#!/bin/bash
# Launch the real .app the way a user would, screenshot it, and check
# whether its own gateway came up. Best effort: never fails the job by
# itself, the screenshot and logs are the evidence.
# Usage: scripts/test-applaunch.sh <path-to-M365Hub.app>
set -u
APP="${1:?usage: test-applaunch.sh <M365Hub.app>}"
SHOT="${RUNNER_TEMP:-/tmp}/m365hub-app-shot.png"
LOG="$HOME/.config/m365hub/serve-mac.log"

echo "== launch the app =="
open "$APP" || echo "open failed (exit $?)"
sleep 20

echo "== screenshot =="
screencapture -x "$SHOT" && ls -la "$SHOT" || echo "screencapture failed"

echo "== processes =="
ps aux | grep -i "[m]365hub" || true
echo "== port 8230 =="
lsof -i :8230 2>/dev/null || echo "nothing listening on 8230"
echo "== session endpoint =="
curl -s -m 3 http://127.0.0.1:8230/api/admin/session; echo
echo "== gateway log written by the app =="
cat "$LOG" 2>/dev/null || echo "no serve-mac.log yet"
echo "== quit the app =="
osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || pkill -f "M365Hub.app" || true
sleep 2
ps aux | grep -i "[m]365hub" || echo "app stopped"
