"""Prepare ignored iOS credentials and SDK from the user's local configuration."""
import argparse
import json
import os
from pathlib import Path
import shutil
import zipfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', type=Path, default=root / 'config/local/ios-sdk.env')
args = parser.parse_args()
config = args.config.expanduser().resolve()
if not config.is_file():
    raise SystemExit('Missing local configuration; copy config/ios-sdk.env.example to config/local/ios-sdk.env and fill in your own values.')
values = {}
for line in config.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key, value = line.removeprefix('export ').split('=', 1)
    values[key.strip()] = value.strip().strip('\"\'')
for key in ('TUYA_IOS_APP_KEY', 'TUYA_IOS_APP_SECRET'):
    if not values.get(key):
        raise SystemExit(f'Missing {key}; edit {config}')
if values.get('IOS_BUNDLE_ID', 'com.yahabib.shuttleref') != 'com.yahabib.shuttleref':
    raise SystemExit('Bundle ID differs from the registered application.')
local = root / 'Local'
local.mkdir(exist_ok=True, mode=0o700)
def swift_string(value):
    # Prevent Swift interpolation while retaining arbitrary credential characters.
    return json.dumps(value, ensure_ascii=False).replace('\\/', '/')
key_file = local / 'AppKey.swift'
key_file.write_text('enum AppKey {\n static let key = ' + swift_string(values['TUYA_IOS_APP_KEY']) + '\n static let secret = ' + swift_string(values['TUYA_IOS_APP_SECRET']) + '\n}\n')
key_file.chmod(0o600)
signing = local / 'Signing.xcconfig'
if not signing.exists():
    team = values.get('APPLE_TEAM_ID', '')
    if team and not team.isalnum():
        raise SystemExit('Invalid APPLE_TEAM_ID')
    signing.write_text('// Local signing; select your team in Xcode if blank.\nDEVELOPMENT_TEAM = ' + team + '\n')
    signing.chmod(0o600)
sdk = root / 'ios_core_sdk'
if not sdk.exists():
    archive = Path(values.get('TUYA_IOS_SDK_ZIP', '~/Downloads/iOS_SDK.zip')).expanduser()
    import io
    with zipfile.ZipFile(archive) as outer:
        name = next(n for n in outer.namelist() if n.endswith('ios_core_sdk.tar.gz') and not n.startswith('__MACOSX'))
        with zipfile.ZipFile(io.BytesIO(outer.read(name))) as inner:
            for item in inner.infolist():
                if item.filename.startswith('__MACOSX'):
                    continue
                relative = Path(item.filename)
                if relative.is_absolute() or '..' in relative.parts:
                    raise SystemExit('Unsafe SDK archive entry')
                # SDK archive usually includes its root directory.
                destination = root if relative.parts[0] == 'ios_core_sdk' else sdk
                inner.extract(item, destination)
print('Local credentials and SDK prepared; no secrets printed.')
