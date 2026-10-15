# Campfire in Julia

A Julia HTTP server for Campfire, with the existing Turbo, Stimulus, and Lexxy
frontend and a Rails-compatible SQLite database. The implementation lives in
`src/Web.jl` and `src/web/`; the earlier small performance prototype remains in
`src/Campfire.jl` for reproducible kernel and handler measurements.

## Run the server

Use Julia 1.13.1 and install the native runtime dependencies. On Debian/Ubuntu:

```sh
sudo apt-get install libcrypt1 libqrencode4 libssl3 libxml2 libvips-tools ffmpeg
julia --project=julia -e 'using Pkg; Pkg.instantiate()'
JULIA_NUM_THREADS=4,1 julia/bin/campfire /tmp/campfire-julia/production.sqlite3 3001
```

Open http://127.0.0.1:3001 and complete first-run setup. The parent directory and
schema are created automatically. Data and attachments persist between restarts.

The server implements login/logout, invitations, profiles, account settings,
custom styles, user administration, open/closed rooms, direct conversations,
room memberships, rich-text messages, edits/deletes, boosts, FTS search, avatars,
file uploads/downloads, image/video previews, bots and webhook replies, session
transfers and real QR codes. Action Cable delivers messages, room changes, typing,
presence, and read/unread notifications. Link previews use bounded requests with
DNS pinning and private-address rejection. Web Push uses P-256, HKDF, AES-GCM,
and VAPID signing through OpenSSL.

Configuration:

| Variable | Default / purpose |
|---|---|
| `DATABASE_PATH` | `storage/julia.sqlite3`, used when the positional path is omitted |
| `DATABASE_SYNCHRONOUS` | `FULL`; optionally `NORMAL` for SQLite WAL writes, with the durability tradeoff below |
| `PORT` | `3001`, overridden by the second positional argument |
| `CAMPFIRE_HOST` | `127.0.0.1` |
| `JULIA_NUM_THREADS` | Julia thread pools; `4,1` means four workers and one I/O thread (Docker defaults to `auto`); see the four-CPU `2,2` measurements below |
| `CAMPFIRE_ORIGIN` | Canonical public origin; set this to the HTTPS URL behind a proxy |
| `STORAGE_PATH` | `storage/` beside the database |
| `SECRET_KEY_BASE` | Generated and persisted with mode 0600 if absent |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | Override the persisted generated Web Push key pair |
| `VAPID_SUBJECT` | Contact URI for push providers; set to your `mailto:` or HTTPS URL |

Use a copy when testing an existing Rails database. Supply its original
`SECRET_KEY_BASE` to verify existing signed cookies, avatar IDs and session
transfers, and point `STORAGE_PATH` at its attachment files. Startup installs the
current schema additions and message-count triggers. Back up the database and
storage together. This process does not run Ruby or Redis.

The writer explicitly defaults to SQLite `synchronous=FULL`. Setting
`DATABASE_SYNCHRONOUS=NORMAL` can reduce synchronization work on durable storage,
but recent committed transactions can be lost after a power failure or operating
system crash. SQLite documents this distinction for
[WAL synchronous settings](https://www.sqlite.org/pragma.html#pragma_synchronous).
Only `FULL` and `NORMAL` are accepted; ordinary process crashes retain committed
transactions with either setting.

HTTP socket I/O and parsing run on the interactive thread pool. Application
requests run on the default worker pool. Room, message, sidebar and search GETs borrow
exclusive SQLite readers, with up to four readers by default when
multiple workers are available. Each reader owns its prepared statements,
observer connection and response cache shard. The shards share a total limit of
64 MiB and 512 entries; authentication and membership checks still query current
database state, and external commits invalidate cached responses. Writes and
other routes use the original writer connection. Session activity updates return
to that writer before a reader lease completes.

Socket writes, webhook calls, link-preview fetches and push delivery run outside
database locks. Media variants publish atomically under a shared storage lock.
Rendering and writes still allocate; GC remains enabled. Websocket delivery
and asynchronous notifications are local to this process. Multiple independently
running Julia replicas do not share a realtime broker or a durable job queue.
Use one server process for now.

The worker transport reuses HTTP.jl's parser, WebSocket handling and server
lifecycle, with a default limit of 4,096 connections. Its adapter uses internal
HTTP.jl 1.11 APIs isolated in `src/web/Transport.jl`; rerun its focused transport
tests when upgrading HTTP.jl. Workers serialize eligible responses into a private
buffer owned by the connection task, which sends headers and body in one socket
write. This buffer is allocated lazily, reused only after the write completes,
and capped at 64 KiB including headers. Larger responses, upgrades, chunked
responses and bodyless responses use HTTP.jl's ordinary write path. Retained
transport buffers are separate from the shared response-cache budget; at the
connection limit their capacity could total 256 MiB. Close the HTTP server
before closing `WebApp`.

The transport records the socket peer address once per connection and serializes
eligible headers directly into that connection's buffer. Push preparation reads
current eligible subscriptions before loading message text, and fetches only the
fields needed for notifications. It verifies signed mentions when a recipient
requests mentions only. This reduces allocation and time holding the writer lock.

## Docker

```sh
docker build -f julia/Dockerfile -t campfire-julia .
docker run --rm -p 3000:3000 -v campfire-julia-data:/data campfire-julia
```

The image runs as a non-root user, listens on port 3000, and persists the database,
attachments and generated secrets under `/data`. Set `CAMPFIRE_ORIGIN` when
serving through an HTTPS reverse proxy. The native libraries are runtime
dependencies; there is no C or Rust application server hidden behind Julia.

## Verification

Each Julia test file runs independently in the test environment:

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate()'
julia --project=test test/julia_web_sqlite.jl
julia --project=test test/julia_web_auth.jl
julia --project=test test/julia_web_messages.jl
julia --project=test test/julia_web_views.jl
julia --project=test test/julia_web_server.jl
julia --threads=4,1 --project=test test/julia_web_readers.jl
julia --threads=4,1 --project=test test/julia_web_transport.jl
julia --threads=2,2 --project=test test/julia_web_transport.jl
julia --threads=4,1 --project=test test/julia_web_media.jl
julia --project=test test/julia_web_cable.jl
julia --project=test test/julia_web_unfurl.jl
julia --project=test test/julia_web_push.jl
```

The unchanged shared browser smoke test passes against a fresh Julia database.
It exercises installation, two-tab live messages, duplicate suppression, stored
markup safety, editing, search, settings, bots, invitations, session transfers,
and direct-message draft preservation. Run it from a checkout of
[once-campfire-verification](https://github.com/basecamp/once-campfire-verification):

```sh
bin/browser --base http://127.0.0.1:3001
```

The shared HTTP contracts and release load generator also passed all eight routes:
880 validated responses, including 110 acknowledged writes audited against exact
persisted message IDs, bodies, rooms and FTS entries. Fixtures were generated by
its pinned Rails revision `90b330024dec3e757c79b6a7e6568f93da8e3148`;
the verification checkout was `ec02debb3e44f40b8778a6a42db3c4515b2f9eaf`.
`bench/conformance.rb --help` documents the adapter that runs the unchanged
contracts and write auditor against a disposable fixture copy. Raw receipts stay
outside source control.

The browser flow and HTTP contracts complement the focused tests; neither proves
complete production equivalence to every Rails behavior. The comparison adapter
below adds Julia to the shared harness without editing its checkout.

## Backend source size, 2026-10-13

The implementations used in the comparison have the following source sizes:

| Implementation | Backend code lines | Relative to Julia | Without whole generated table files |
|---|---:|---:|---:|
| Julia | 7,248 | 1.0× | 7,248 |
| Rust | 35,740 | 4.9× | 31,667 |
| C | 108,371 | 15.0× | 94,829 |

Counts use `cloc` 2.06 and exclude blank lines, comments, tests, benchmarks,
build tooling, third-party dependencies and shared frontend assets. They include
backend source, rendering/templates, schema and application-owned media helpers.
The main count includes checked-in generated application tables. The last column
excludes whole generated table files but retains generated blocks inside other
source files. Julia's retained prototype and seed helpers are included.

Rust's inline test modules and test-support code were removed using syntax-tree
spans before counting; both original and filtered files parsed successfully.
`--docstring-as-code` preserves Julia's triple-quoted SQL/HTML as code, and
`--force-lang='Jinja Template',html` recognizes comments in Askama templates.
Revisions counted were Julia `0981a32`, Rust `6838ead` and C `873a51f`.
Per-file counts, source manifests and filtering scripts are retained under
`tmp/julia-loc/2026-10-13/` (ignored by Git).

At these revisions, Julia reaches 96–112% of the earlier Rust read throughput
and 72–75% of C's across the four measured read routes. Posting reaches 46% of
Rust's and 56% of C's throughput. These use the measurements below; native
implementations were not rerun for the source count. C and Rust maintain more
infrastructure and compatibility code themselves, while Julia delegates several
corresponding operations to packages. Source size reflects these implementation,
dependency and formatting choices; it does not establish equivalent feature
coverage or maintainability.

## Full local comparison: Julia `4,4`, Julia `2,2` and C, 2026-10-15

Fresh measurements on this machine's **Intel Core i7-12700K**, with the same
four server cores allocated to each configuration. All five HTTP routes were
rerun together; these are medians of three rotating rounds, rounded to whole
requests per second. The source-size row is a separate count, not a timed test.

| HTTP workload (requests/sec) | Julia `4,4` | Julia `2,2` | C |
|---|---:|---:|---:|
| Room page | 39,100 | 105,371 | 102,847 |
| Messages page | 35,041 | 110,932 | 111,478 |
| Sidebar | 36,408 | 117,504 | 118,692 |
| Search | 41,307 | 114,766 | 114,673 |
| Post a message | 3,758 | 6,198 | 4,759 |
| Backend KLOC | 7.3 | 7.3 | 94.8 |

Julia `2,2` reaches roughly C's read throughput: its medians range from 1.00%
below C to 2.45% above. Differences this small across three rounds do not
establish a general read-performance winner. Its POST throughput is 30.25%
higher than C's, while C retains substantially lower POST tail latency:

| Median per-run p99 (ms) | Julia `4,4` | Julia `2,2` | C |
|---|---:|---:|---:|
| Room page | 3.679 | 0.221 | 0.334 |
| Messages page | 3.905 | 0.208 | 0.312 |
| Sidebar | 3.947 | 0.191 | 0.269 |
| Search | 3.697 | 0.200 | 0.291 |
| Post a message | 12.263 | 11.487 | 4.531 |

Maximum container lifetime memory peaks across the complete five-route runs
are **2,453.7 MiB** for Julia `4,4`, **3,489.1 MiB** for Julia `2,2`, and
**112.9 MiB** for C. These include startup/JIT, warmup, earlier routes and
different numbers of persisted messages. They are not steady-state live heap,
RSS or per-request allocation measurements, and cannot identify a memory leak
or its cause. C has a large measured memory advantage in this run.

The Julia columns use identical application source and the same Julia 1.13.1
image. `4,4` means four application workers plus four interactive I/O threads;
`2,2` means two of each. Both have only four allocated server cores. Fresh Julia
API probes report four versus two GC threads, and the application also selects
four versus two exclusive readers/cache shards. GC remains enabled and the
total response-cache budget stays 64 MiB. This combined configuration change
does not isolate why `4,4` is slower. C uses four HTTP loops plus its native
reader, writer and job pools; CPU allocation is matched, not total thread count.

Each route has ten seconds of warmup at four clients and fifteen measured
seconds at 16 clients. Server CPUs are `0,2,4,6`, four distinct performance
cores; the client uses four other performance cores, `8,10,12,14`. Round order
rotates C/Julia `4,4`/Julia `2,2`, Julia `4,4`/Julia `2,2`/C, then
Julia `2,2`/C/Julia `4,4`. Each application-round starts from a fresh fixture
copy, then runs room, messages, sidebar, search and POST in that order.
The harness uses gzip, host networking and unchanged response contracts;
rendered HTML and compressed sizes can differ between implementations.

Both Julia writers explicitly use `DATABASE_SYNCHRONOUS=NORMAL` to match C;
Julia's default remains `FULL`. C sets all handles to `NORMAL`, while Julia's
query-only reader/observer settings are unchanged. Disposable databases reside
on `/tmp` tmpfs, so this does not measure durable-disk synchronization cost.
Local unavailable/rejected notification endpoints do not measure real-provider
delivery, and write audits do not establish equal background-job completion.
Rust and mixed read/write traffic were not measured. These local results must
not be combined with the root README's published AMD-machine throughput table.

The fresh source count is **7,294 Julia lines** and **94,816 C lines**, using
`cloc` 2.06 consistently for both implementations (the upstream table used
2.10). It counts maintained backend-language files, including Julia's selectable
prototype and C's first-party media helper. It excludes blank lines, comments,
standalone SQL, shell/build/deployment files, fixture seeds, tests, benchmarks,
frontend assets, dependencies and whole generated files. Inline generated/test
blocks inside maintained runtime files remain counted. `--docstring-as-code`
preserves executable Julia triple-quoted SQL/HTML; eight genuine one-line
docstrings are explicitly reclassified as comments. The earlier roughly 7.6
Julia KLOC count included SQL, shell and seed files and those docstrings; the
new number changes the counting scope, not the source. Counts reflect formatting,
dependency and feature boundaries, not equivalent coverage or maintainability.

All **69,734,971 responses**, including warmup, validate with zero errors or
invalid responses; 47,654,386 are timed responses. Independent read-only audits
verify all **1,052,048 acknowledged writes** from 18 receipt files across nine
databases, including exact IDs, rooms, rich-text and FTS bodies, no extra writes,
integrity checks and unchanged database/WAL hashes. The unchanged focused
transport test passes **206 assertions under `--threads=4,4`**, and the unchanged
Chromium smoke test passes. The preceding `2,2` test/browser evidence remains
applicable to the identical runtime. No production or test source changed here.

Julia was measured at clean source revision `0acee77`, image
`sha256:c5c0e2d8aa293206c8c71a674bad5fbf4cb73e9a9e7bc77f03a5d6e3aa1c2131`,
with runtime digest
`7ecf3edc38e20ca43ec609e56ecf12698917794fc28db98b7adf246e955a9c8a`.
C remains at `873a51f`, image
`sha256:820f3ef4f63e72f26031698a6f6146d3e779ccf75390f90598183d7c68862cca`.
Fresh image/source checks confirm these identities. Verification checkout
`ec02deb` and its unchanged load generator supply the contracts and write audits.

An earlier incomplete attempt hit the host's `/tmp` user quota while the load
generator wrote a receipt. All of its samples are excluded. Four older completed
Julia runtime directories were moved to ignored workspace storage with exact
file/hash verification and symlinks preserving their original paths; no retained
evidence was discarded. The entire three-round comparison was then rerun.
Successful raw results, receipts, audit reports, source/count manifests, launch
scripts, tests and browser evidence are retained under
`tmp/julia-full-server/2026-10-15-full-table/` (ignored by Git). The failed attempt
is separate; evidence archives exclude runtime databases, storage and credentials.

## Two I/O threads on four CPUs, 2026-10-14

Changing `JULIA_NUM_THREADS=4,1` to `2,2` closes the measured cached-room gap
without changing Julia's executable or application source. The same image now
uses two application workers and two interactive I/O threads on four allocated
CPUs. GC remains enabled. Three rotating rounds give these medians:

| Route | C req/s | Julia `4,1` req/s | Julia `2,2` req/s | C p99 | Julia `4,1` p99 | Julia `2,2` p99 |
|---|---:|---:|---:|---:|---:|---:|
| Cached room | 98,605.9 | 81,190.9 | 102,818.6 | 0.347 ms | 0.654 ms | 0.250 ms |
| POST message | 4,648.0 | 5,509.3 | 6,198.8 | 4.583 ms | 9.191 ms | 11.047 ms |

Cached-room throughput improves **26.64%**, with paired gains of 28.60%, 26.45%
and 23.13%. Julia reaches 104.27% of C's median throughput. Its individual runs
range from 99,967.3 to 104,273.7 req/s; C wins the third round by about 0.8%.
This supports roughly C-level throughput for this workload, with a small median
lead. Julia's cached-room p99 improves 61.77% relative to `4,1`.

The write tradeoff matters: POST throughput improves 12.52%, but p99 worsens
20.19%. C retains substantially lower POST p99. Maximum POST container lifetime
memory peaks are 111.4 MiB for C, 1,260.6 MiB for Julia `4,1`, and 1,354.5 MiB
for Julia `2,2`. These include startup, compilation, warmup and different numbers
of persisted messages; they are not steady-state RSS or per-request allocation
measurements. Treat `2,2` as a measured four-CPU tuning option. Docker's thread
default remains unchanged. To select this split when starting a server:

```sh
JULIA_NUM_THREADS=2,2 julia/bin/campfire /tmp/campfire-julia/production.sqlite3 3001
```

This command retains the default `FULL` writer durability. The comparison
explicitly sets Julia's writers to `NORMAL` to match C. C sets all connections
to `NORMAL`; Julia's query-only reader/observer settings are unchanged. Both
use SQLite 3.53.4 from different builds, with disposable databases on tmpfs.
Durable-disk synchronization cost and real-provider notification delivery are
not measured. HTTP write audits do not establish equal background-job completion.

This is a combined thread-pool configuration change: Julia reports four versus
two GC threads, and the application automatically creates four versus two
exclusive readers/cache shards. The total cache budget remains 64 MiB. It does
not isolate the contribution of the I/O threads, worker scheduling, GC or reader
partitioning. A separate two-round pilot tried `4,1`, `3,1`, `3,2` and `2,2`,
then repeated `4,1`; it selected `2,2` for this fresh three-round comparison.
Pilot samples are excluded from the table above.

The final rounds rotate C/baseline/tuned, baseline/tuned/C and tuned/C/baseline.
Each route gets ten seconds of warmup at four clients and fifteen measured
seconds at 16 clients. Server CPUs are `0,2,4,6`; client CPUs are `8,10,12,14`.
The fixture, gzip, host networking, cache budgets and response contracts match.
C retains four HTTP loops plus its reader, writer and job pools; CPU allocation
is matched, not total thread count. Throughput and p99 are medians of three
per-run values, not pooled percentiles. Rust, other routes and mixed writes
were not rerun.

All 20,144,571 responses including warmup validate with zero errors or invalid
responses. Independent read-only audits verify all 1,175,872 acknowledged writes
across nine databases, including exact message IDs, rooms, rich-text and FTS
bodies, no extra writes, integrity checks and unchanged database/WAL hashes.
The modified transport test passes 206 assertions under `--threads=2,2`, with
temporary coverage probes confirming distinct I/O threads, worker dispatch,
private buffers through delayed writes, reuse and graceful shutdown. The
unchanged Chromium smoke test passes. JuliaFormatter 2.14's second pass is
unchanged; no production source changed.

Both Julia configurations use image `sha256:c5c0e2d8aa29…`, runtime digest
`7ecf3edc38e20ca43ec609e56ecf12698917794fc28db98b7adf246e955a9c8a`, based on
`bcd4baa`. C remains `873a51f`, image `sha256:820f3ef4f63e…`. Image/source checks,
raw results, receipts, launch scripts, selected topology, completed pilot,
focused tests and browser evidence are retained under
`tmp/julia-full-server/2026-10-14-io-topology/` (ignored by Git), excluding
runtime databases, storage and credentials.

## Cached-header experiment, not retained, 2026-10-14

A candidate stored separate validated plain/gzip header templates in each
cached page and copied the selected template per response. It preserved header
order, duplicate fields, response ownership and authorization, and charged the
extra templates to the cache budget. The isolated gzip response helper, including
security headers, fell from 1,328 to 464 Julia-allocated bytes and from 0.316 to
0.160 µs across seven alternating warmed rounds. This excludes HTTP parsing,
database checks, worker dispatch and socket I/O.

That saving did not improve full-server cached-room throughput:

| Route | C req/s | Julia baseline req/s | Header candidate req/s | Baseline p99 | Candidate p99 |
|---|---:|---:|---:|---:|---:|
| Cached room | 103,836.3 | 81,137.1 | 80,472.3 | 0.653 ms | 0.663 ms |
| POST message | 4,688.3 | 5,581.4 | 5,567.0 | 9.071 ms | 8.999 ms |

The cached-room median changes −0.82%; individual paired changes are −0.74%,
−1.50% and +0.24%. The candidate is not retained. Lower allocation in one helper
does not establish a server throughput gain.

Three rounds rotate C/baseline/candidate, baseline/candidate/C and
candidate/C/baseline. All writers use `NORMAL`, with the same fixture, gzip,
64 MiB cache budgets, server CPUs `0,2,4,6`, client CPUs `8,10,12,14`, ten seconds
of warmup at four clients and fifteen seconds at 16 clients per route. Julia
uses four default threads plus one interactive thread and GC stays enabled.
Databases are on tmpfs; external notification delivery is not measured.
Throughput and p99 are medians of per-run values, not pooled percentiles.

All 18,703,362 responses including warmup validate with zero errors. Independent
read-only audits verify all 1,133,860 acknowledged writes across nine databases,
including exact message IDs, rooms, rich-text and FTS bodies, integrity checks
and unchanged database/WAL hashes. The candidate passed 386 focused assertions,
temporary line/type coverage probes, JuliaFormatter 2.14's unchanged second
pass and the unchanged Chromium smoke test before measurement.

The baseline is `bcd4baa` using the previously pinned Julia image; the discarded
candidate image is `sha256:4704a7948358…`. C remains the pinned `873a51f` build.
Candidate sources, patch, full hashes, profiles, component measurements, raw
results, receipts and validation evidence are retained under
`tmp/julia-full-server/2026-10-14-cached-headers/` (ignored by Git), excluding
runtime databases, storage and credentials.

## Refreshed matched C comparison, 2026-10-14

A fresh comparison of Julia `e07808a` against the same pinned C `873a51f`
build sets both SQLite writers to `NORMAL`:

| Route | C req/s | Julia req/s | C p99 | Julia p99 |
|---|---:|---:|---:|---:|
| POST message | 4,716.8 | 5,489.7 | 4.571 ms | 9.223 ms |
| Cached room | 100,981.8 | 81,108.1 | 0.325 ms | 0.647 ms |

Julia leads this POST workload by 16.39% at the median, with paired leads of
17.81%, 12.11% and 21.10%. It reaches 80.32% of C's cached-room throughput.
C retains roughly half the p99 latency on both routes. Maximum POST container
lifetime memory peaks are 113.8 MiB for C and 1,181.5 MiB for Julia; these
include startup, compilation and warmup, rather than measuring steady-state
resident memory or per-request allocations. This refresh measures the current
implementations; it does not isolate the effect of an individual optimization.

Three rounds alternate C/Julia, Julia/C and C/Julia on fresh copies of the same
fixture. Each route gets ten seconds of warmup at four clients, then fifteen
seconds at 16 clients. Throughput and p99 are medians of the three run values;
percentiles are not pooled. Server CPUs are `0,2,4,6`, client CPUs `8,10,12,14`.
The release load generator, response contracts, fixture, host networking, gzip
and 64 MiB cache budgets are unchanged. Julia has four default threads plus
one interactive thread, with GC enabled. C has four HTTP loops plus its reader,
writer and job pools. CPU allocation is matched; total thread counts and
HTTP/compression implementations differ.

Both implementations use SQLite 3.53.4 from different builds. C applies
`NORMAL` to all connections; Julia applies it to its writer, with query-only
reader/observer settings unchanged. Julia's default remains `FULL`; this
comparison explicitly overrides it to match C's writer durability. Databases
are on `/tmp` tmpfs, so durable-disk synchronization cost is not measured.
Push/webhook endpoints retain the benchmark's local rejection/unavailability
setup. Acknowledged HTTP writes and persistence audits do not establish equal
background-job completion or external delivery throughput. Only these two
routes were rerun; Rust, other routes and mixed-writer loads were not refreshed.

All 12,737,411 responses including warmup pass validation with zero errors or
invalid responses. Independent read-only audits verify all 746,368 acknowledged
writes across six databases against exact IDs, rooms, rich-text bodies and FTS
entries, with no extra or missing new messages. Integrity checks pass, and
database/WAL hashes remain unchanged during the audits.

The Julia image is `campfire-julia:native-push-subscriptions`
(`sha256:c5c0e2d8aa29…`); C is `campfire-c:local` (`sha256:820f3ef4f63e…`).
Julia's image/source match and both clean source revisions are checked. C's
image executable matches the retained optimized build and its startup script
matches the pinned source; C was not rebuilt for this refresh. Raw results,
receipts, source snapshots, complete hashes, launch settings and independent
audits are retained under `tmp/julia-full-server/2026-10-14-matched-c-refresh/`
(ignored by Git). The archive excludes runtime databases, storage and
credentials. This is a documentation/measurement update; the earlier focused
Julia tests, formatting and browser checks are referenced, not rerun.

## Direct decoding of push subscriptions, 2026-10-14

Push subscription selection now copies fixed rows directly from the prepared
SQLite statement, avoiding generic query metadata and dynamic field lookup.
The unchanged query uses `p.*`, so the reader checks all eleven column names
without allocating name strings, then validates each row's storage types before
copying it. An unusual schema or value discards every provisional row and uses
the original decoder for the entire query after statement reset. That reread may
observe a newer external commit; it reevaluates all recipient predicates and
retains the existing room/creator check on the subsequent message read.

Strings remain owned after the statement advances or resets, and the existing
NULL and embedded-NUL behavior is preserved. Multiple devices remain separate
rows. No ordering guarantee is added to the SQL, which has no `ORDER BY`.

An isolated Julia 1.13.1 diagnostic compares the exact previous helper with the
new reader on the same SQLite connection:

| Eligible devices | Old time | New time | Old Julia bytes | New Julia bytes |
|---|---:|---:|---:|---:|
| None | 6.260 µs | 1.810 µs | 5,360 | 32 |
| One, nullable fields | 10.068 µs | 2.523 µs | 7,008 | 448 |
| Two, Unicode fields | 14.098 µs | 3.197 µs | 8,880 | 928 |
| 32 across 16 users | 124.048 µs | 22.250 µs | 60,200 | 13,560 |

The two-device lookup takes 77.3% less time and allocates 89.5% fewer Julia bytes.
Seven warmed rounds alternate old/new order on CPU 0 with one thread and GC
enabled. These loops include selection, row copying and statement cleanup;
message/badge reads, payload encoding, encryption, delivery, network and HTTP
are excluded. Native SQLite time is included, but native allocation bytes are
excluded. Both helpers infer `Vector{PushSubscription}`. Exact values, query
sequence, eligibility filters and duplicate devices match. Returned strings
survive statement reuse, GC, external updates and database close. The reader
runs under the existing writer lock, so reducing this work shortens that lock's
hold time without changing the lock boundaries.

The full-server before/after comparison reports:

| Route | Baseline req/s | Candidate req/s | Baseline p99 | Candidate p99 |
|---|---:|---:|---:|---:|
| POST message | 5,072.5 | 5,571.5 | 9.823 ms | 9.159 ms |
| Cached room | 81,197.4 | 81,271.8 | 0.656 ms | 0.648 ms |

POST throughput rises 9.84% at the median, with individual paired gains of
12.58%, 9.52% and 10.51%. Median POST p99 falls 6.76%. The cached-read control
changes only +0.09%. Maximum POST container lifetime memory peaks are 1,264.6
versus 1,190.1 MiB; they include startup, compilation and warmup, so they are
not measurements of steady-state resident memory.

Three alternating rounds compare against `447790f`, with SQLite `FULL` in both
builds, ten seconds of warmup at four clients and fifteen seconds at 16 clients.
The fixture, release load generator, response contracts, gzip, 64 MiB cache and
GC are unchanged. Julia uses four worker threads and one interactive thread;
server CPUs are `0,2,4,6`, client CPUs `8,10,12,14`. Databases are on `/tmp`
tmpfs, so durable-disk synchronization cost is not measured. Push endpoints
retain the benchmark's local rejection setup; external delivery is not measured.
Latencies are medians of per-run p99 values. Other routes, C and Rust were not
rerun for this step; the earlier matched C comparison remains in the badge-count
section.

The focused push test file passes 239 assertions in `--project=test` after
formatting. Coverage probes exercise native decoding, eight compatibility
fallbacks and a failure on a subsequent SQLite step, then are removed. Tests
check complete-list parity, later-row conversion rules, column additions and
renames, duplicate devices, copied strings and statement reuse after errors.
JuliaFormatter 2.14's second pass is unchanged, and the unchanged Chromium smoke
test passes against the candidate image.

All 11,687,945 benchmark responses including warmup pass validation with zero
errors or invalid responses. Independent read-only audits verify all 753,831
acknowledged writes across six databases against exact IDs, rooms, rich-text
bodies and FTS entries. Integrity checks pass and database/WAL hashes remain
unchanged during the audit.

The baseline image is `campfire-julia:native-message-row`; the candidate is
`campfire-julia:native-push-subscriptions`. Source/image hashes, raw paired
results, receipts, component measurements, focused tests and precommit diff are
retained under `tmp/julia-full-server/2026-10-14-native-push-subscriptions/`
(ignored by Git). Runtime databases, storage and credentials are excluded from
the evidence archive.

## Direct decoding of newly created messages, 2026-10-14

The newly created message reader now bypasses SQLite.jl's generic `Query`/`Row`
metadata when its 12 columns have their usual storage types. It checks every
column before decoding, copies strings into an owned concrete row, and resets
the statement through the existing native helper. Its fixed SQL string is also
assembled once at module load. The SQL text and transaction
boundary are unchanged, so database triggers and association guards remain
visible. Unusual storage types use the original typed query projection after
reset; non-`Int64` IDs also retain the generic path. The creation transaction
keeps the fallback reread in the same database snapshot.

An isolated diagnostic compares the exact previous reader with the new one in
the same Julia 1.13.1 process:

| Message lookup | Old time | New time | Old Julia bytes | New Julia bytes |
|---|---:|---:|---:|---:|
| Short plain message | 10.409 µs | 2.305 µs | 7,472 | 480 |
| Unicode message | 10.437 µs | 2.336 µs | 7,552 | 560 |
| Large Unicode message | 39.703 µs | 29.893 µs | 179,600 | 172,608 |
| NULL room name, absent rich text | 10.214 µs | 2.200 µs | 7,296 | 336 |
| Missing message | 5.668 µs | 1.159 µs | 5,696 | 0 |

The short lookup takes 77.9% less time and allocates 93.6% fewer Julia bytes.
Seven warmed rounds alternate old/new order on CPU 0 with one thread and GC
enabled. Native SQLite execution is timed; native allocations are excluded from
the byte counters. Transaction begin/commit, rendering, HTTP and notifications
are outside these loops. Both readers infer `Union{Nothing, CreatedMessageRow}`;
the improvement removes internal generic decoding work despite the previous
reader's concrete return type. Exact rows, presentation and HTML match, and held
strings survive statement reuse, GC, external commits and database close.

The full-server before/after comparison reports:

| Route | Baseline req/s | Candidate req/s | Baseline p99 | Candidate p99 |
|---|---:|---:|---:|---:|
| POST message | 4,890.6 | 5,163.8 | 10.199 ms | 9.479 ms |
| Cached room | 82,075.4 | 82,026.0 | 0.602 ms | 0.607 ms |

POST throughput rises 5.59% at the median, with individual paired gains of
4.64%, 5.11% and 6.53%. Median POST p99 falls 7.06%. The cached-read control is
nearly unchanged at -0.06%. Maximum POST container lifetime memory peaks are
1,226.5 versus 1,216.0 MiB; they include startup, compilation and warmup, so this
small difference does not establish lower steady-state resident memory.

Three alternating rounds compare against `6d2b046`, with SQLite `FULL` in both
builds, ten seconds of warmup at four clients and fifteen seconds at 16 clients.
The fixture, release load generator, response contracts, gzip, 64 MiB cache and
GC are unchanged. Julia uses four worker threads and one interactive thread;
server CPUs are `0,2,4,6`, client CPUs `8,10,12,14`. Databases are on `/tmp`
tmpfs, so these runs do not measure durable-disk synchronization cost. Latencies
are medians of per-run p99 values. Other routes, C and Rust were not rerun for
this step; the badge-count section retains the previous matched C comparison.

The focused message/media tests pass 379 assertions in `--project=test` after
formatting. Fifteen storage scenarios compare exact values or exception classes
with the old decoder, followed by successful canonical reads to check statement
recovery. Coverage probes confirm both decoding paths, then are removed. Existing
NULL, Unicode, embedded-NUL, trigger, attachment, boost and rollback checks pass.
JuliaFormatter 2.14's second pass is unchanged, and the unchanged Chromium smoke
test passes against the candidate image.

All 11,857,278 benchmark responses including warmup pass validation with zero
errors or invalid responses. Independent read-only audits verify all 717,067
acknowledged writes across six databases against exact IDs, rooms, rich-text
bodies and FTS entries. Integrity checks pass and database/WAL hashes remain
unchanged during the audit.

The baseline image is `campfire-julia:stream-buffer`; the candidate is
`campfire-julia:native-message-row`. Source/image hashes, raw paired results,
receipts, component measurements, focused tests and precommit diff are retained
under `tmp/julia-full-server/2026-10-14-native-message-row/` (ignored by Git).
Runtime databases, storage and credentials are excluded from the evidence archive.

## Message streams in one buffer, 2026-10-14

Message creation and editing now write the Turbo Stream envelope and existing
`message_html(io, ctx, row)` output into one owned buffer. This removes the
intermediate complete HTML string and its copy into the stream. The buffer adds
128 bytes for the normal append/replace envelope to the renderer's existing
6,144-byte allowance, avoiding extra growth near that boundary. Rendering stays
at the same point inside the transaction, before events are published. The
existing standalone HTML and generic stream helpers remain available.

An isolated rendering diagnostic compares the unchanged nested composition with
the new writer in the same Julia 1.13.1 process:

| Rendered stream | Old time | New time | Old Julia bytes | New Julia bytes |
|---|---:|---:|---:|---:|
| Typical, 4,855 bytes | 6.285 µs | 5.675 µs | 16,560 | 11,760 |
| Near buffer limit, 6,190 bytes | 6.487 µs | 5.797 µs | 17,904 | 11,760 |
| Large Unicode, 100,759 bytes | 52.935 µs | 30.455 µs | 274,448 | 173,840 |

Typical rendering is 9.7% faster with 29.0% fewer Julia allocation bytes. All
12 measured cases improve in this diagnostic and preserve exact append/replace
output. Seven warmed rounds alternate old/new order, with GC enabled, one
thread on CPU 0, and owned hydrated rows prepared before timing. Only append is
timed; SQL, transaction commit, HTTP, compression and push work are excluded.
These component improvements do not establish a full-server speedup. Native
allocation bytes are excluded. The initial 6,144-byte-hint experiment and its
boundary allocation regression are preserved alongside the corrected result.

The full-server before/after comparison reports:

| Route | Baseline req/s | Candidate req/s | Baseline p99 | Candidate p99 |
|---|---:|---:|---:|---:|
| POST message | 4,423.0 | 4,502.4 | 11.631 ms | 11.319 ms |
| Cached room | 76,619.9 | 77,622.7 | 0.683 ms | 0.693 ms |

POST throughput rises in all three pairs: +1.80%, +5.85% and +0.33%; the median
rises 1.80%. The unchanged cached-read control also rises 1.31%, and POST p99
is slightly worse in the third pair. This is a modest, noisy server gain, with
clearer evidence for the isolated allocation reduction. Maximum POST container
lifetime memory peaks rise from 1,294.4 to 1,442.5 MiB, including startup and
warmup; fewer rendering allocations do not establish lower resident memory.

The full-server comparison uses three alternating rounds against `3c64c0b`,
with SQLite `FULL` in both builds, ten seconds of warmup at four clients and
fifteen seconds at 16 clients. The same fixture, unchanged release load
generator and response contracts, gzip, 64 MiB cache and GC are retained. Julia
uses four worker threads and one interactive thread, with server CPUs `0,2,4,6`
and client CPUs `8,10,12,14`. Databases are on `/tmp` tmpfs. Cached room reads
are a control; other routes, C and Rust were not rerun for this step. The badge-count section records the previous step's
fresh matched C comparison. Latencies are medians of per-run p99 values.

The modified message/media test file passes 339 assertions in `--project=test`
after formatting. Coverage probes hit both changed call sites and the capacity
boundary, then were removed. Exact stream bytes, target escaping, owned output,
attachments, sounds, mentions, boosts, edit events and rollback behavior are
covered. JuliaFormatter 2.14's second pass is unchanged, and the unchanged
Chromium smoke test passes against the candidate image.

All 10,996,935 benchmark responses including warmup pass validation with zero
errors or invalid responses. Independent read-only audits verify all 642,608
acknowledged writes across six databases against exact IDs, rooms, bodies and
FTS entries. Integrity checks pass and database/WAL hashes stay unchanged.

The baseline image is `campfire-julia:badge-count`; the candidate is
`campfire-julia:stream-buffer`. Source/image hashes, paired raw results,
receipts, component measurements, focused tests and precommit diff are retained
under `tmp/julia-full-server/2026-10-14-stream-buffer/` (ignored by Git).
The evidence archive excludes runtime databases, storage and credentials.

## Typed push badge counts and fresh C comparison, 2026-10-14

Each push subscription still gets its own fresh unread-room count under the
writer lock. A dedicated `message_push_badge` now binds the user ID as `Int64`
and reads the integer result through SQLite.jl's existing native API, skipping
the generic query wrapper and column metadata. The shared statement helper now
accepts `Int64` alongside strings; statement ownership, reset/clear on errors,
SQL, recipient order, permissions and notification payloads are preserved.
No new dependency, batching, cache or default durability change is involved.

The paired Julia-before/after comparison keeps both builds at SQLite `FULL`:

| Route | Baseline req/s | Candidate req/s | Baseline p99 | Candidate p99 |
|---|---:|---:|---:|---:|
| POST message | 4,331.4 | 4,494.9 | 11.223 ms | 11.191 ms |
| Cached room | 77,626.8 | 79,426.9 | 0.757 ms | 0.685 ms |

POST medians differ by +3.77%, but individual pairs are −5.19%, +1.49% and
+9.88%, while the unchanged cached-read control also rises 2.32%. This is noisy
full-server evidence, not an established 3.77% speedup from the badge change.

A separate fresh comparison uses SQLite `NORMAL` for both pinned C and the
Julia candidate:

| Route | C req/s | Julia req/s | C p99 | Julia p99 |
|---|---:|---:|---:|---:|
| POST message | 4,782.5 | 4,715.4 | 4.407 ms | 10.695 ms |
| Cached room | 106,302.5 | 80,413.1 | 0.321 ms | 0.667 ms |

Julia reaches 98.60% of C's median POST throughput and 75.65% of its cached-read
throughput. POST throughput is close; tail latency and memory remain substantial
gaps. Maximum container-lifetime memory peaks for POST runs are 123.1 MiB for C
and 1,909.7 MiB for Julia, including startup and warmup. These peaks are not
per-request allocations or steady-state live-memory measurements.

In the isolated component diagnostic, the badge query drops from 896 to **zero
Julia-allocated bytes** and from 1.881 to 1.264 µs (−32.8%), with its inferred
return type narrowing from `Any` to `Int64`. Complete preparation of three
notifications falls from 20,720 to 18,032 bytes (−13.0%) and from 34.596 to
32.820 µs (−5.1%). Payload hashes match exactly. Instrumented uncontended writer
lock hold time falls from 34.476 to 31.955 µs (−7.3%). Each image runs seven
warmed batches in a separate process; these are component measurements, not
full-server speedups. Julia allocation counters exclude SQLite/native memory.

A separate instrumented Julia diagnostic pair finds mean push lock hold time
50.683→48.370 µs and enqueue-to-finish p99 15.946→15.687 ms. All 230,152 warmup
and timed jobs complete successfully and match acknowledged message IDs, each
with one preparation lock and three real sender calls rejected by the existing
local-address guard. No provider requests occur. Peak unfinished timed jobs
remain 34 in each build, with none unfinished when the stop marker is observed.
This checks completion of the local benchmark workload; it does not measure
external push delivery, and the single instrumented pair is not throughput proof.

Both throughput comparisons use three alternating rounds on fresh copies of
the same fixture, ten seconds of warmup at four clients and fifteen seconds
at 16 clients per route. GC stays enabled. The server uses CPUs `0,2,4,6`,
the load generator `8,10,12,14`; gzip and 64 MiB response caches remain enabled.
Julia uses four default threads plus one interactive thread. C uses its pinned
build with four HTTP loops and four readers. Only the cached room and POST
routes were rerun; this is not a new full-route or mixed-writer comparison. Databases live on
`/tmp` tmpfs, so these results do not establish durable-disk synchronization
costs. Latencies are medians of per-run p99s, not pooled percentiles.

The refreshed baseline POST profile still places samples in the generic badge
query path; those inclusive samples are diagnostic, not predicted speedups.
The modified SQLite and push test files pass 88 and 189 assertions respectively
in `--project=test`, including exact large integers, mixed string/integer
bindings, forced GC, error recovery and fresh badge state. All six temporary
line/type coverage probes hit and were removed. The formatted source passes
the same 277 assertions and the unchanged Chromium smoke test. JuliaFormatter
2.14's second pass is unchanged.

The two throughput comparisons validate 24,107,116 responses including warmup,
with zero errors or invalid responses. Independent read-only audits verify all
1,327,888 acknowledged writes across twelve databases against exact message IDs,
rooms, bodies and FTS entries; integrity checks pass and database/WAL hashes are
unchanged by those audits.

Julia baseline is `24db0b7` (`campfire-julia:push-snapshot`); the candidate image
is `campfire-julia:badge-count`. C remains at `873a51f`, using the same pinned
image as the earlier comparison, now measured again. Raw samples, receipts,
source/image hashes, component and completion diagnostics, tests and the
precommit patch are retained under
`tmp/julia-full-server/2026-10-14-badge-count/` (ignored by Git). Runtime
databases, storage and credentials are excluded from the evidence archive.

## Push payloads outside the writer lock, 2026-10-13

Push jobs now capture owned message text, eligible subscriptions and an aligned
`Int64` badge vector under `app.lock`, then build every JSON payload after
releasing it. Existing SQL, recipient/author checks, signed mentions and the
room/creator race guard remain in the locked section. The complete batch is
still prepared before its first send. There is no new cache, dependency,
transaction change or task-scheduling change.

In a fresh alternating old/new, new/old, old/new comparison, median posting
throughput increased by 1.2%. Each route receives ten seconds of warmup at four
clients and fifteen seconds of measurement at 16 clients:

| Workload | Julia before, req/s | Julia after, req/s | p99 before → after, ms |
|---|---:|---:|---:|
| Room page, cached control | 80,931.9 | 80,971.4 | 0.636 → 0.656 |
| Post a message | 4,650.9 | 4,708.7 | 10.487 → 10.375 |

Posting samples were 4,487.3 / 4,650.9 / 4,725.6 req/s before and
4,635.8 / 4,708.7 / 4,831.8 after. Corresponding pairs improved by 3.3%,
1.2% and 2.2%; the cached-read median changed by +0.05%. This is a modest
observed gain from three short pairs, not proof of statistical significance.
Latency columns are medians of per-run p99s, not pooled percentiles.

The isolated three-recipient check measured:

| Preparation metric | Before | After |
|---|---:|---:|
| Total helper time, µs | 35.486 | 35.260 |
| Julia heap bytes | 20,976 | 20,688 |
| Instrumented uncontended lock hold, µs | 36.081 | 35.076 |

These are medians of seven warmed rounds of 500 calls per image. Each copy
inserts the same deterministic message and sets the room memberships to
`everything` with no active connections; active-user filtering leaves three
eligible subscriptions. Complete subscription/payload hashes match. Total time
and allocations are measured before installing diagnostic wrappers. Lock times
come from separate instrumented rounds, so they should not be subtracted from
the uninstrumented total. The empty timer/counter wrapper costs about 0.073 µs
and allocates no Julia bytes. Timing includes SQLite work; allocation counts
exclude native SQLite memory. Three warmed empty-recipient rounds measure
5,376 → 5,344 bytes.
The snapshot infers as `Union{Nothing, <concrete snapshot>}`. The small byte
reduction includes the new badge vector and building the room path once per
batch.

A separate instrumented full-server check, one ten-second warmup/fifteen-second
measurement per image at 16 clients, verified push completion:

| Timed push-job metric | Before | After |
|---|---:|---:|
| Acknowledged posts = completed jobs | 68,732 | 70,144 |
| Mean preparation lock hold, µs | 55.781 | 51.244 |
| p99 preparation lock hold, µs | 86.748 | 80.267 |
| Mean enqueue-to-completion, ms | 4.037 | 3.962 |
| p99 enqueue-to-completion, ms | 15.799 | 16.051 |
| Maximum unfinished jobs, reconstructed from timestamps | 35 | 34 |
| Unfinished jobs at observed stop | 0 | 0 |

Mean lock ownership falls by 8.1%, while push completion p99 is slightly higher;
this single diagnostic pair does not establish a general tail-latency gain.
Every warmup and measured receipt matches exactly one successful push job by
message ID: 111,105 jobs before and 112,982 after. Each job prepares three
payloads. All sender calls reach the existing local loopback-endpoint rejection,
with no provider fetches or sender errors. This checks payload preparation and
local handling, not real external delivery. The fixture and production sender
remain the same as in the uninstrumented comparison.

The completed-job rate from first enqueue to last finish is 4,581.3 → 4,677.4/s;
including load-driver and confirmed-drain wall time gives 4,558.8 → 4,659.7/s.
These instrumented rates are diagnostic only. Stop polling can lag by up to
50 ms plus driver overhead; timestamp-derived backlog maxima cover the whole
measured epoch. Evidence generation occurs after the drain marker. Together,
the exact completion counts and bounded backlog provide no sign that the
posting gain comes from accumulating unfinished push work.

The modified push tests pass 177 assertions, including encoding while another
task holds the writer lock, unequal badges across multiple devices, and owned
snapshot values after subsequent database mutations. Temporary line/type/lock
coverage probes hit all seven points and were removed. The formatted source
passes the same tests and the unchanged Chromium smoke test; JuliaFormatter
2.14's second pass was unchanged.

The paired comparison validated 11,622,657 responses including warmup, with
zero errors or invalid responses. Independent audits verified all 669,190
acknowledged writes across six databases and twelve receipt files, including
exact IDs, rooms, rich-text bodies and FTS entries. Integrity checks passed;
DB/WAL hashes were unchanged by the audits.

Both images use Julia 1.13.1, SQLite `FULL`, GC enabled, gzip, a 64 MiB response
cache, four default threads plus one interactive thread, server CPUs `0,2,4,6`
and client CPUs `8,10,12,14`. Databases are on `/tmp` tmpfs; this does not measure
durable-disk synchronization. C and Rust were not rerun, and this comparison
covers the room and POST routes rather than all read/mixed workloads.

Baseline is `07b3e2a`, image `campfire-julia:typed-post`; candidate is
`campfire-julia:push-snapshot`. Raw results, exact write receipts, source/image
hashes, diagnostic scripts, test logs and the precommit patch are retained at
`tmp/julia-full-server/2026-10-13-push-snapshot/` (ignored by Git). Runtime
databases, storage and credentials are excluded from the evidence archive.

## Typed message and context rows, 2026-10-13

Fixed row projections increased posting throughput by 4.5% in a fresh,
alternating comparison against the preceding push-row build. Both images use
SQLite `FULL` with GC enabled. Three rounds alternate old/new, new/old, old/new;
each route gets ten seconds of warmup at four clients and fifteen seconds of
measurement at 16 clients:

| Workload | Julia before, req/s | Julia after, req/s | p99 before → after, ms |
|---|---:|---:|---:|
| Room page, cached control | 81,706.5 | 81,531.0 | 0.624 → 0.619 |
| Post a message | 4,439.3 | 4,638.5 | 10.823 → 10.495 |

Posting samples were 4,303.6 / 4,439.3 / 4,453.7 req/s before and
4,567.2 / 4,638.5 / 4,684.3 after. Each corresponding pair improved, by
6.1%, 4.5% and 5.2%. The cached-read median changed by -0.2%. Three short
pairs do not establish statistical significance, and the paired check covers
only these two routes. Container lifetime peak memory was 1,250.6 MiB before
and 1,185.0 MiB after in this check.

This extra comparison was necessary because the original full-route rerun was
inconclusive against the saved measurements. With the previous five-second
warmup/eight-second measurement protocol, posting was essentially unchanged
at 4,503.3 versus 4,506.4 req/s; samples ranged from 4,198.9 to 4,548.6.
Cached reads were also below the saved results:

| Workload | Saved Julia, req/s | New Julia, req/s | p99 saved → new, ms |
|---|---:|---:|---:|
| Room page | 81,853 | 80,802 | 0.644 → 0.681 |
| Messages page | 85,950 | 84,320 | 0.579 → 0.612 |
| Sidebar | 90,456 | 88,814 | 0.467 → 0.538 |
| Search | 88,277 | 83,857 | 0.534 → 0.697 |
| Post a message | 4,506 | 4,503 | 10.671 → 10.679 |

The same full-route rerun with a writer capped at ten posts/second to a separate
room produced:

| Workload | Saved Julia, req/s | New Julia, req/s | Read p99 saved → new, ms | Writer p99 saved → new, ms |
|---|---:|---:|---:|---:|
| Room page | 77,597 | 74,961 | 0.853 → 0.855 | 4.511 → 8.463 |
| Messages page | 82,148 | 80,079 | 0.832 → 0.965 | 7.955 → 8.887 |
| Sidebar | 89,369 | 88,205 | 0.639 → 0.681 | 3.703 → 5.807 |
| Search | 86,151 | 84,809 | 0.730 → 0.839 | 4.559 → 4.571 |

All twelve timed mixed writers acknowledged 80 posts at 9.9 posts/second.
Across them, median writer p99 was 7.135 ms and the largest individual p99
18.671 ms, versus 4.679 and 8.367 ms in the saved run. Container lifetime peaks
were 1,865.4 MiB normally and 1,642.7 MiB with the writer, versus saved peaks of
1,718.1 and 1,596.5 MiB. These cgroup figures include warmup and page cache;
they are not Julia heap measurements. Latency columns throughout are medians
of per-run p99s, not pooled percentiles. The alternating room/POST check does
not settle the other read routes or mixed-writer latency changes.

The implementation uses a concrete `CreatedMessageRow` for freshly inserted
messages and a concrete `Account` for request contexts. Authentication constructs
the existing `User` directly from the SQLite row. All three paths retain the
existing SQL and SQLite.jl parameter binding/string ownership. Nullable fields,
fresh authorization and session activity, legacy account column ordering,
trigger-visible message values and attachment/boost fallback remain covered.
No native bindings, dependencies, cross-request caches or lock-scope changes
were added.

Seven alternating warmed component rounds measured:

| Operation | Time before → after, µs | Julia heap bytes before → after |
|---|---:|---:|
| Authenticate an active user | 12.456 → 9.783 | 8,112 → 6,640 |
| Load account with styles/settings | 8.327 → 7.133 | 5,808 → 5,152 |
| Load and prepare a plain new message | 14.290 → 12.693 | 9,984 → 9,152 |

Authentication/account samples use 2,000 calls per round; message samples use
1,000. Nine authentication/account scenarios preserve user/account fields and
session-activity effects, and five message scenarios preserve complete rows,
presentations and rendered HTML. Missing messages and association fallback
retain their previous allocation. Component timings exclude HTTP, transaction
commits and notification delivery. Julia heap counts exclude native SQLite
allocation; message timing includes presentation preparation but not HTML
serialization.

A fresh profile of the preceding image confirmed generic row conversion in
these paths before implementation. The modified authentication/account and
message/media files pass 299 and 294 assertions respectively in `--project=test`,
including temporary coverage probes that were subsequently removed. The final
formatted source passes the same 593 assertions and the unchanged Chromium
smoke test. JuliaFormatter 2.14's second pass made no changes.

The normal/mixed rerun validated 23,819,693 responses including warmup and
158,326 acknowledged writes. The paired check validated another 11,652,117
responses and 648,218 writes across both images. All responses passed the
unchanged shared contracts with zero errors or invalid responses. Independent
audits verified all 806,544 writes against exact IDs, rooms, rich-text bodies
and FTS entries in twelve databases; integrity checks passed and DB/WAL hashes
were unchanged by the audits.

Both comparisons use the same shared fixture, gzip, 64 MiB response cache,
four Julia workers plus one interactive thread, server CPUs `0,2,4,6` and
client CPUs `8,10,12,14`. Builds, tests and component runs finished before
server timing. Databases remain on `/tmp` tmpfs, so these measurements do not
establish durable-disk synchronization costs. C and Rust were not rerun; the
longer paired measurements should not be substituted into the historical native
comparison as if the protocols were identical.

The candidate image is
`sha256:26fc253402ef3ff7f47ba0c21e310bc0d8524ce2ed05f7828f0b9290f7e96004`,
built from `e7f483c` plus the archived patch. Its runtime source SHA-256 is
`5bffa5b2e92e00e6a1219e9774ae4bb52a947ceb389faeb144f593c23d7ed932`.
The paired baseline uses an isolated checkout and the exact preceding image;
both source trees match their recorded image provenance. The paired adapter
only adds two Julia aliases, their runtime mapping and source-directory selection
on top of the existing adapter; the workload, contracts and auditor are unchanged.
Full and paired results, audits, source snapshots, profiles and checks are under
`tmp/julia-full-server/2026-10-13-typed-post/` (ignored by Git).

## Typed push rows, 2026-10-13

Typed row conversion increased posting throughput from 4,014 to 4,506 req/s
(+12.3%) against the preceding message-creation build. SQLite `FULL`, GC, the
fixture, cache budget and benchmark settings remain unchanged. Medians over
three normal runs:

| Workload | Julia before, req/s | Julia after, req/s | p99 before → after, ms |
|---|---:|---:|---:|
| Room page | 81,100 | 81,853 | 0.651 → 0.644 |
| Messages page | 84,829 | 85,950 | 0.607 → 0.579 |
| Sidebar | 90,117 | 90,456 | 0.481 → 0.467 |
| Search | 87,081 | 88,277 | 0.562 → 0.534 |
| Post a message | 4,014 | 4,506 | 11.583 → 10.671 |

Posting samples ranged from 4,382 to 4,522 req/s. Normal read medians increased
by 0.4–1.4%; three short sequential runs do not establish statistical
significance. The posting gain depends on this fixture's subscribed recipients;
the no-recipient push path is unchanged.

With the writer capped at ten posts/second to a separate room:

| Workload | Julia before, req/s | Julia after, req/s | Read p99 before → after, ms | Writer p99 before → after, ms |
|---|---:|---:|---:|---:|
| Room page | 76,972 | 77,597 | 0.841 → 0.853 | 4.647 → 4.511 |
| Messages page | 81,344 | 82,148 | 0.839 → 0.832 | 5.555 → 7.955 |
| Sidebar | 88,406 | 89,369 | 0.658 → 0.639 | 3.289 → 3.703 |
| Search | 85,040 | 86,151 | 0.809 → 0.730 | 7.919 → 4.559 |

Each timed writer sample acknowledged 80 posts at 9.9 posts/second; warmups
acknowledged 45–50. Across all twelve timed writer samples, median p99 fell from
5.203 to 4.679 ms and the highest individual p99 from 18.959 to 8.367 ms, but
per-route results varied as shown. All latency figures are medians of per-run
p99s, not pooled percentiles. Container lifetime peak memory changed from
1,704.9 to 1,718.1 MiB normally and from 1,602.1 to 1,596.5 MiB with the writer.
These cgroup peaks include page cache and warmup, not just Julia's heap.

Push preparation now projects subscription and message rows into named tuples
with explicit field types. This gives Julia concrete array elements and fields
without rebuilding a heterogeneous tuple for every row. Nullable columns retain
`Missing`, and SQLite.jl still owns parameter binding and copies result strings.
The SQL, read order, authorization checks, room/author race guard, mention
verification and JSON payloads are unchanged. No new C bindings are needed.

For a warmed fixture message with three deliveries, preparation changed from
40.27 to 31.19 µs (22.6% less time) and from 25,328 to 20,864 Julia heap bytes
(17.6% less allocation). Five alternating rounds of 300 calls compare the exact
previous implementation against the new projections. All seven scenarios
produce equal full subscription tuples and JSON payloads, including nullable
keys, mentions, an unnamed direct room, no recipients and a missing message.
No-recipient allocation is unchanged at 5,376 bytes. These component figures
exclude HTTP, scheduling, encryption, network delivery, native SQLite allocation
and the rest of the posting transaction.

Two other experiments were rejected. A membership existence check mostly moved
full-text-index work into COMMIT and made actual membership updates slower.
Disabling SQLite connection mutexes for exclusively leased readers improved the
four-worker cached-handler median by only 1.1%, with overlapping samples and
unchanged allocation, which did not justify using an internal handle adapter.
Neither experiment changes the production server. A concrete delivery-result
vector also offered less than 0.6% component timing improvement and allocated
more for one-delivery cases, so the existing result-vector type is retained.

This uses the preceding harness unchanged: three rounds, a five-second warmup
at four clients followed by eight seconds at 16 clients, gzip, a 64 MiB response
cache, four Julia workers and one interactive thread. Server CPUs are `0,2,4,6`
and client CPUs `8,10,12,14`. Builds, tests and component measurements finished
before full-server timing. The databases are on `/tmp` tmpfs; these results do
not measure durable-disk synchronization costs.

The current result reaches 92% of the historical C posting throughput
(4,884 req/s) and 76% of Rust's (5,922 req/s). Only Julia was rerun. The native
references use SQLite `NORMAL`, while both compared Julia builds use `FULL`.

The modified push test file passes 149 assertions, including nullable fields,
copied-string lifetime, current recipient state, edits and the room/author race
guard. Temporary coverage probes were removed, JuliaFormatter 2.14's second
pass made no changes, and the unchanged Chromium smoke test passed. The full
benchmark validated 24,749,268 responses including warmup, with zero errors or
invalid responses. Independent audits matched all 163,668 acknowledged writes
to exact message IDs, rooms, rich-text bodies and FTS entries in six databases;
integrity checks passed and DB/WAL hashes were unchanged by the audits.

The measured image is
`sha256:3a4f0494a72c93fa8823457f72dd837e5b5b91051f037b918cb89535a6b283b2`,
built from `0b2d6d3` plus the archived patch. Runtime source SHA-256 is
`88457bf73913146ca15fad2f6f0218ca52ca911778df70797121a95bbd93c784`.
Results, receipt audits, baseline profiles, rejected experiments, component
checks, exact source snapshots and validation logs are retained under
`tmp/julia-full-server/2026-10-13-push-rows/` (ignored by Git).

## Message creation and rendering, 2026-10-13

Reducing new-message hydration and rendering work increased posting throughput
from 3,378 to 4,014 requests/second (+18.8%). Both Julia builds use SQLite WAL
with `synchronous=FULL`; GC remains enabled. Median requests/second over three
runs, compared with the preceding push/transport build:

| Workload | Julia before | Julia after | Change | p99 before → after, ms |
|---|---:|---:|---:|---:|
| Room page | 81,301 | 81,100 | −0.2% | 0.673 → 0.651 |
| Messages page | 85,087 | 84,829 | −0.3% | 0.644 → 0.607 |
| Sidebar | 90,161 | 90,117 | ≈0% | 0.498 → 0.481 |
| Search | 87,498 | 87,081 | −0.5% | 0.603 → 0.562 |
| Post a message | 3,378 | 4,014 | +18.8% | 13.871 → 11.583 |

Posting samples ranged from 3,999 to 4,033 requests/second. Read throughput was
roughly unchanged. Latencies are medians of per-run p99s, not pooled percentiles.
Three short sequential runs do not establish statistical significance.

With an additional writer capped at ten posts/second to a separate room:

| Workload | Julia before, req/s | Julia after, req/s | p99 before → after, ms |
|---|---:|---:|---:|
| Room page | 77,126 | 76,972 | 0.863 → 0.841 |
| Messages page | 81,090 | 81,344 | 0.881 → 0.839 |
| Sidebar | 89,013 | 88,406 | 0.683 → 0.658 |
| Search | 85,334 | 85,040 | 0.807 → 0.809 |

Mixed read throughput changed by −0.7% to +0.3%. All twelve timed writer samples
acknowledged 80 posts at 9.9 posts/second; warmup samples acknowledged 45–50.
Writer median p99 changed from 5.269 to 5.203 ms, and the highest individual p99
from 19.503 to 18.959 ms, although per-route results varied. Container lifetime
peak memory changed from 1,709.9 to 1,704.9 MiB normally and from 1,590.6 to
1,602.1 MiB with the writer. These cgroup peaks include page cache and warmup,
not just Julia's heap. Read CPU remained around 382% normally and 376% with the
writer; saturated posting CPU increased from 267% to 291%.

The main harness uses the unchanged shared Rails fixture, release load generator
and route contracts, with three rounds, five seconds of warmup at four clients,
then eight seconds at 16 clients per route. Gzip and the 64 MiB response cache
remain enabled. Four Julia workers and one interactive thread use server CPUs
`0,2,4,6`; client CPUs are `8,10,12,14`. Builds, tests, component benchmarks and
profiling completed before the server timing runs.

New-message hydration now reads the persisted row with indexed guards for
boosts and attachments. The common case avoids the general page-association
queries and temporary collections. Database-trigger changes remain visible;
trigger-created associations fall back to the general path, and known uploads
use it directly. Storage and presentation sanitization remain separate.

Message HTML, boosts and quick-boost forms now write into one per-render buffer.
A small `@html` macro preserves interpolated templates while sending their
parts directly to `print`. Escaping and output bytes are preserved, timestamps
are parsed once when equal, and the current time is computed only when missing.
Ordinary HTTP requests also reuse their parsed URL. No SIMD dependency is needed
for these SQL and string-processing improvements.

Isolated component measurements:

| Component | Julia heap bytes before → after | Median time before → after |
|---|---:|---:|
| Hydrate a plain newly created message | 19,856 → 10,016 | 33.15 → 15.35 µs |
| Render plain message HTML | 19,568 → 11,632 | 9.32 → 6.21 µs |

Hydration uses five alternating rounds of 500 calls on the same copied fixture;
rendering uses seven alternating rounds of 5,000 calls. These exclude HTTP and
network work, and hydration excludes native SQLite allocations. Rendering uses
identical deterministic signing and clock stubs, so it excludes actual HMAC
cost. Trigger-associated messages incur an extra guard query before falling
back (about 6–7 µs in the component checks). The buffer is allocated per render;
neither component is allocation-free or a whole-request allocation measurement.

The SQLite settings check also exposed a difference in the historical native
comparison: Julia used `FULL`, while C and Rust explicitly use `NORMAL`.
`FULL` remains Julia's default, with an explicit `DATABASE_SYNCHRONOUS=NORMAL`
option for comparisons that accept its durability tradeoff. Separate posting
pilots used the same fixture, CPUs, 16 clients, an eight-second warmup and three
eight-second measurements:

| Build / writer setting | Median req/s | Sample range, req/s | Median p99, ms |
|---|---:|---:|---:|
| Previous Julia / FULL, first run | 3,191 | 2,955–3,441 | 16.591 |
| Previous Julia / FULL, repeat | 3,399 | 3,391–3,412 | 13.927 |
| Previous Julia / NORMAL | 3,440 | 3,427–3,472 | 13.583 |
| Current Julia / FULL | 3,929 | 3,899–3,945 | 11.959 |
| Current Julia / NORMAL | 3,990 | 3,989–3,992 | 11.903 |

The same-setting code gain is 15.6% against the repeated FULL pilot and 16.0%
under NORMAL. The current build's NORMAL pilot is only 1.5% above FULL, and the
first baseline FULL run varied substantially. All these runs, including the
historical full-server comparison, place their databases on `/tmp` tmpfs.
They do not measure durable-disk synchronization cost or power-loss durability;
a disk-backed comparison is needed to quantify that tradeoff.

The current FULL result reaches 68% of the historical Rust posting throughput
(5,922 req/s) and 82% of C's (4,884 req/s). C and Rust were not rerun, and their
NORMAL setting differs from this FULL result. The pilot and main harness have
different warmups and must not be combined as one experiment.

Validation passed 599 assertions across the four modified Julia test files,
48 separate old/new renderer byte comparisons across twelve scenarios, and the
unchanged Chromium smoke test. Temporary line probes confirmed the new paths
ran and were removed; JuliaFormatter 2.14 made no changes on its second pass.
The main benchmark validated 24,324,216 responses including warmup, with zero
errors or invalid responses. Independent audits matched all 145,904 acknowledged
writes to exact message IDs, rooms, rich-text bodies and FTS entries across six
databases; database integrity checks passed and the audits left DB/WAL bytes
unchanged. The five separate SQLite pilots also passed an exact audit of
560,344 acknowledgements across their five databases.

The measured build is based on `b0d010d` plus the archived patch, with runtime
source SHA-256
`aba502417dd6c626a60725619548d0a9c13fef00b560114d58dc1cae450641ce`
and Docker image
`sha256:8a01741d07f8fcddb6e71b3888812cb78654615911b056741d5bcae7ffed7d59`.
Raw normal/mixed results, comparisons, receipt hashes, the baseline POST profile,
SQLite pilots, component checks, source snapshots and validation logs are under
`tmp/julia-full-server/2026-10-13-message-create/` (ignored by Git).

## Push preparation and transport overhead, 2026-10-13

Removing unused presentation work from push preparation and reducing per-request
transport work improved posting throughput by 24.5% and reads by 3.7–4.3%.
Median requests/second over three runs:

| Workload | Julia before | Julia after | Change | Rust reference | C reference |
|---|---:|---:|---:|---:|---:|
| Room page | 77,966 | 81,301 | +4.3% | 76,894 | 108,868 |
| Messages page | 82,015 | 85,087 | +3.7% | 73,102 | 112,285 |
| Sidebar | 86,979 | 90,161 | +3.7% | 87,414 | 116,207 |
| Search | 84,073 | 87,498 | +4.1% | 87,199 | 112,151 |
| Post a message | 2,713 | 3,378 | +24.5% | 5,922 | 4,884 |

Julia reaches 100–116% of the earlier Rust read throughput and 75–78% of C's.
Posting reaches 57% of Rust's and 69% of C's, so a substantial write gap remains.
Only Julia was rerun; the preceding Julia and native results are historical
references. Three short sequential runs do not establish statistical significance.
Current posting samples ranged from 3,375 to 3,407 requests/second. Median posting
p99 fell from 17.711 to 13.871 ms; all four normal read p99s also fell.

With an additional writer capped at ten posts/second to a separate room:

| Workload | Julia before, req/s | Julia after, req/s | p99 before → after, ms |
|---|---:|---:|---:|
| Room page | 74,252 | 77,126 | 0.817 → 0.863 |
| Messages page | 78,319 | 81,090 | 0.928 → 0.881 |
| Sidebar | 86,285 | 89,013 | 0.730 → 0.683 |
| Search | 82,694 | 85,334 | 0.845 → 0.807 |

All twelve timed writer samples acknowledged 80 posts at 9.9 posts/second;
warmup samples acknowledged 44–50. Writer median p99 increased from 4.537 to
5.269 ms, and the highest individual p99 increased from 14.159 to 19.503 ms.
Latency figures are medians of per-run p99s, not pooled percentiles.
Normal-profile container lifetime peak memory increased from 1,674.9 to
1,709.9 MiB; mixed-profile peak increased from 1,545.5 to 1,590.6 MiB.
These cgroup peaks include page cache and warmup, rather than measuring Julia's
heap alone. Read CPU remained around 382% normally and 376% with the writer.

Push preparation now selects current eligible subscriptions first, loads only
message text and author/room labels, and checks signed mentions only when needed.
It avoids building a rendering context, sanitizing unused HTML, signing avatar
URLs, or querying presentation associations. Payloads and recipients still use
current database state. A room/creator check prevents an external SQL move
between queries from pairing new message data with the old recipient list.
The transport caches the actual socket peer string per connection and removes
an intermediate header buffer while retaining HTTP.jl's serializer and the
existing 64 KiB bound and fallback paths.

On a warmed fixture message with three eligible subscriptions, push preparation
allocated 25,472 Julia heap bytes versus 56,992 before, with median time falling
from 99.40 to 45.98 µs. These are five alternating rounds of 500 preparations,
with equal recipient IDs and JSON payloads; they exclude network delivery and
native SQLite allocations. With no eligible subscriptions, allocation fell from
42,560 to 5,376 bytes. Separately, warmed preparation and serialization of the
same synthetic response with a 14,223-byte body fell from 3,440 to 2,560 bytes.
That measurement excludes request construction, handlers, task creation
and socket I/O. Neither component measurement is a whole-request allocation count.

The full-server fixture, verification revision, release load generator, CPU
affinity, four-worker allocation, gzip, five-second warmup, eight-second timed
sample and 16-client concurrency match the preceding comparison. GC remains
enabled and the response cache stays limited to 64 MiB. Builds, profiling and
tests stopped before timing. All 306 assertions in the two modified test files
passed, including fresh push eligibility/payloads, external message moves,
keepalive/WebSocket peer identity, buffer ownership and HTTP framing. Temporary
line probes confirmed the new paths ran and were removed before clean validation.
The unchanged Chromium smoke test passed, and JuliaFormatter was idempotent.

The comparison validated 24,067,638 responses including warmups, with zero errors
or invalid responses across 54 primary invocations and 24 nested writer samples.
The 16,323,251 timed responses include 960 paced writes. All 123,575 acknowledged
writes, including warmups, were independently reconciled against exact persisted
IDs, rooms, rich-text bodies and FTS bodies across six databases. Integrity checks,
receipt hashes and the unchanged upstream acknowledged-write auditor all passed.

The candidate image is
`sha256:d42f5b3e6d2a4ffc77244b5c58d9fcc3bb06bc2e8e6f0af2bc4ccd7b1adf7c2b`,
built from the working tree based on `5b8c6c2`; its runtime source digest is
`d210404ff1b48c43f5e5a9d69bb8c3ac70162395e58a77428bfd5c5180b0cd5a`.
Raw samples, receipts and hashes, source snapshots, component measurements,
profiles, test logs and comparison analysis are retained under
`tmp/julia-full-server/2026-10-13-push-transport/` (ignored by Git).

## Reusable response buffers and full-server comparison, 2026-10-12

Moving response serialization onto workers and sending headers and body in one
socket write improved read throughput by 34–41%. A private per-connection buffer
avoids allocating a new response-sized byte array for every request. The
HTTP.jl serializer, parser, connection lifecycle and WebSocket handling remain
in use. Median requests/second over three runs:

| Workload | Julia before | Julia after | Change | Rust reference | C reference |
|---|---:|---:|---:|---:|---:|
| Room page | 58,364 | 77,966 | +33.6% | 76,894 | 108,868 |
| Messages page | 59,947 | 82,015 | +36.8% | 73,102 | 112,285 |
| Sidebar | 61,889 | 86,979 | +40.5% | 87,414 | 116,207 |
| Search | 60,840 | 84,073 | +38.2% | 87,199 | 112,151 |
| Post a message | 2,780 | 2,713 | −2.4% | 5,922 | 4,884 |

Reads are now close to or above the earlier Rust measurements. C still leads
on all measured routes, and posting remains substantially slower than either
native implementation. Only Julia was rerun: the preceding Julia and native
results are historical references, and three short sequential runs do not
establish statistical significance. Current read ranges were 77,852–78,205 for
rooms, 81,691–82,214 for messages, 86,766–87,183 for sidebar, and 84,036–84,654
for search. Posts ranged from 2,698 to 2,720 requests/second.

With an additional writer capped at ten posts/second to a separate room:

| Workload | Julia before, req/s | Julia after, req/s | p99 before → after, ms |
|---|---:|---:|---:|
| Room page | 54,876 | 74,252 | 1.006 → 0.817 |
| Messages page | 57,282 | 78,319 | 0.974 → 0.928 |
| Sidebar | 60,928 | 86,285 | 0.819 → 0.730 |
| Search | 59,289 | 82,694 | 0.909 → 0.845 |

All twelve timed writer samples acknowledged 80 posts at 9.9 posts/second.
Their median p99 was 4.537 ms; the highest individual p99 was 14.159 ms.
Latency figures are medians of per-run p99s, not pooled percentiles.

The normal workload has tradeoffs: room p99 increased from 0.589 to 0.683 ms,
messages from 0.603 to 0.673 ms, and search from 0.616 to 0.657 ms. Sidebar p99
fell from 0.616 to 0.605 ms and posting from 18.079 to 17.711 ms. Normal-profile
container lifetime peak memory increased from 1,463.2 to 1,674.9 MiB; the mixed
profile increased from 1,353.6 to 1,545.5 MiB. These are cgroup peaks including
page cache and warmup, not Julia heap sizes. Read CPU remains around 382% in
the normal workload. This change improves read throughput, not peak memory or
every latency metric.

The fixture, verification revision, release load generator, CPU affinity,
four-worker allocation, gzip, five-second warmup, eight-second measurement and
16-client concurrency match the preceding comparison. Builds, profiling and
tests stopped before timing. GC remains enabled and the shared response cache
is still limited to 64 MiB.

For a synthetic 14,223-byte materialized response, warmed response preparation
and serialization allocate 3,440 Julia heap bytes versus 2,560 before this
change. This excludes request construction, the handler, task creation and
socket I/O. It is not a zero-allocation transport: small headers and metadata
still allocate. An intermediate version allocating a new wire buffer required
18,128 bytes for the same operation and had worse read tail latency; that
experiment was superseded. The previously measured cached-handler allocation
of 2,544 bytes is a separate measurement. Tests also verify that warming the
buffer removes body-sized allocation when the body grows to 32 KiB.

All 183 assertions in the changed transport test passed, including byte framing,
binary/gzip bodies, keepalive and pipelining, `100 Continue`, oversize fallback,
concurrent buffer ownership, stalled writes and shutdown. Temporary line probes
confirmed execution of the new paths and were removed before clean validation.
The unchanged Chromium smoke test passed, and JuliaFormatter was idempotent.
The full comparison validated 23,876,527 responses including warmups, with zero
errors or invalid responses across 54 primary invocations and 24 nested writer
samples. The 15,731,427 timed responses include 960 paced writes; all 100,090
acknowledged writes including warmups were reconciled against persisted
message IDs, bodies, rooms, rich text and FTS entries.

The candidate image is
`sha256:1259dd132f53acd1b5f49cc4e05940602161255266e08270249c0ab391b9e936`,
built from the working tree based on `3878bd7`; its runtime source digest is
`ac6da06ab653000aa5bff32ac82e8019e8c41c5fe503d91012e11c27b7226c66`.
Raw samples, write receipts and hashes, source snapshots, allocation and profile
evidence, test logs and comparison analysis are retained under
`tmp/julia-full-server/2026-10-12-reused-response/` (ignored by Git). The incomplete
allocating-buffer experiment is retained separately under
`tmp/julia-full-server/2026-10-12-worker-wire/` and excluded from these totals.

## Inference fixes and full-server comparison, 2026-10-12

Removing boxed request variables, typing queued event payloads, and specializing
fixed-schema SQLite operations reduced Julia heap allocation in the warmed
cached handler from 7,968 to 2,544 bytes/request (68%). Full-server throughput
improved modestly, by 1.9–3.0% in the normal workload. Median requests/second
over three runs, compared with the preceding parallel-server measurements:

| Workload | Julia before | Julia after | Change | p99 before → after, ms |
|---|---:|---:|---:|---:|
| Room page | 57,225 | 58,364 | +2.0% | 0.727 → 0.589 |
| Messages page | 58,518 | 59,947 | +2.4% | 0.703 → 0.603 |
| Sidebar | 60,748 | 61,889 | +1.9% | 0.701 → 0.616 |
| Search | 59,651 | 60,840 | +2.0% | 0.722 → 0.616 |
| Post a message | 2,700 | 2,780 | +3.0% | 18.783 → 18.079 |

With the additional writer capped at ten posts/second to a separate room:

| Workload | Julia before, req/s | Julia after, req/s | p99 before → after, ms |
|---|---:|---:|---:|
| Room page | 53,717 | 54,876 | 1.432 → 1.006 |
| Messages page | 55,748 | 57,282 | 1.309 → 0.974 |
| Sidebar | 60,147 | 60,928 | 0.910 → 0.819 |
| Search | 57,735 | 59,289 | 1.241 → 0.909 |

Only the Julia candidate was rerun. Earlier Julia, Rust and C measurements are
historical references; these short three-run comparisons do not establish
statistical significance. The latency values are medians of per-run p99s.
Fixture, verification revision, load-generator binary, CPU affinity, four-worker
allocation, gzip, five-second warmup, eight-second measurement and 16-client
concurrency match the previous comparison. Builds and tests stopped before
timing. GC stays enabled and the shared response-cache budget remains 64 MiB.

Reads still use approximately 380% CPU. Normal-profile container lifetime peak
memory was effectively unchanged, 1,464.3 → 1,463.2 MiB; the mixed-profile peak
was 1,338.0 → 1,353.6 MiB. These cgroup figures include page cache and warmup.
Lower allocation per request has not translated into lower peak container
memory, and most of the C/Rust throughput gap remains.

### Allocation and inference checks

| Warmed operation | Julia heap bytes before → after | Allocations before → after |
|---|---:|---:|
| Cached `handle_request` | 7,968 → 2,544 | 171 → 45 |
| Current session and membership query | 2,160 → 0 | 57 → 0 |
| Database generation check | 928 → 0 | 20 → 0 |
| BEGIN plus COMMIT | 1,344 → 0 | 26 → 0 |

These measurements reuse a request in process and exclude socket parsing,
transport task creation, and native SQLite/OpenSSL allocation. The SQLite text
binder uses `SQLITE_TRANSIENT`, which copies text in native memory. Session and
membership checks still read current database state on every cache hit.
The fixed-schema helper retains SQLite.jl's statement ownership, resets and
clears bindings on success and failure, and avoids constructing query metadata.
It accesses SQLite.jl 1.8.3 internals; rerun `test/julia_web_sqlite.jl` when
upgrading SQLite.jl. Generic writes retain SQLite.jl's parameter binding.

Compiler IR confirms that `handle_request` no longer captures `Core.Box`
variables. `cache_generation!` now infers `Int64` and has no JET reports.
Authorization returns a concrete small union, and event payloads use a finite
union with branch-specific types. Actual JuliaC `--trim=safe` checks no longer
report the targeted handler, generation or event-payload failures. The complete
handler still fails safe trimming because of dynamic rows, rendering, request
input and dependency code. Logging-only diagnostics were set aside; no unsafe
trimming or verifier bypass was used. Better inference exposes more of the
call graph, so raw diagnostic totals are not a measure of progress.

All 394 assertions in the four changed test files passed, including binding
lifetime, error recovery, live authorization, reader ownership, method overrides
and WebSockets. The unchanged Chromium smoke test passed. All 54 primary load
invocations and 24 nested writer samples had zero errors and invalid responses:
18,423,158 validated responses including warmups, 11,433,013 timed responses,
and 102,879 acknowledged writes reconciled against exact SQLite/FTS records.
Every timed paced-writer sample acknowledged 80 posts at 9.9 posts/second.

The candidate image is
`sha256:6fa3ca9b2595b531e31508000334dba21ad16315f19aae0dd157c5e8066d9277`,
built from the working tree based on `366ffe0`; its runtime source digest is
`f7da644e1a33fb51d8bb1fe8da20dbe035dd1d682e76ec2206af6e97f44ef73e`.
Raw samples, exact write receipts with hashes, inference/allocation reports,
test logs and comparison analysis are retained under
`tmp/julia-full-server/2026-10-12-inference-fixed/` (ignored by Git).

## Earlier parallel-server comparison, 2026-10-12

Read throughput doubled after moving application work to worker threads, adding
exclusive SQLite readers, and sending known response lengths to avoid extra
chunk-framing socket writes. The shared cache budget remains 64 MiB, and GC
remains enabled. Median requests/second over three runs:

| Workload | Julia before | Julia now | Speedup | Rust reference | C reference |
|---|---:|---:|---:|---:|---:|
| Room page | 27,848 | 57,225 | 2.05× | 76,894 | 108,868 |
| Messages page | 27,902 | 58,518 | 2.10× | 73,102 | 112,285 |
| Sidebar | 30,276 | 60,748 | 2.01× | 87,414 | 116,207 |
| Search | 29,452 | 59,651 | 2.03× | 87,199 | 112,151 |
| Post a message | 2,627 | 2,700 | 1.03× | 5,922 | 4,884 |

Only Julia was rerun in this optimization pass. Rust and C are the earlier
reference measurements documented below, using the same machine and fixture.
Their read-throughput leads over Julia shrink from 2.62–2.96× to 1.25–1.46×
for Rust, and from 3.81–4.02× to 1.88–1.92× for C. Julia's three-run ranges were
56,793–57,317 for room pages, 58,508–58,532 for messages, 60,469–60,766 for the
sidebar, 59,438–59,682 for search, and 2,685–2,745 for posts.

With an additional writer capped at ten posts/second to a separate room:

| Workload | Julia before, req/s | Julia now, req/s | p99 before → now, ms |
|---|---:|---:|---:|
| Room page | 26,469 | 53,717 | 3.069 → 1.432 |
| Messages page | 26,652 | 55,748 | 2.555 → 1.309 |
| Sidebar | 29,544 | 60,147 | 1.145 → 0.910 |
| Search | 28,709 | 57,735 | 1.408 → 1.241 |

Every timed writer again acknowledged 80 posts and reported 9.9 posts/second.
The latency values are medians of per-run p99s, not pooled percentiles.

There are costs. Normal-profile room p99 increased from 0.617 to 0.727 ms, and
post p99 from 13.047 to 18.783 ms. Reads now use about 381% CPU versus 100%,
with the same four-core allocation. Maximum observed normal-profile container
memory increased from 576.7 to 1,464.3 MiB. Those are cgroup lifetime peaks,
including page cache and warmup, not heap allocation counts. This improves
throughput and latency under the paced writer; memory use and posting latency
still need work.

### What changed and what was checked

Each reader owns its SQLite statements, cache, signing-key dictionary and
connection-local observer epoch. Every cache hit still checks the current
session, user status, role and room membership. Combined authorization queries
return concrete Julia fields. Session activity and event delivery stay on the
writer. Lazy media generation and deletion share a storage lock, and encoded
variants become visible through atomic rename.

Profiling showed why putting complete connections on worker threads regressed:
Julia's global I/O lock became a bottleneck. Keeping I/O on the interactive
thread and dispatching application work to workers improved the diagnostic run;
explicit Content-Length removed further writes. Native token parsing and
verification also improved from 2.097 to 1.238 µs, reducing Julia heap allocation
from 5,072 to 560 bytes per call. These isolated allocation figures exclude
OpenSSL's native allocations; the complete request path still allocates.

768 focused assertions passed, covering authorization, invalidation, reader
ownership, shutdown, HTTP framing, WebSockets and concurrent media access.
The unchanged Chromium smoke test passed. The two benchmark profiles validated
17,579,923 responses including warmups, with 11,190,998 timed responses, and
reconciled 98,587 acknowledged writes against exact SQLite/FTS records.
All 54 primary load-generator invocations and their 24 nested mixed-writer
samples had zero errors and zero invalid responses.

The hardware, affinity, fixture, load generator, contracts, five-second warmup,
eight-second measurement and 16-client concurrency match the baseline below.
Three Julia rounds were run per profile, with fresh disposable data each round;
all builds and tests stopped before timing. `JULIA_NUM_THREADS=4` under Julia
1.13.1 supplies four default workers and one interactive thread. The production
image is `sha256:1f538fb653d6755f5cb1fd992354d2ae9a31a18cfbf2734eb5c4c92180303053`,
built from the working tree based on `9ea9bf1`; its runtime source digest is
`95d18a144a40d616c6e74b32712cd30677e0b186b7787989377b827363f2323b`.
Maximum observed load-generator CPU was 68.94%, with four cores available.

Raw samples, exact write receipts with hashes, source/image metadata, diagnostic
profiles and before/after analysis are retained under
`tmp/julia-full-server/2026-10-12-parallel/`. The earlier results remain under
`tmp/julia-full-server/2026-10-12/`. These artifacts are ignored by Git.

## Baseline full-server comparison, 2026-10-12

The initial Julia server was slower than the C and Rust implementations on this
workload. These measurements include real HTTP, authentication, SQLite, gzip,
and message persistence, using the same shared fixture and response contracts.
Each cell shows median requests/second followed by the three-run minimum–maximum.

| Workload | Julia | Rust | C |
|---|---:|---:|---:|
| Room page | 27,848 (27,691–28,046) | 76,894 (75,516–77,352) | 108,868 (101,449–109,919) |
| Messages page | 27,902 (27,791–28,206) | 73,102 (72,981–74,166) | 112,285 (111,338–121,821) |
| Sidebar | 30,276 (30,018–30,299) | 87,414 (87,086–88,835) | 116,207 (114,772–121,438) |
| Search | 29,452 (29,441–29,869) | 87,199 (87,160–87,634) | 112,151 (111,539–117,793) |
| Post a message | 2,627 (2,607–2,668) | 5,922 (5,914–5,945) | 4,884 (4,808–4,908) |

With one additional writer capped at ten posts/second to a separate room,
median read throughput was:

| Workload | Julia | Rust | C |
|---|---:|---:|---:|
| Room page | 26,469 | 71,822 | 95,445 |
| Messages page | 26,652 | 69,745 | 101,973 |
| Sidebar | 29,544 | 87,378 | 114,572 |
| Search | 28,709 | 86,899 | 110,730 |

Every timed writer sample acknowledged 80 posts and reported 9.9 posts/second.
This profile exercises cross-room cache invalidation. It does not measure
WebSocket fanout or a room with many actively posting users.

The following latency values are medians of the three per-run p99s, in
milliseconds; they are not pooled percentiles:

| Workload/profile | Julia | Rust | C |
|---|---:|---:|---:|
| Room page, normal | 0.617 | 0.395 | 0.314 |
| Post a message, normal | 13.047 | 4.147 | 4.391 |
| Room page, with paced writer | 3.069 | 0.424 | 0.364 |

Julia used approximately one CPU core despite having four available. C and Rust
used most of their four-core allocation. Julia's initial request path
serialized database work through one connection and one application lock; cache
miss rendering also held that lock. The observed CPU use and larger latency
increase under writes motivated the concurrency changes measured above. These results do not isolate GC cost.
GC was enabled throughout.

Maximum observed container memory peaks during the normal profile were
576.7 MiB for Julia, 167.8 MiB for Rust and 84.3 MiB for C. These are cgroup
lifetime peaks including page cache, not Julia heap allocations or process RSS.
No aggregate load-generator CPU saturation was observed: its maximum was about
103%, with 400% available across four allocated cores.

### Method and provenance

Intel Core i7-12700K, 32 GB RAM, Linux 7.2.5; existing `powersave` governor.
Servers ran sequentially in Docker with host networking on CPUs `0,2,4,6`:
four distinct performance cores. The load generator used four other performance
cores, `8,10,12,14`, with no shared SMT siblings. Each profile used three rotating
rounds, five seconds of warmup at four clients, eight seconds of measurement at
16 clients, gzip, and fresh fixture copies per application/round. Builds and
tests had stopped before timing. Database and attachment copies were on `/tmp`
tmpfs for every implementation; this is not an SSD throughput measurement.

| Implementation | Source revision | Production configuration |
|---|---|---|
| Julia | `f5853f0ab77490602d36fcc4e7e30052f5a0f1be` | Julia 1.13.1; `JULIA_NUM_THREADS=4`; one process/DB connection; 64 MiB response cache |
| Rust | `6838ead05391bd287a3b0bdd14904d0a5b44ad8a` | Official Rust 1.98.1 image; release LTO; five DB readers; three job workers; 64 MiB response and 32 MiB fragment caches |
| C | `873a51f523de5a0cc235884e5725cfb5521d2027` | Clang 22.1.8, `-O3 -flto`; four HTTP loops/readers; two job workers; 64 MiB response cache |

The verification revision and pinned Rails fixture are the ones listed above.
All eight preflight contracts passed for each image. The normal and mixed
profiles together validated 62,768,504 responses, including 42,169,371 timed
responses, and audited 504,448 exact persisted writes. All 162 warmup/timed
samples had zero errors and zero invalid responses. SQLite/FTS write audits
reconciled every acknowledgment. Julia's mixed warmups posted fewer messages
while compiling; its timed writer samples all reached the requested cap.

This compares production implementations, whose HTML and runtime topology
differ. For example, the decoded room page was 216,645 bytes for Julia,
416,121 for Rust and 412,696 for C; compressed sizes were approximately
14.2, 24.2 and 21.3 kB respectively. All passed the same content contract.
The C benchmark image follows its committed image recipe and omits external
media transformation executables; the fixture's existing processed avatar
passed validation. Fresh media transformations are outside these timed routes.

Raw summaries, per-sample metrics, machine/build metadata and hashed write
receipts are retained locally under the ignored
`tmp/julia-full-server/2026-10-12/` directory at the repository root.

### Reproduce

These commands measure the current checkout. Build each production image and
the shared release load generator first. Put
the C and Rust checkouts under `WORKSPACE/once-campfire-c` and
`WORKSPACE/once-campfire-rust`. Generate `FIXTURE` with the shared `bin/seed`.
The adapter uses this checkout for Julia; `JULIA_SOURCE` overrides that path.

```sh
docker build -f julia/Dockerfile -t campfire-julia:parallel .
export JULIA_IMAGE=campfire-julia:parallel
export C_IMAGE=campfire-c:local
export RUST_IMAGE=campfire-rust:bench-6838ead
export BENCH_ENV_FILE="$FIXTURE/reference.env"
export JULIA_BENCH_ENV='{"JULIA_NUM_THREADS":"4"}'

ruby julia/bench/compare.rb "$VERIFICATION" \
  --apps julia,c,rust --workspace "$WORKSPACE" --seed "$FIXTURE" \
  --cpus 0,2,4,6 --client-cpus 8,10,12,14 --rounds 3 \
  --warmup 5 --duration 8 --concurrencies 16 \
  --routes room_show,messages_page,sidebar,search,post_message \
  --output tmp/julia-full-server/normal --keep_runtime
```

For the mixed profile, use the four read routes, add `--mixed-write-rate 10`,
and choose a new output directory. Adjust CPU lists to the actual physical-core
topology of your machine. The adapter retains the unchanged upstream load
generator, contracts and write auditor. Its narrow registration/configuration
changes reject unexpected source layouts and record the original, adapted and
adapter source hashes. It also records immutable image IDs, Julia runtime source
hashes, and best-effort cgroup CPU/memory counters outside request timing.

## Earlier performance prototype

The small bearer-token prototype is retained separately from the browser server:

```sh
julia --project=julia -e 'using Campfire; println(Campfire.seed!("/tmp/campfire-demo.sqlite3"))'
julia --project=julia julia/server.jl --prototype /tmp/campfire-demo.sqlite3 3001
curl -H 'Authorization: Bearer TOKEN' http://127.0.0.1:3001/rooms/1
```

Its schema is a subset of Rails and is intended for disposable experiments. The
measurements below describe that prototype and the isolated rendering kernels,
not the full server.

## Reproduce the measurements

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate()'
julia --project=test test/julia_rendering.jl
julia --project=test test/julia_backend.jl
julia --project=test test/julia_benchmark.jl
julia --project=test test/julia_handler_benchmark.jl

# Linux: pin to an otherwise idle performance core available on your machine.
taskset -c 2 julia --project=julia -O3 --cpu-target=native julia/bench/render.jl --output /tmp/render-results.toml
julia --project=julia julia/bench/backend.jl --output /tmp/backend-results.toml
```

`test/runtests.jl` includes these Julia tests; each file also runs independently.
The renderer benchmark uses `CC` (default `cc`) and `rustc` when available.
C uses `-O3 -march=native`; Rust uses `-C opt-level=3 -C target-cpu=native`.
All implementations receive the same runtime UTF-8 fixtures and caller-owned
buffers. It verifies identical output, warms every specialization, consumes
output bytes, rotates execution order, and reports medians and individual samples.
Fixtures cover plain text, ordinary text with markup, and dense escaping.
There is a simple scalar Julia baseline as well as the SIMD-assisted renderer.

`@allocated` measures Julia's heap, not native-library allocations. The C and Rust
benchmark kernels themselves do not call an allocator. The backend's SQLite and
HTTP paths do allocate; do not extend the renderer's zero-allocation claim to them.
Compilation, fixture construction and buffer growth are outside warmed timings.

### Local results, 2026-10-12

Intel i7-12700K, pinned to CPU 2; Julia 1.13.1 at `-O3 --cpu-target=native`,
GCC 16.2.1 and rustc 1.97.1 with the flags above. Medians of nine rotated samples
of 4,000 operations on repeated, cache-resident fixtures; all outputs checked.
These compare the equivalent kernels in `bench/`, not full Campfire applications.

| Work (µs/operation; lower is better) | Julia SIMD scan | C | Rust |
|---|---:|---:|---:|
| Escape plain text | 0.289 | 0.309 | 0.285 |
| Escape mixed text | 10.517 | 12.259 | 8.361 |
| Escape dense metacharacters | 4.209 | 5.656 | 4.390 |
| Render 40 plain messages | 2.143 | 0.971 | 1.134 |
| Render 40 mixed messages | 13.657 | 11.672 | 11.407 |
| Render 40 dense messages | 6.336 | 5.496 | 5.281 |

All warmed kernels report zero Julia allocation bytes. The scalar Julia baseline
and individual samples are included in the generated TOML. Most sample IQRs are
1–2% of the median; treat the small plain/dense Julia–Rust escaping differences
as parity. Julia remains slower on full simplified message rendering. In
particular, native benchmark writers trust the caller's capacity guarantee;
Julia retains buffer capacity/alias checks. Both reuse storage.

The sequential Julia handler benchmark, with 500 operations per sample and seven
samples on the same CPU model, reports:

| Route | Cache disabled | Cache warm | Warm Julia allocation bytes/request |
|---|---:|---:|---:|
| Room | 74.7 µs | 8.11 µs | 6,080 |
| Messages | 70.5 µs | 8.41 µs | 6,704 |
| Sidebar | 9.76 µs | 7.01 µs | 4,864 |
| Search | 168.6 µs | 7.12 µs | 5,520 |

This is not an HTTP requests-per-second measurement. It includes fresh SQLite
authentication and authorization but excludes request construction, sockets,
HTTP parsing, gzip and writes. It uses HTTP.jl 1.11.0 and SQLite.jl 1.8.3. The next
allocation targets are the database result wrappers and per-request HTTP objects.

## Why Julia can do this without manual memory management

Most of the application is ordinary functions over concrete structs. The compiler
specializes those functions for their argument types. A `Vector{UInt8}` is allocated
once and reused with `reset!`; escaping and integer formatting write directly into
it. `finish` copies only when a response must outlive the next buffer reuse.
There are no temporary strings, interpolated message IDs, or growing arrays in the
warmed rendering loop. GC stays enabled.

The escaping kernel uses an independent `@simd` byte scan to detect clean text,
then copies it in bulk. Text needing escaping takes a scalar output loop: output
positions depend on the preceding characters, so annotating that loop with
`@simd` or `@turbo` would be incorrect. Bounds checks are removed only inside
loops whose capacity and indexing have already been checked. Unicode bytes pass
through unchanged. The API rejects overlapping source and destination buffers.

LoopVectorization is not required for this kernel: Julia's own compiler emits SIMD
for the scan. Adding a package or aggressive annotation should earn its place in
the measured workload. Database calls, HTTP parsing, compression, and cache behavior
will matter more to the eventual application result than numerical-loop tricks.
See Julia's [performance tips](https://docs.julialang.org/en/v1/manual/performance-tips/)
and LoopVectorization's [loop restrictions](https://github.com/JuliaSIMD/LoopVectorization.jl#warning).

## Prototype cache ownership and correctness

One `Store` owns its prepared read/transaction statements and reusable buffer.
A lock serializes its work; no mutable buffer is indexed by `Threads.threadid()`.
Cached byte vectors are immutable by convention and remain valid while HTTP sends
them. The default budget is 64 MiB of response payload, with at most 512 entries
and bounded request targets. Set `cache_budget=0` to disable caching. The budget
does not include Julia/SQLite metadata or the retained rendering scratch buffer.

Every request rechecks the session, user status, and room membership inside the
same SQLite transaction used for rendering. A dedicated observer connection checks
`PRAGMA data_version` before authentication, at cache lookup, and at admission.
Both local commits and other writers invalidate cached responses. Tests cover
external edits, revoked membership, banned users, deleted sessions, rollback after
a failed write, cache bounds, and real TCP round trips. The single-store lock is a
deliberate first-stage limitation, not a scalable four-core serving design.


The full server uses the same observer-epoch rule, fresh authorization and bounded
cache ownership. It caches identity and gzip encodings with a 64 MiB byte budget
and a 512-entry limit. Cache hits read only authorization fields and reuse immutable
response bytes; cache misses construct the full template context. Responses vary
by session, public origin and request target. A separate SQLite observer detects
both internal and external commits. This design is covered by the full-server
HTTP and websocket authorization tests.
