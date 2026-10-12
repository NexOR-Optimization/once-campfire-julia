The Julia server serves Campfire's current `app/javascript`, `app/assets`, and
`vendor/javascript` directly. It uses the same Turbo, Stimulus and Lexxy frontend
as the Rails application, with a Julia-generated import map. There is no alternate
client implementation or JavaScript build step.
The server loads the fixed set of deployment assets once and shares their bytes
between responses. Restart the Julia process after editing frontend source files.

The nine files in `vendor/` are browser runtime dependencies ordinarily provided by
Ruby gems. They were copied unchanged from the published compiled asset fixture
in `basecamp/once-campfire-c`, `tests/fixtures/assets/public/assets`, at revision
`873a51f523de5a0cc235884e5725cfb5521d2027` on 2026-10-12.
The fixture was generated from Campfire revision
`90b330024dec3e757c79b6a7e6568f93da8e3148` and pins Lexxy 0.9.24, Stimulus Rails
1.3.4, Turbo Rails 2.0.16, and Action Cable 8.2.0.alpha.

`UPSTREAM-VENDOR-MANIFEST.md` preserves the source gem paths, revisions, and
original checksums. `manifest.json` gives SHA-256 hashes of the exact compiled
files used here. All four dependencies use the MIT license. The original license
notices embedded in their source files are retained. `licenses/` includes the
upstream MIT licenses for these dependencies and Lexxy's bundled Lexical, Prism,
and Marked libraries.

To verify this checkout deterministically:

```sh
python3 - <<'PY'
import hashlib, json
from pathlib import Path
root = Path('julia/assets')
for name, expected in json.loads((root / 'manifest.json').read_text()).items():
    assert hashlib.sha256((root / 'vendor' / name).read_bytes()).hexdigest() == expected, name
print('Browser dependency hashes match')
PY
```
