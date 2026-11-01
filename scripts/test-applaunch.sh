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
for t in $(seq 10 10 180); do
  sleep 10
  LISTENING=$(lsof -i :8230 2>/dev/null | grep -c LISTEN || true)
  LOGSTATE="missing"
  [ -f "$LOG" ] && LOGSTATE="exists ($(wc -c < "$LOG" 2>/dev/null || echo 0) bytes)"
  SESSION=$(curl -s -o /dev/null -w "%{http_code}" -m 2 http://127.0.0.1:8230/api/admin/session || echo "curl-failed")
  echo "t=${t}s listening=$LISTENING serve-mac.log=$LOGSTATE session=http:$SESSION"
  if [ "$LISTENING" != "0" ] && [ "$SESSION" != "000" ] && [ "$SESSION" != "curl-failed" ]; then
    echo "gateway is up at t=${t}s"
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
