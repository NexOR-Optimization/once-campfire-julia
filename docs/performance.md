# HTTP performance

One matched five-route run put Julia near C on cached reads and ahead on message
posting throughput, with substantially higher memory use and worse POST tail
latency. These are measurements of a **historical revision**, not the current
checkout, and not a general comparison of the languages.

The table uses only the complete run started on **2026-10-15 at 08:09 UTC**.
Julia's measured revision is
[`8a4feb2f`](https://github.com/blegat/once-campfire-julia/commit/8a4feb2f27af0929290f0c8162d85f28784055a4) in this repository's filtered history
(original revision `76fb004e61252f58f18187b62e5bd8ee50e72bb9`).
The later request-parameter parsing change is absent from that revision.
Later three-route runs and exploratory pilots are not combined with this table.
Rust was not run in this comparison.

| Workload | Julia requests/s | C requests/s | Julia / C | Julia p99, ms | C p99, ms |
|---|---:|---:|---:|---:|---:|
| Cached room | 103,492 | 104,823 | 0.987× | 0.227 | 0.321 |
| Cached messages page | 109,795 | 110,921 | 0.990× | 0.236 | 0.314 |
| Cached sidebar | 117,438 | 116,795 | 1.006× | 0.196 | 0.271 |
| Cached search | 111,165 | 114,767 | 0.969× | 0.247 | 0.282 |
| Post message | 6,130 | 4,747 | 1.291× | 11.495 | 4.479 |

Each number is the median of three runs. The latency column is the median of
three per-run p99s, not a percentile computed from pooled requests. Small read
throughput differences should not be treated as established wins.

Julia's maximum recorded container-lifetime memory peak was **3,048.4 MiB**,
compared with **108.2 MiB** for C. These cgroup counters include startup, JIT,
warmup and preceding routes; they are neither steady-state RSS nor per-request
allocation measurements. Julia's POST p99 was about 2.57× C's despite its higher
throughput. Both limits matter when interpreting the table.

## What was measured

- **Machine:** Intel Core i7-12700K, 20 logical CPUs / 12 physical cores,
  33,476,227,072 bytes of RAM; Linux `7.2.5-3-omarchy`. The selected CPUs used the
  `powersave` governor. Server affinity was `0,2,4,6`; clients used
  `8,10,12,14`, on different physical cores of the same host.
- **Julia:** version `1.13.1`, one process, `JULIA_NUM_THREADS=2,2`: two default
  worker threads and two interactive I/O threads. The recorded probe found two
  GC threads and two exclusive query-only database readers. GC stayed enabled.
- **C:** commit
  [`873a51f523de5a0cc235884e5725cfb5521d2027`](https://github.com/basecamp/once-campfire-c/commit/873a51f523de5a0cc235884e5725cfb5521d2027),
  optimized `clang -O3` / LTO build, one process and four HTTP loops.
- **Workload:** host networking, gzip, 64 MiB response-cache budgets, and a fresh
  copy of the same generated fixture for each application-round. Routes ran in
  table order. Every route warmed for 10 seconds at four clients, then measured
  for 15 seconds at 16 clients.
- **Storage:** disposable SQLite databases on `/tmp` tmpfs. Both writers used
  `NORMAL`; C configures all handles that way, while Julia's query-only
  readers/observers retain their existing settings. This is not persistent-disk
  synchronization performance.

The actual run also contained Julia `4,0`, with the same Julia image. Application
order rotated `C / Julia 4,0 / Julia 2,2`, then `Julia 4,0 / Julia 2,2 / C`, then
`Julia 2,2 / C / Julia 4,0`. All 90 raw samples, including that configuration and
warmups, are retained in the [evidence bundle](benchmarks/2026-10-15-matched-http/).
The displayed table selects C and Julia `2,2` from this single run.

This is an authenticated, warm-cache HTTP workload, not a concurrent-user,
WebSocket, cold-start or uncached-rendering capacity result. Posted messages
were checked for persistence and search indexing. HTTP acknowledgements do not
establish identical background-job completion or real-provider push delivery.
Responses satisfy the same route contracts but can differ in bytes and markup.
The preflight machine snapshot does not establish host isolation throughout the
run, and these short samples have no statistical confidence interval.

## Evidence and validation

The complete three-configuration run validated **85,873,050 responses**, including
**58,969,779 timed responses**, with zero errors or invalid responses. A separate
read-only database audit checked **1,194,890 acknowledged writes** from 18 receipt
files: exact message IDs, rich-text bodies and FTS content, no missing or extra
new messages, database integrity, and unchanged database/WAL hashes across the
audit. Those totals cover all three configurations, not just the two table
columns.

The bundle contains original raw metric bytes, recomputed summaries, exact
source/image identities, sanitized hardware data and historical audit results.
It excludes fixture databases, storage, generated credentials, cookies, labels
and receipt contents. Its offline checker verifies hashes, table arithmetic,
counts and provenance links; it cannot repeat the database audit without those
private artifacts.

```sh
python3 docs/benchmarks/2026-10-15-matched-http/verify.py
```

[Provenance](benchmarks/2026-10-15-matched-http/provenance.json) pins verification
commit `ec02debb3e44f40b8778a6a42db3c4515b2f9eaf`, the load-generator binary and
fixture hashes, the original adapter hashes, and these local image identities:

- Julia: `sha256:c5c0e2d8aa293206c8c71a674bad5fbf4cb73e9a9e7bc77f03a5d6e3aa1c2131`
- C: `sha256:820f3ef4f63e72f26031698a6f6146d3e779ccf75390f90598183d7c68862cca`

The [runtime manifest](benchmarks/2026-10-15-matched-http/runtime-source.json)
identifies all 330 files included in the measured runtime digest. The
[historical experiment log](../julia/README.md) preserves the development
sequence, including rejected optimizations. Its other tables are separate
experiments and must not be combined with this one.

The separate historical source count was 7,294 Julia lines versus 94,816 C lines
using `cloc 2.06` consistently. It counted maintained backend-language source,
including Julia's selectable prototype, while excluding fixture helpers,
tests, standalone SQL, build scripts, frontend assets, dependencies and whole
generated files. Executable multiline Julia strings counted as code; eight
actual docstrings were reclassified as comments. See the
[full scope](benchmarks/2026-10-15-matched-http/source-count.json).
This describes those source versions and dependency boundaries, not equivalent
features, maintainability, or all code executed by a request.

## Reproduce the workload

These commands create a **new** measurement of the pinned historical source.
They have not been run as part of publication packaging. They require Docker,
Ruby, Python 3, Rust 1.98.1, SQLite CLI, FFmpeg and the C checkout's documented
build dependencies. Use an otherwise quiet host and choose disjoint physical
CPU cores appropriate to that machine. Allow sufficient tmpfs quota for all
nine database copies, receipts and generated assets.

From the root of this standalone checkout:

```sh
PUBLICATION="$PWD"
WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/campfire-reproduction.XXXXXX")
export JULIA_SOURCE="$WORKSPACE/once-campfire-julia"
git worktree add --detach "$JULIA_SOURCE" 8a4feb2f27af0929290f0c8162d85f28784055a4

python3 "$PUBLICATION/docs/benchmarks/2026-10-15-matched-http/verify.py" \
  --source "$JULIA_SOURCE"

git clone https://github.com/basecamp/once-campfire-verification.git \
  "$WORKSPACE/once-campfire-verification"
VERIFICATION="$WORKSPACE/once-campfire-verification"
git -C "$VERIFICATION" checkout --detach ec02debb3e44f40b8778a6a42db3c4515b2f9eaf

git clone https://github.com/basecamp/once-campfire-c.git "$WORKSPACE/once-campfire-c"
git -C "$WORKSPACE/once-campfire-c" checkout --detach 873a51f523de5a0cc235884e5725cfb5521d2027

docker build -f "$JULIA_SOURCE/julia/Dockerfile" \
  -t campfire-julia:measured "$JULIA_SOURCE"

# Fetch/build the C dependencies according to its pinned README.
make -C "$WORKSPACE/once-campfire-c" deps
make -C "$WORKSPACE/once-campfire-c" deps-build
make -C "$WORKSPACE/once-campfire-c" MODE=bench build-app
mkdir -p "$WORKSPACE/c-image/tests/fixtures"
cp "$WORKSPACE/once-campfire-c/build/bench/campfire" "$WORKSPACE/c-image/campfire"
cp -a "$WORKSPACE/once-campfire-c/tests/fixtures/assets" "$WORKSPACE/c-image/tests/fixtures/"
cp "$WORKSPACE/once-campfire-c/bench/image/entrypoint.sh" "$WORKSPACE/c-image/entrypoint.sh"
docker build -f "$WORKSPACE/once-campfire-c/bench/image/Dockerfile.c" \
  --build-arg BASE_IMAGE=fedora:latest -t campfire-c:measured "$WORKSPACE/c-image"

# Generates a fresh Rails-built fixture and private disposable credentials.
"$VERIFICATION/bin/seed" --output "$WORKSPACE/fixture"
cargo build --release --locked --manifest-path "$VERIFICATION/loadgen/Cargo.toml"
export LOADGEN="$VERIFICATION/loadgen/target/release/loadgen"
export BENCH_ENV_FILE="$WORKSPACE/fixture/reference.env"
export C_IMAGE=campfire-c:measured
export C_BENCH_ENV='{}'
export JULIA_4_0_IMAGE=campfire-julia:measured
export JULIA_2_2_IMAGE=campfire-julia:measured
export JULIA_4_0_BENCH_ENV='{"JULIA_NUM_THREADS":"4,0","DATABASE_SYNCHRONOUS":"NORMAL"}'
export JULIA_2_2_BENCH_ENV='{"JULIA_NUM_THREADS":"2,2","DATABASE_SYNCHRONOUS":"NORMAL"}'

ruby "$PUBLICATION/docs/benchmarks/2026-10-15-matched-http/reproduce.rb" "$VERIFICATION" \
  --apps c,julia-4-0,julia-2-2 --workspace "$WORKSPACE" --seed "$WORKSPACE/fixture" \
  --cpus 0,2,4,6 --client-cpus 8,10,12,14 --port 25150 --rounds 3 \
  --warmup 10 --duration 15 --concurrencies 16 \
  --routes room_show,messages_page,sidebar,search,post_message \
  --output "$WORKSPACE/results" --keep_runtime
```

The portable wrapper retains the original three alias substitutions and uses
the measured revision's standard Julia adapter. Its only additional changes
are portable source-path discovery and a measured-source guard. The upstream
load generator, response contracts and acknowledged-write auditor stay intact.
The command performs the original three-configuration rotation, not a new
mix of historical results.

The historical Docker IDs are provenance, not published registry tags.
Rebuilding on a different toolchain/base image can change binaries and image
IDs; the C image's libc must support the host-built executable. Record the
actual image IDs, compiler, dependency versions and machine settings of any new
run. The fixture builder pins Rails
`90b330024dec3e757c79b6a7e6568f93da8e3148` and generates fresh credentials, so its
database hash will differ. Keep the new fixture, environment file and raw write
receipts private. Use the new run's own summary rather than expecting identical
throughput or image hashes.
