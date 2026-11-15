#!/bin/bash
# Unit-test the pure gateway-diagnostics helpers (lsof parsing, log
# tail, failure-state file) with a plain swiftc harness — no Xcode
# project, no app target. Fails the build if any assertion fails.
# Usage: bash scripts/test-gateway-diagnostics.sh
set -u
cd "$(dirname "$0")/.." || exit 1
TMP="${RUNNER_TEMP:-/tmp}"
BIN="$TMP/gw-diagnostics-test"
swiftc -o "$BIN" M365HubApp/M365HubApp/GatewayDiagnostics.swift scripts/GatewayDiagnosticsTests.swift \
  || { echo "DIAGNOSTICS-TEST: FAIL - swiftc compile failed"; exit 1; }
"$BIN" || { echo "DIAGNOSTICS-TEST: FAIL"; exit 1; }
