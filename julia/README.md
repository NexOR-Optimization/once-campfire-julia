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
| `JULIA_NUM_THREADS` | Julia thread pools; use `4,1` for four workers and one I/O thread (Docker defaults to `auto`) |
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

HTTP socket I/O and parsing stay on one interactive thread. Application requests
run on the default worker pool. Room, message, sidebar and search GETs borrow
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
