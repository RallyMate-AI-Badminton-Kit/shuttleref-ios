# RallyMate / ShuttleRef iOS

This repository contains only the native iOS client. Commands run from repository root.

- Application sources: `App/`, `Core/`, `UI/`; resources: `Resources/`.
- Open `ShuttleRef.xcworkspace` for SDK builds. `ShuttleRefPreview` is the SDK-free preview target.
- Run `python3 Tools/verify_support.py` and `bash Tools/test_phone_score.sh` for host-side protocol and scoring checks.
- Private settings: `config/local/ios-sdk.env`; generated files: `Local/`; proprietary SDK: `ios_core_sdk/`. Never commit them or print their contents.
- Preserve `com.yahabib.shuttleref`, protocol semantics, account/server isolation and uncertain-result protection during repository migration.
- Cross-component snapshots are pinned in `Tests/Support/provenance.json`. Keep them test-only and update via explicit compatibility changes.
- Do not add server, sensor or Pi runtime implementations. Keep migration and deployment status distinct from hardware verification.
