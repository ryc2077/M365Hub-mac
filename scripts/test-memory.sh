#!/bin/bash
# Memory test: the Mac "本地记忆" view and the gateway memory API.
# Seeds one memory (tag:ci-test) into the gateway data dir BEFORE the
# gateway starts (it loads local-memory.json at startup), then:
#   - list shows the seeded memory (key / turns / chars / hasSummary)
#   - detail returns its real summary + turns (not just a byte count)
#   - delete removes it (also keeps the seed out of the account cache)
# Then it screenshots the Mac 本地记忆 section. The app's login screen
# cannot be driven in the runner's GUI session (synthetic keystrokes and
# coordinate clicks never reach the field — five attempts proved it), so
# the session cookie is seeded into the shared cookie storage instead
# (scripts/seed-session.swift) and the app is launched after that, so it
# opens straight into the main view. Runs after test-account-chat.sh,
# which already changed the admin password to ci-test-pass-20261101.
# Usage: scripts/test-memory.sh <path-to-M365Hub.app>
# Exit 0 only if every API step matches its expected result.
set -u
APP="${1:?usage: test-memory.sh <M365Hub.app>}"
BIN="$APP/Contents/Resources/m365hub"
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
JAR="$TMP/m365hub-cookies.txt"
SUMMARY="$TMP/m365hub-memory-summary.txt"
SHOT="$TMP/m365hub-memory-shot.png"
NEW_PASS="ci-test-pass-20261101"
FAIL=0
: > "$SUMMARY"

note() { echo "$1" | tee -a "$SUMMARY"; }
fail() { FAIL=1; note "FAIL: $1"; }
pass() { note "PASS: $1"; }

jget() { python3 -c "import json,sys; d=json.load(open('$1')); v=d$2; print(v if not isinstance(v,bool) else str(v).lower())" 2>/dev/null; }

echo "== seed one memory into the gateway data dir =="
mkdir -p "$HOME/.config/m365hub"
cat > "$HOME/.config/m365hub/local-memory.json" <<'EOF'
{"memories":{"tag:ci-test":{"summary":"CI 记忆测试：这是摘要内容。","turns":[{"role":"user","content":"你好，这是第一轮","at":"2026-11-10T00:00:00Z"},{"role":"assistant","content":"你好，这是第二轮","at":"2026-11-10T00:01:00Z"}]}}}
EOF
grep -q "tag:ci-test" "$HOME/.config/m365hub/local-memory.json" \
  && pass "seed file written" || { fail "seed file missing"; }

echo "== start the gateway directly (so the app can adopt it) =="
[ -x "$BIN" ] || { fail "gateway binary missing/not executable: $BIN"; }
M365_DATA_DIR="$HOME/.config/m365hub" M365_LISTEN="127.0.0.1:8230" \
  "$BIN" serve > "$HOME/.config/m365hub/serve-mac.log" 2>&1 &
GW_PID=$!
echo "gateway pid: $GW_PID" | tee -a "$SUMMARY"
UP=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 2 "$BASE/api/admin/session" 2>/dev/null || echo "000")
  if [ "$CODE" != "000" ]; then UP=1; break; fi
  sleep 1
done
[ "$UP" = "1" ] && pass "gateway up (session answers)" || { fail "gateway never answered"; }

echo "== login (password already changed by the account test) =="
curl -s -m 10 -c "$JAR" -b "$JAR" -X POST "$BASE/api/admin/login" \
  -H 'Content-Type: application/json' -d "{\"password\":\"$NEW_PASS\"}" -o "$TMP/mr1.json" -w "%{http_code}" > "$TMP/mr1.code"
[ "$(cat "$TMP/mr1.code")" = "200" ] \
  && pass "login with the changed password" || fail "login: $(cat "$TMP/mr1.json")"

echo "== seed the session cookie so the app skips its login screen =="
COOKIE_VALUE=$(python3 - "$JAR" <<'PY'
import sys
for line in open(sys.argv[1], errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 7 and parts[5] == "m365hub_admin":
        print(parts[6]); break
PY
)
if [ -n "$COOKIE_VALUE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  swift "$SCRIPT_DIR/seed-session.swift" "$COOKIE_VALUE" 2>&1 | tee -a "$SUMMARY" \
    && pass "session cookie seeded into shared storage" \
    || fail "seed-session.swift failed"
else
  fail "no m365hub_admin cookie in jar"
fi

echo "== 1. list memories =="
curl -s -m 10 -b "$JAR" "$BASE/api/local-memory" -o "$TMP/mr2.json" -w "%{http_code}" > "$TMP/mr2.code"
[ "$(cat "$TMP/mr2.code")" = "200" ] \
  && pass "GET /api/local-memory -> 200" || fail "list: $(cat "$TMP/mr2.json")"
python3 - "$TMP/mr2.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
mems = d.get("memories", [])
m = next((x for x in mems if x.get("key") == "tag:ci-test"), None)
assert m is not None, "seeded memory tag:ci-test not in list: %r" % (mems,)
assert m.get("turns") == 2, "turns=%r" % (m.get("turns"),)
assert m.get("hasSummary") is True, "hasSummary=%r" % (m.get("hasSummary"),)
print("PASS: list shows tag:ci-test (2 turns, hasSummary=true)")
PY
[ $? -ne 0 ] && fail "list content mismatch (see above)"

echo "== 2. detail returns the real content =="
curl -s -m 10 -b "$JAR" "$BASE/api/local-memory?key=tag%3Aci-test" -o "$TMP/mr3.json" -w "%{http_code}" > "$TMP/mr3.code"
[ "$(cat "$TMP/mr3.code")" = "200" ] \
  && pass "GET /api/local-memory?key=tag:ci-test -> 200" || fail "detail: $(cat "$TMP/mr3.json")"
python3 - "$TMP/mr3.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("key") == "tag:ci-test", "key=%r" % (d.get("key"),)
assert "CI 记忆测试" in (d.get("summary") or ""), "summary=%r" % (d.get("summary"),)
turns = d.get("turns") or []
assert len(turns) == 2, "turns=%r" % (turns,)
assert turns[0].get("content") == "你好，这是第一轮", "turn0=%r" % (turns[0],)
assert turns[1].get("content") == "你好，这是第二轮", "turn1=%r" % (turns[1],)
print("PASS: detail shows the real summary + both turns")
PY
[ $? -ne 0 ] && fail "detail content mismatch (see above)"

echo "== 3. launch the app (adopts the gateway, skips login) and open 本地记忆 =="
open "$APP" || echo "open failed (exit $?)"
sleep 5
osascript <<OSA 2>&1 | tee -a "$SUMMARY" || echo "sidebar navigation failed (best effort)"
tell application "M365Hub" to activate
delay 2
tell application "System Events"
  tell process "M365Hub"
    try
      click static text "本地记忆" of window 1
      delay 2
    on error
      try
        click (first UI element of window 1 whose description contains "本地记忆")
        delay 2
      end try
    end try
  end tell
end tell
OSA
sleep 2
screencapture -x "$SHOT" 2>/dev/null && ls -la "$SHOT" | tee -a "$SUMMARY" || echo "screencapture failed"

echo "== 4. delete the seeded memory (keeps it out of the account cache) =="
curl -s -m 10 -b "$JAR" -X DELETE "$BASE/api/local-memory?key=tag%3Aci-test" -o "$TMP/mr4.json" -w "%{http_code}" > "$TMP/mr4.code"
[ "$(cat "$TMP/mr4.code")" = "200" ] \
  && pass "DELETE /api/local-memory?key=tag:ci-test -> 200" || fail "delete: $(cat "$TMP/mr4.json")"
curl -s -m 10 -b "$JAR" "$BASE/api/local-memory" -o "$TMP/mr5.json"
python3 - "$TMP/mr5.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
mems = d.get("memories", [])
assert not any(x.get("key") == "tag:ci-test" for x in mems), "seed still present: %r" % (mems,)
print("PASS: seeded memory is gone after delete")
PY
[ $? -ne 0 ] && fail "delete did not remove the seed (see above)"

echo "== quit the app and stop the gateway =="
osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || pkill -f "M365Hub.app" || true
sleep 2
kill "$GW_PID" 2>/dev/null || true
sleep 1
pkill -f "m365hub serve" 2>/dev/null || true

echo "== summary =="
cat "$SUMMARY"
if [ "$FAIL" = "0" ]; then echo "MEMORY-TEST: PASS"; exit 0
else echo "MEMORY-TEST: FAIL"; exit 1; fi
