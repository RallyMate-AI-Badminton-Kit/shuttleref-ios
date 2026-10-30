#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
phone_test_dir=$(mktemp -d /private/tmp/shuttleref-phone-score.XXXXXX)
trap 'rm -rf "$phone_test_dir"' EXIT
phone_sources=(source/ios/Core/RacketScoreWire.swift source/ios/Core/PhoneMatchModels.swift source/ios/Core/PhoneMatchStore.swift source/ios/Core/PhoneMatchSession.swift source/ios/Core/PhoneMatchSync.swift source/ios/Core/PhoneScoreLink.swift)
cc -std=c99 -I shuttleref/core/include source/ios/Tests/PhoneScore/oracle.c shuttleref/core/src/score_engine.c -o "$phone_test_dir/oracle"
for suite in Wire Core Store Session Link Recovery SyncLifecycle Vectors; do
  swiftc -module-cache-path /private/tmp/shuttleref-swift-cache "${phone_sources[@]}" "source/ios/Tests/PhoneScore/${suite}Main.swift" -o "$phone_test_dir/$suite"
  case "$suite" in
    Core) "$phone_test_dir/$suite" "$phone_test_dir/oracle" ;;
    Vectors) "$phone_test_dir/$suite" docs/contracts/racket-phone-score-v1/vectors.json
             "$phone_test_dir/$suite" docs/contracts/racket-phone-score-v1/app-vectors.json ;;
    *) "$phone_test_dir/$suite" ;;
  esac
done
# Keep the existing Tuya host protocol/state machine and BLE identity codec unchanged.
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/MatchWire.swift source/ios/Core/MatchSession.swift source/ios/Tests/main.swift -o "$phone_test_dir/host-regression"
"$phone_test_dir/host-regression"
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/RacketModels.swift source/ios/Core/RacketBLEWire.swift source/ios/Tests/RacketBLEWireMain.swift -o "$phone_test_dir/ble-regression"
"$phone_test_dir/ble-regression"

c++ -std=c++17 -I source/racket_matrix_client/src source/ios/Tests/PhoneScore/wire_oracle.cpp -o "$phone_test_dir/wire-oracle"
python3 - "$phone_test_dir/wire-oracle" <<'PYTEST'
import json, subprocess, sys
with open('docs/contracts/racket-phone-score-v1/app-vectors.json') as stream:
    messages = json.load(stream)['messages']
lines = [v['json'] for v in messages if v['type'] in ('configure', 'ready', 'stop', 'ack')]
subprocess.run([sys.argv[1]], input='\n'.join(lines)+'\n', text=True, check=True)
PYTEST
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/RacketModels.swift source/ios/Core/KnownRacketRegistry.swift source/ios/Tests/KnownRacketMain.swift -o "$phone_test_dir/known-rackets"
"$phone_test_dir/known-rackets"
swiftc -D RACKET_TESTS -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/RacketModels.swift source/ios/App/MockRacketService.swift source/ios/App/RacketStore.swift source/ios/Tests/RacketPresentationMain.swift -o "$phone_test_dir/presentation"
"$phone_test_dir/presentation"
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/RacketDiagnostics.swift source/ios/Tests/RacketDiagnosticsMain.swift -o "$phone_test_dir/diagnostics"
"$phone_test_dir/diagnostics"
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/RacketScoreWire.swift source/ios/Core/RacketArchiveWire.swift source/ios/Tests/RacketArchiveMain.swift -o "$phone_test_dir/archive"
"$phone_test_dir/archive" docs/contracts/racket-journal-archive-v1/vectors.json

swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/RacketScoreWire.swift source/ios/Core/PhoneMatchModels.swift source/ios/Core/LocalMatchReplica.swift source/ios/Tests/PhoneScore/ReplicaMain.swift -o "$phone_test_dir/replica"
"$phone_test_dir/replica"

swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/RacketScoreWire.swift source/ios/Core/RacketDualHostWire.swift source/ios/Tests/PhoneScore/DualHostMain.swift -o "$phone_test_dir/dual-host"
"$phone_test_dir/dual-host" docs/contracts/racket-dual-host-v1/vectors.json
