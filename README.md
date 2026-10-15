# Campfire in Julia

A community Julia implementation of [ONCE Campfire](https://github.com/basecamp/once-campfire),
using its Turbo, Stimulus and Lexxy frontend and a Rails-compatible SQLite database.
The backend handles rooms, messages, search, uploads, authentication, Action Cable
WebSockets, bot webhooks and Web Push. Ruby and Redis are not required to run it.

This repository preserves the tested `julia/` layout and the shared frontend
assets. The Julia backend and frontend dependencies retain their upstream license
notices. See [source provenance](docs/standalone.md) and [MIT-LICENSE](MIT-LICENSE).

## Run with Docker

```sh
git clone https://github.com/NexOR-Optimization/once-campfire-julia.git
cd once-campfire-julia
docker build -t once-campfire-julia .
docker run --rm -p 3000:3000 \
  -e JULIA_NUM_THREADS=2,2 \
  -e CAMPFIRE_ORIGIN=http://localhost:3000 \
  -v campfire-julia-data:/data \
  once-campfire-julia
```

Open <http://localhost:3000> and complete first-run setup. The named volume keeps
the database, uploads and generated secrets between runs. Julia compiles code on
first use, so startup and initial requests take longer than warmed requests.

For an HTTPS deployment, set `CAMPFIRE_ORIGIN` to the public URL and put the server
behind a reverse proxy that terminates TLS. The image is built locally; this
repository does not currently publish a prebuilt container image.

## Run natively

The tested Julia version is **1.13.1**, pinned in the Docker image and CI.
On Debian 12, install the native runtime dependencies:

```sh
sudo apt-get install libcrypt1 libqrencode4 libssl3 libxml2 libvips-tools ffmpeg
julia --project=julia -e 'using Pkg; Pkg.instantiate()'
JULIA_NUM_THREADS=2,2 CAMPFIRE_ORIGIN=http://127.0.0.1:3001 \
  julia/bin/campfire storage/campfire.sqlite3 3001
```

Open <http://127.0.0.1:3001>. The database directory and schema are created on
startup. `2,2` selects two worker threads and two interactive I/O threads; choose
thread counts appropriate to the available CPUs and workload.

| Setting | Purpose |
|---|---|
| `DATABASE_PATH` | Database path when no positional path is supplied |
| `STORAGE_PATH` | Attachment and persisted-secret directory |
| `PORT`, `CAMPFIRE_HOST` | Listener port and address |
| `CAMPFIRE_ORIGIN` | Public origin used for links and origin checks |
| `SECRET_KEY_BASE` | Existing signing secret, or generated and persisted if absent |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | Web Push credentials and contact URI |
| `DATABASE_SYNCHRONOUS` | SQLite `FULL` by default; `NORMAL` is an explicit durability tradeoff |

Use a copy of an existing Rails database when evaluating compatibility, and retain
its original signing secret and attachment storage. The server adds schema
indexes and triggers at startup. Detailed configuration is in the
[implementation notes](julia/README.md#run-the-server).

## Recorded performance

One matched local run measured all five HTTP workloads at the Julia revision
[`8a4feb2`](https://github.com/NexOR-Optimization/once-campfire-julia/commit/8a4feb2f27af0929290f0c8162d85f28784055a4).
This is a historical benchmark, not a fresh measurement of the current checkout.
It used an Intel Core i7-12700K, four physical cores per server, separate client
cores, Julia `2,2`, gzip, 16 clients and three rounds. Both servers used SQLite
`NORMAL` for writer connections on tmpfs; production defaults to `FULL`.

| HTTP workload (requests/sec, median) | Julia | C |
|---|---:|---:|
| Room page | 103,492 | 104,823 |
| Messages page | 109,795 | 110,921 |
| Sidebar | 117,438 | 116,795 |
| Search | 111,165 | 114,767 |
| Post a message | 6,130 | 4,747 |
| Backend KLOC | 7.3 | 94.8 |

Julia used more memory and had higher POST tail latency in this run: lifetime container
memory peaked near 3.0 GiB versus 108 MiB for C, and median POST p99 was 11.495 ms
versus 4.479 ms. GC stayed enabled. These warmed, isolated workloads do not measure
startup, durable-disk throughput or production mixed traffic. Rust was not part of
this run, and these numbers should not be combined with Basecamp's measurements
on different hardware.

[Benchmark details and reproducible evidence](docs/performance.md) include exact
revisions, settings, latency, memory, source-count scope and validation results.
The longer
[experiment log](julia/README.md) preserves earlier successful and rejected
optimizations; its `tmp/` evidence paths describe the original local workspace.

## Tests and compatibility

Install the test environment, then run the test file relevant to a change:

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate()'
julia --threads=2,2 --project=test test/julia_web_server.jl
```

CI runs the Julia test files independently, checks formatting and builds the image
for the unchanged upstream browser smoke test. See the
[verification instructions](docs/standalone.md#verification) for the pinned shared
HTTP contracts and persisted-write auditor. [Standalone validation](docs/validation.json) records the local packaging checks.
Browser and contract checks cover specific behavior; they do not establish complete equivalence to Rails.

The implementation uses bounded response caches with fresh authentication and
membership checks and invalidation after database changes. Rendering and writes
still allocate. Realtime delivery and background notifications are local to one
process, and background jobs are not durably queued; use one server instance.
HTTP transport integration uses internal HTTP.jl APIs, so dependency upgrades need
focused transport validation.

For formatting, install JuliaFormatter 2.14 in a separate tooling environment and
run `using JuliaFormatter; format(".")` from the repository root. The formatting job in [CI](.github/workflows/ci.yml) shows the exact command. Keep the pinned environments when reproducing
results.
