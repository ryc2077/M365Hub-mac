#!/bin/bash
# End-to-end proof for the gateway self-heal (1.0.28, extended 1.0.29):
#   Phase A — a hung process named exactly "m365hub" holds 8230
#     (accepts TCP, never answers): the app must clear it, start its
#     own gateway, and answer /api/admin/session.
#   Phase B — a hung process NOT named m365hub (python3) holds 8230:
#     the app must NOT kill it, must enter the failure state, and the
#     state file must name the occupant (name + pid).
#   Phase C (1.0.29) — a hung "m365hub" that IGNORES SIGTERM holds
#     8230: the app must escalate to SIGKILL by pid, clear it, and
#     its own gateway must answer; serve-mac.log must record the
#     forced kill. This is the exact failure the user hit in 1.0.28
#     (pid 74358 survived one SIGTERM).
#   Phase C2 (1.0.29, control) — a TERM-ignoring foreign listener
#     holds 8230: the app must NOT kill it (escalation never targets
#     a non-m365hub occupant) and must enter the failure state.
# Usage: scripts/test-hung-gateway.sh <path-to-M365Hub.app>
# Exit 0 only if all phases match.
set -u
APP="${1:?usage: test-hung-gateway.sh <M365Hub.app>}"
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
SUMMARY="$TMP/m365hub-hung-gateway-summary.txt"
SHOT_A="$TMP/m365hub-hung-gateway-shot.png"
SHOT_B="$TMP/m365hub-hung-gateway-fail-shot.png"
STATE="$HOME/.config/m365hub/gateway-state.json"
STATE_COPY="$TMP/m365hub-hung-gateway-state.json"
SHOT_C="$TMP/m365hub-hung-gateway-shot-c.png"
SHOT_C2="$TMP/m365hub-hung-gateway-fail-shot-c2.png"
STATE_C2="$TMP/m365hub-hung-gateway-state-c2.json"
FAIL=0
: > "$SUMMARY"

note() { echo "$1" | tee -a "$SUMMARY"; }
fail() { FAIL=1; note "FAIL: $1"; }
pass() { note "PASS: $1"; }

# A listener that accepts TCP connections and never answers — the exact
# shape of the hung gateway the user hit in 1.0.27. It must be compiled
# to a binary literally named "m365hub": the app only ever kills a
# process with exactly that name, so any other name would not test the
# real clear path.
mkdir -p "$TMP/hungtest"
cat > "$TMP/hungtest/hung.c" <<'EOF'
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
int main(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return 1;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(8230);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) { perror("bind"); return 1; }
    if (listen(s, 16) != 0) return 1;
    for (;;) { int c = accept(s, 0, 0); if (c >= 0) sleep(3600); }
    return 0;
}
EOF
cat > "$TMP/hungtest/hung.py" <<'EOF'
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8230))
s.listen(16)
while True:
    try:
        c, _ = s.accept()
        time.sleep(3600)
    except Exception:
        time.sleep(1)
EOF
# TERM-ignoring variants for Phase C / C2 (1.0.29): the fake gateway
# that survived 1.0.28's single SIGTERM.
mkdir -p "$TMP/hungtest-term"
cat > "$TMP/hungtest-term/hung-term.c" <<'EOF'
#include <arpa/inet.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
int main(void) {
    signal(SIGTERM, SIG_IGN);
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return 1;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(8230);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) { perror("bind"); return 1; }
    if (listen(s, 16) != 0) return 1;
    for (;;) { int c = accept(s, 0, 0); if (c >= 0) sleep(3600); }
    return 0;
}
EOF
cat > "$TMP/hungtest/hung-term.py" <<'EOF'
import signal, socket, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8230))
s.listen(16)
while True:
    try:
        c, _ = s.accept()
        time.sleep(3600)
    except Exception:
        time.sleep(1)
EOF

cleanup() {
  osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || true
  pkill -f "M365Hub.app" 2>/dev/null || true
  # SIGKILL, not SIGTERM: the Phase C / C2 fakes ignore SIGTERM by
  # design, and a stuck app gateway must not survive into the next
  # phase either. Test-only cleanup; the app itself never sweeps.
  pkill -9 -x m365hub 2>/dev/null || true
  [ -n "${FAKE_PID:-}" ] && kill -9 "$FAKE_PID" 2>/dev/null || true
  [ -n "${FAKE2_PID:-}" ] && kill -9 "$FAKE2_PID" 2>/dev/null || true
  [ -n "${PY_PID:-}" ] && kill -9 "$PY_PID" 2>/dev/null || true
  [ -n "${PY2_PID:-}" ] && kill -9 "$PY2_PID" 2>/dev/null || true
  sleep 2
}

# port_hung: exit 0 if something on 8230 accepts TCP but never answers
# HTTP (curl times out, exit code 28). Connection refused is exit 7.
port_hung() {
  curl -s -m 3 -o /dev/null "$BASE/api/admin/session" 2>/dev/null
  [ "$?" = "28" ]
}

# port_free: exit 0 if nothing listens on 8230.
port_free() {
  ! lsof -nP -iTCP:8230 -sTCP:LISTEN >/dev/null 2>&1
}

# wait_session <seconds>: exit 0 once /api/admin/session answers HTTP 200.
wait_session() {
  local deadline="$1" i=0 code rc
  while [ "$i" -lt "$deadline" ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 2 "$BASE/api/admin/session" 2>/dev/null)
    rc=$?
    [ "$rc" -ne 0 ] && code="000"
    [ "$code" = "200" ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

echo "== setup: clean slate =="
cleanup
rm -rf "$HOME/.config/m365hub"
rm -f "$STATE" "$STATE_COPY"
port_free || fail "port 8230 not free at test start"
cc -O2 -o "$TMP/hungtest/m365hub" "$TMP/hungtest/hung.c" \
  || { fail "cc failed to build the fake hung gateway"; exit 1; }

echo "== Phase A: hung process named m365hub holds 8230 =="
"$TMP/hungtest/m365hub" &
FAKE_PID=$!
sleep 1
if kill -0 "$FAKE_PID" 2>/dev/null && port_hung; then
  pass "fake hung m365hub (pid $FAKE_PID) holds 8230 and never answers"
else
  fail "fake hung m365hub did not come up"
fi
open "$APP" || echo "open failed (exit $?)"
if wait_session 60; then
  pass "app cleared the hung gateway and its own gateway answers"
else
  fail "gateway never answered after the app cleared the hung process"
fi
if kill -0 "$FAKE_PID" 2>/dev/null; then
  fail "fake hung m365hub (pid $FAKE_PID) is still alive — app did not clear it"
else
  pass "fake hung m365hub process is gone"
fi
screencapture -x "$SHOT_A" 2>/dev/null || echo "screencapture failed"

echo "== Phase B: hung process NOT named m365hub holds 8230 =="
cleanup
rm -rf "$HOME/.config/m365hub"
rm -f "$STATE" "$STATE_COPY"
port_free || fail "port 8230 not free before Phase B"
python3 "$TMP/hungtest/hung.py" &
PY_PID=$!
sleep 1
if kill -0 "$PY_PID" 2>/dev/null && port_hung; then
  pass "foreign hung listener python3 (pid $PY_PID) holds 8230 and never answers"
else
  fail "python hung listener did not come up"
fi
open "$APP" || echo "open failed (exit $?)"
FOUND=0
for i in $(seq 1 45); do
  [ -f "$STATE" ] && { FOUND=1; break; }
  sleep 1
done
if [ "$FOUND" = "1" ]; then
  pass "app entered the failure state (gateway-state.json written)"
  cp "$STATE" "$STATE_COPY"
  # The occupant name is whatever lsof reports for the listener
  # (macOS reports the Python interpreter as "Python", not the
  # "python3" command used to start it), so read the name from lsof
  # instead of assuming it.
  OCC_NAME=$(lsof -nP -iTCP:8230 -sTCP:LISTEN -Fcpn 2>/dev/null | awk '/^c/{print substr($0,2); exit}')
  [ -n "$OCC_NAME" ] || OCC_NAME="python3"
  grep -q "$OCC_NAME" "$STATE" \
    && pass "state file names the occupant ($OCC_NAME)" \
    || fail "state file does not name $OCC_NAME: $(cat "$STATE")"
  grep -q "$PY_PID" "$STATE" \
    && pass "state file names the occupant pid ($PY_PID)" \
    || fail "state file does not name pid $PY_PID: $(cat "$STATE")"
else
  fail "no gateway-state.json within 45s — app did not enter the failure state"
fi
if kill -0 "$PY_PID" 2>/dev/null; then
  pass "foreign listener (pid $PY_PID) still alive — app did not kill it"
else
  fail "foreign listener is gone — app killed a process it must not kill"
fi
screencapture -x "$SHOT_B" 2>/dev/null || echo "screencapture failed"

echo "== Phase C: hung m365hub that ignores SIGTERM holds 8230 =="
cleanup
rm -rf "$HOME/.config/m365hub"
rm -f "$STATE" "$STATE_COPY"
port_free || fail "port 8230 not free before Phase C"
cc -O2 -o "$TMP/hungtest-term/m365hub" "$TMP/hungtest-term/hung-term.c" \
  || { fail "cc failed to build the TERM-ignoring fake gateway"; exit 1; }
"$TMP/hungtest-term/m365hub" &
FAKE2_PID=$!
sleep 1
if kill -0 "$FAKE2_PID" 2>/dev/null && port_hung; then
  pass "TERM-ignoring fake m365hub (pid $FAKE2_PID) holds 8230 and never answers"
else
  fail "TERM-ignoring fake m365hub did not come up"
fi
open "$APP" || echo "open failed (exit $?)"
if wait_session 60; then
  pass "app escalated to SIGKILL and its own gateway answers"
else
  fail "gateway never answered after the app escalated to SIGKILL"
fi
if kill -0 "$FAKE2_PID" 2>/dev/null; then
  fail "TERM-ignoring fake m365hub (pid $FAKE2_PID) is still alive — escalation did not kill it"
else
  pass "TERM-ignoring fake m365hub process is gone"
fi
grep -q "强制结束" "$HOME/.config/m365hub/serve-mac.log" \
  && pass "serve-mac.log records the forced kill" \
  || fail "serve-mac.log does not record the forced kill"
screencapture -x "$SHOT_C" 2>/dev/null || echo "screencapture failed"

echo "== Phase C2: TERM-ignoring foreign listener holds 8230 (control) =="
cleanup
rm -rf "$HOME/.config/m365hub"
rm -f "$STATE" "$STATE_COPY" "$STATE_C2"
port_free || fail "port 8230 not free before Phase C2"
python3 "$TMP/hungtest/hung-term.py" &
PY2_PID=$!
sleep 1
if kill -0 "$PY2_PID" 2>/dev/null && port_hung; then
  pass "TERM-ignoring foreign listener python3 (pid $PY2_PID) holds 8230 and never answers"
else
  fail "TERM-ignoring foreign listener did not come up"
fi
open "$APP" || echo "open failed (exit $?)"
FOUND=0
for i in $(seq 1 45); do
  [ -f "$STATE" ] && { FOUND=1; break; }
  sleep 1
done
if [ "$FOUND" = "1" ]; then
  pass "app entered the failure state (gateway-state.json written)"
  cp "$STATE" "$STATE_C2"
  OCC_NAME=$(lsof -nP -iTCP:8230 -sTCP:LISTEN -Fcpn 2>/dev/null | awk '/^c/{print substr($0,2); exit}')
  [ -n "$OCC_NAME" ] || OCC_NAME="python3"
  grep -q "$OCC_NAME" "$STATE" \
    && pass "state file names the occupant ($OCC_NAME)" \
    || fail "state file does not name $OCC_NAME: $(cat "$STATE")"
else
  fail "no gateway-state.json within 45s — app did not enter the failure state"
fi
if kill -0 "$PY2_PID" 2>/dev/null; then
  pass "TERM-ignoring foreign listener (pid $PY2_PID) still alive — app did not kill it"
else
  fail "foreign listener is gone — app killed a process it must not kill"
fi
screencapture -x "$SHOT_C2" 2>/dev/null || echo "screencapture failed"

echo "== cleanup: leave a fresh slate for the account test =="
cleanup
rm -rf "$HOME/.config/m365hub"
rm -f "$STATE"

echo "== summary =="
cat "$SUMMARY"
if [ "$FAIL" = "0" ]; then echo "HUNG-GATEWAY-TEST: PASS"; exit 0
else echo "HUNG-GATEWAY-TEST: FAIL"; exit 1; fi
