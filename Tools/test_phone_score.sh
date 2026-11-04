#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
phone_test_dir=$(mktemp -d /private/tmp/shuttleref-phone-score.XXXXXX)
trap 'rm -rf "$phone_test_dir"' EXIT
phone_sources=(Core/RacketScoreWire.swift Core/PhoneMatchModels.swift Core/PhoneMatchStore.swift Core/PhoneMatchSession.swift Core/PhoneMatchSync.swift Core/PhoneScoreLink.swift)
cc -std=c99 -I Tests/Support/score-core Tests/PhoneScore/oracle.c Tests/Support/score-core/score_engine.c -o "$phone_test_dir/oracle"
for suite in Wire Core Store Session Link Recovery SyncLifecycle Vectors; do
  swiftc -module-cache-path /private/tmp/shuttleref-swift-cache "${phone_sources[@]}" "Tests/PhoneScore/${suite}Main.swift" -o "$phone_test_dir/$suite"
  case "$suite" in
    Core) "$phone_test_dir/$suite" "$phone_test_dir/oracle" ;;
    Vectors) "$phone_test_dir/$suite" docs/contracts/racket-phone-score-v1/vectors.json
             "$phone_test_dir/$suite" docs/contracts/racket-phone-score-v1/app-vectors.json ;;
    *) "$phone_test_dir/$suite" ;;
  esac
done
# Keep the existing Tuya host protocol/state machine and BLE identity codec unchanged.
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache Core/MatchWire.swift Core/MatchSession.swift Tests/main.swift -o "$phone_test_dir/host-regression"
"$phone_test_dir/host-regression"
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache Core/RacketModels.swift Core/RacketBLEWire.swift Tests/RacketBLEWireMain.swift -o "$phone_test_dir/ble-regression"
"$phone_test_dir/ble-regression"

c++ -std=c++17 -I Tests/Support/racket-wire Tests/PhoneScore/wire_oracle.cpp -o "$phone_test_dir/wire-oracle"
python3 - "$phone_test_dir/wire-oracle" <<'PYTEST'
import json, subprocess, sys
with open('docs/contracts/racket-phone-score-v1/app-vectors.json') as stream:
    messages = json.load(stream)['messages']
lines = [v['json'] for v in messages if v['type'] in ('configure', 'ready', 'stop', 'ack')]
subprocess.run([sys.argv[1]], input='\n'.join(lines)+'\n', text=True, check=True)
PYTEST
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache Core/RacketModels.swift Core/KnownRacketRegistry.swift Tests/KnownRacketMain.swift -o "$phone_test_dir/known-rackets"
"$phone_test_dir/known-rackets"
swiftc -D RACKET_TESTS -module-cache-path /private/tmp/shuttleref-swift-cache Core/RacketModels.swift App/MockRacketService.swift App/RacketStore.swift Tests/RacketPresentationMain.swift -o "$phone_test_dir/presentation"
"$phone_test_dir/presentation"
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache Core/RacketDiagnostics.swift Tests/RacketDiagnosticsMain.swift -o "$phone_test_dir/diagnostics"
"$phone_test_dir/diagnostics"
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache Core/RacketScoreWire.swift Core/RacketArchiveWire.swift Tests/RacketArchiveMain.swift -o "$phone_test_dir/archive"
"$phone_test_dir/archive" docs/contracts/racket-journal-archive-v1/vectors.json

swiftc -module-cache-path /private/tmp/shuttleref-swift-cache Core/RacketScoreWire.swift Core/PhoneMatchModels.swift Core/LocalMatchReplica.swift Tests/PhoneScore/ReplicaMain.swift -o "$phone_test_dir/replica"
"$phone_test_dir/replica"

swiftc -module-cache-path /private/tmp/shuttleref-swift-cache Core/RacketScoreWire.swift Core/RacketDualHostWire.swift Tests/PhoneScore/DualHostMain.swift -o "$phone_test_dir/dual-host"
"$phone_test_dir/dual-host" docs/contracts/racket-dual-host-v1/vectors.json
