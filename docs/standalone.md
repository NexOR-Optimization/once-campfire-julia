# Standalone repository and source provenance

This repository was exported from the local `julia` development branch of
[ONCE Campfire](https://github.com/basecamp/once-campfire), at original commit
`8976167e254478f8586b62223a7088ad1159498e`. The Julia development commits were local;
these original identifiers need not exist in Basecamp's public repository.

Git's path-filtered `fast-export` / `fast-import` preserved authors, commit messages
and the relevant history while retaining these paths:

- `julia/`: implementation, pinned package environments, entry point, assets,
  benchmark adapters and historical experiment notes.
- `app/javascript/`, `app/assets/`, `app/views/pwa/`, `vendor/javascript/`:
  shared frontend source and assets used by the Julia server.
- `test/*.jl`, `test/Project.toml`, `test/Manifest.toml` and the two media fixtures
  `moon.jpg` and `alpha-centuri.mov` referenced by the Julia tests.
- `MIT-LICENSE` and the license and provenance files already inside `julia/assets/`.

The import contains 361 files and 55 commits. Its tip is
`e8d74d299b738b4141c680e729614cbde3f989a5`. Filtering changes Git commit IDs;
[source-history.json](source-history.json) maps original commits to the standalone
history. Every imported file was checked against the original committed bytes.
Subsequent packaging commits add the root documentation, Dockerfile link, CI,
ignore rules and curated benchmark evidence. They do not change server behavior.

The original nested layout keeps asset paths and test imports intact.
`Dockerfile` at the root links to `julia/Dockerfile`, and both use the repository
root as their Docker build context. The Rails backend, Rails test suite and Rails
CI workflows are not part of this export.

The shared frontend comes from Campfire; retain `MIT-LICENSE` and
`julia/assets/LICENSE.once-campfire`. The vendored browser libraries have separate
notices under `julia/assets/licenses/`, plus an exact
[asset manifest](../julia/assets/manifest.json) and
[upstream provenance](../julia/assets/README.md).

## Verification

The tested runtime is Julia 1.13.1. The broader `julia = "1.10"` package compat
entry is not evidence that every accepted Julia version has been tested.
Use `test/Project.toml` for Julia tests and run the file relevant to a change.
CI runs each listed test file separately, including transport checks for the
thread configurations used during development.

The browser smoke and HTTP conformance adapters use the unchanged shared
verification repository at a pinned revision:

```sh
git clone https://github.com/basecamp/once-campfire-verification.git ../once-campfire-verification
git -C ../once-campfire-verification checkout ec02debb3e44f40b8778a6a42db3c4515b2f9eaf
```

For the browser smoke, install Node.js 24 and prepare Playwright in that checkout:

```sh
(cd ../once-campfire-verification && npm ci && npx playwright install --with-deps chromium)
../once-campfire-verification/bin/browser --base http://127.0.0.1:3000
```

The browser flow needs a fresh, disposable server database. It completes first-run
setup and creates data; the container CI job creates and removes its own volume.
It covers installation, live messaging across two tabs, stored-markup safety,
editing, search, settings, bots, QR codes and session transfers.

The HTTP adapter requires Ruby, SQLite's command-line client, Docker for generating
the reference fixture, and Rust/Cargo for building the shared load generator:

```sh
cargo build --release --locked \
  --manifest-path ../once-campfire-verification/loadgen/Cargo.toml
../once-campfire-verification/bin/seed --output /tmp/campfire-reference-fixture
ruby julia/bench/conformance.rb ../once-campfire-verification \
  /tmp/campfire-reference-fixture --output /tmp/campfire-julia-contracts
```

The adapter copies the fixture before starting a Julia server. It runs all eight
upstream route contracts and audits acknowledged message writes against the
persisted database. Generated fixtures contain credentials and signing keys and
stay outside the public evidence bundle. These correctness gates do not measure
throughput and do not prove complete Rails compatibility.

## Benchmark provenance

The public [matched benchmark](performance.md) records a complete earlier run.
Its original Julia source commit `76fb004e61252f58f18187b62e5bd8ee50e72bb9` maps to
standalone commit `8a4feb2f27af0929290f0c8162d85f28784055a4`. The imported current
source also includes the later bodyless-request parameter parsing optimization;
that source change is not attributed to the historical table.

The [original implementation README](../julia/README.md) remains an experiment
log, including rejected candidates. Its original commit IDs can be looked up in
[source-history.json](source-history.json). References to ignored `tmp/` paths in
that log describe local archives in the development workspace. The curated
public evidence under `docs/benchmarks/` is a separate, portable subset with an
explicit manifest and an offline verifier.
