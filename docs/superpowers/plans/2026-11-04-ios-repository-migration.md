# iOS repository migration implementation plan

**Goal:** Independent private iOS repository under RallyMate-AI-Badminton-Kit.

**Architecture:** Extract `source/ios` history, put its contents at repository root, and pin the minimal existing cross-component test dependencies locally until shared repositories are available.

**Approved scope:** User requested separate closed-source repositories, retained Pi in one repository, excluded T5, and supplied this first remote.

- [x] Verify target is private and empty.
- [x] Split iOS-only Git history from source commit `64889f4916aa63ef249572203a53b9c0c3e5b6d7`.
- [x] Move test and private configuration paths to standalone repository root.
- [x] Pin protocol vectors, C score oracle and firmware parser with source hashes.
- [x] Run independent tests and SDK-free simulator build.
- [x] Audit exported history/current files for credentials.

**Publish target:** `RallyMate-AI-Badminton-Kit/shuttleref-ios`, branch `main`. Verify publication against the remote commit after push.

Original monorepo remains the complete historical archive. No device deployment or backend configuration change is part of this migration.

## Validation evidence

- `python3 Tools/verify_support.py`: 9 pinned support files match hashes.
- `bash Tools/test_phone_score.sh`: all suites passed from standalone root.
- `xcodebuild -project ShuttleRef.xcodeproj -scheme ShuttleRefPreview -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`: BUILD SUCCEEDED with isolated DerivedData.
- Preserved 4 extracted iOS commits; scanned 167 historical blobs plus current files for selected credential patterns, no matches. This is a targeted scan, not a full security audit.
- 113 application, project and resource files remain byte-identical to the source tree.
- This machine reports a CoreSimulator service version mismatch. Generic simulator compilation passed; simulator launch/UI tests and physical iPhone installation were not performed.
- Proprietary SDK target, account login, BLE and live cloud integration require separately provisioned local SDK/signing and were not revalidated by this migration.
