# Fixed-version test dependencies

These files are test-only snapshots exported byte-for-byte from the source commit in `provenance.json`. They are not App runtime dependencies and do not require another repository beside this checkout.

- `score-core`: C score engine used as an independent oracle by Swift score tests. Production C engine ownership belongs to the planned edge repository.
- `racket-wire`: firmware parser used to cross-check App-generated control vectors. Runtime firmware ownership belongs to the planned racket repository.
- Protocol vector files under `docs/` are recorded in the same manifest. Their canonical owner will be the planned contracts repository.

Run `python3 Tools/verify_support.py` before tests. Update snapshots deliberately as one compatibility change with a new immutable source commit and hashes; do not edit copied implementations independently. No ongoing code development belongs in this directory.
