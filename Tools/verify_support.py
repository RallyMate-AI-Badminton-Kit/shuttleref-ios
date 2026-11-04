"""Verify pinned cross-component fixtures without fetching another repository."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'Tests/Support/provenance.json').read_text())
for entry in manifest['files']:
    path = root / entry['path']
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
        raise SystemExit('Pinned support file changed: ' + entry['path'])
print('PASS: pinned protocol vectors and test oracles (' + str(len(manifest['files'])) + ' files)')
