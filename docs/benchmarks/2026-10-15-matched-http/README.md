# Matched HTTP evidence, 2026-10-15

This bundle contains one historical C / Julia 4,0 / Julia 2,2 run, not current-HEAD
measurements. See [performance.md](../../performance.md) for the selected C/2,2
table, limits, pinned revisions and reproduction commands. There are no Rust
measurements here.

- `raw/http-1.json` through `raw/http-90.json`: unchanged original metric bytes;
  45 warmups and 45 timed samples across nine application-rounds.
- `samples.json`: exact file-to-application/round/route/phase mapping, original
  paths and hashes. `summary.json`: recomputed per-round and median metrics.
- `provenance.json`, `image-proofs.json`, `runtime-source.json`, `hardware.json`:
  source/image/fixture/toolchain identities and selected host configuration.
- `write-audit.json`: historical audit outcomes, 18 receipt hashes/counts and
  database/WAL hashes. It contains no receipts, database or request bodies.
- `source-count.json`: the separate historical count and its scope.
- `reproduce.rb`: portable version of the original alias wrapper, with a pinned
  source guard. It runs a new benchmark only when explicitly invoked.
- `SHA256SUMS.json`, `verify.py`: explicit file allowlist and offline verification.

Run `python3 verify.py` from this directory. Optional
`--source /path/to/measured/checkout` also checks all 330 runtime files.
The checker recomputes metrics and validates hashes; it cannot repeat the
private database audit, establish statistical significance, or authenticate
these files with an external signature. No databases, storage, fixture labels,
credentials, cookies, private keys or receipt contents are distributed.
