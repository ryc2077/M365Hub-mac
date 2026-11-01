#!/bin/bash
# Launch the real .app the way a user would and watch, for up to 180s,
# when (if ever) its gateway comes up. Best effort: the screenshots and
# logs are the evidence; a missing display must not fail the job.
# Usage: scripts/test-applaunch.sh <path-to-M365Hub.app>
set -u
APP="${1:?usage: test-applaunch.sh <M365Hub.app>}"
SHOT1="${RUNNER_TEMP:-/tmp}/m365hub-app-shot.png"
SHOT2="${RUNNER_TEMP:-/tmp}/m365hub-app-shot-late.png"
LOG="$HOME/.config/m365hub/serve-mac.log"

echo "== system proxy (URLSession obeys this, curl does not) =="
scutil --proxy || true
echo "== proxy env =="
env | grep -i proxy || echo "no proxy env vars"

echo "== launch the app =="
open "$APP" || echo "open failed (exit $?)"
sleep 5

echo "== shell check: does 127.0.0.1:8230 refuse instantly? =="
curl -v -m 3 http://127.0.0.1:8230/api/admin/session 2>&1 | tail -n 5 || true

echo "== watch for 180s: gateway process / port / log file / login screen =="
UP=0
for t in $(seq 10 10 180); do
  sleep 10
  LISTENING=$(lsof -i :8230 2>/dev/null | grep -c LISTEN || true)
  LOGSTATE="missing"
  [ -f "$LOG" ] && LOGSTATE="exists ($(wc -c < "$LOG" 2>/dev/null || echo 0) bytes)"
  # Same trap as test-gateway.sh had: `$(curl ... || echo "curl-failed")`
  # yields "000curl-failed" on a dead port, which passes a != "000"
  # check. Capture the exit code separately.
  SESSION=$(curl -s -o /dev/null -w "%{http_code}" -m 2 http://127.0.0.1:8230/api/admin/session 2>/dev/null)
  [ "$?" -ne 0 ] && SESSION="000"
  echo "t=${t}s listening=$LISTENING serve-mac.log=$LOGSTATE session=http:$SESSION"
  if [ "$LISTENING" != "0" ] && [ "$SESSION" != "000" ]; then
    echo "gateway is up at t=${t}s"
    UP=1
    break
  fi
done

echo "== screenshot (late) =="
screencapture -x "$SHOT2" && ls -la "$SHOT2" || echo "screencapture failed"
screencapture -x "$SHOT1" && ls -la "$SHOT1" || echo "screencapture failed"

echo "== processes =="
ps aux | grep -i "[m]365hub" || true
echo "== gateway log written by the app =="
cat "$LOG" 2>/dev/null || echo "no serve-mac.log yet"
echo "== quit the app =="
osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || pkill -f "M365Hub.app" || true
sleep 2
ps aux | grep -i "[m]365hub" || echo "app stopped"

# Fail here when the gateway never came up. Without this the run sails
# on to the account test, which then fails with a wall of http 000 and
# the real cause (a dead gateway) is buried. This is what happened in
# run 41303424313: the app sat on "starting the local gateway" for the
# full 180s and this step still exited 0.
if [ "$UP" = "1" ]; then
  echo "APPLAUNCH-TEST: PASS"
  exit 0
else
  echo "APPLAUNCH-TEST: FAIL - gateway never answered within 180s"
  exit 1
fi
