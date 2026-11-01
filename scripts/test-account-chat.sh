#!/bin/bash
# Account-add + chat test against the real Mac app, through the exact
# gateway endpoints its UI calls. The app is launched, logged in as admin
# (default password, forced change), then:
#   - accounts list (empty on a fresh gateway)
#   - PKCE start returns a login.microsoftonline.com auth URL
#   - device start returns a user code
#   - a bogus PKCE callback is rejected cleanly (400 auth_failed)
#   - chat with zero accounts fails cleanly (503 no_account)
# Completing the PKCE/device sign-in needs a human in the browser, so the
# test proves the flow starts and its errors are clean; it cannot mint an
# account by itself.
# Usage: scripts/test-account-chat.sh <path-to-M365Hub.app>
# Exit 0 only if every step matches its expected result.
set -u
APP="${1:?usage: test-account-chat.sh <M365Hub.app>}"
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
JAR="$TMP/m365hub-cookies.txt"
SUMMARY="$TMP/m365hub-account-chat-summary.txt"
NEW_PASS="ci-test-pass-20261101"
FAIL=0
: > "$SUMMARY"

note() { echo "$1" | tee -a "$SUMMARY"; }
fail() { FAIL=1; note "FAIL: $1"; }
pass() { note "PASS: $1"; }

# jq is not guaranteed on the runner; python3 is.
jget() { python3 -c "import json,sys; d=json.load(open('$1')); v=d$2; print(v if not isinstance(v,bool) else str(v).lower())" 2>/dev/null; }

expect_code() { # expect_code <name> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1 (http $3)"; else fail "$1: want http $2, got $3"; fi
}

echo "== launch the app and wait for its gateway =="
rm -f "$JAR"
open "$APP" || echo "open failed (exit $?)"
UP=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 2 "$BASE/api/admin/session" || echo "000")
  if [ "$CODE" = "200" ]; then UP=1; break; fi
  sleep 1
done
[ "$UP" = "1" ] && pass "gateway up (session answers)" || { fail "gateway never answered"; }

echo "== 1. admin login with the default password =="
curl -s -m 10 -c "$JAR" -X POST "$BASE/api/admin/login" \
  -H 'Content-Type: application/json' -d '{"password":"admin123"}' \
  -o "$TMP/r1.json" -w "%{http_code}" > "$TMP/r1.code"
expect_code "login with default password" 200 "$(cat "$TMP/r1.code")"
[ "$(jget "$TMP/r1.json" "['must_change_password']")" = "true" ] \
  && pass "default password forces a change" \
  || fail "expected must_change_password=true, got: $(cat "$TMP/r1.json")"

echo "== 2. change the admin password =="
curl -s -m 10 -X POST "$BASE/api/admin/password" \
  -H 'Content-Type: application/json' \
  -d "{\"current\":\"admin123\",\"next\":\"$NEW_PASS\"}" -o "$TMP/r2.json" -w "%{http_code}" > "$TMP/r2.code"
expect_code "change admin password" 200 "$(cat "$TMP/r2.code")"

echo "== 3. login with the new password (session cookie) =="
curl -s -m 10 -c "$JAR" -b "$JAR" -X POST "$BASE/api/admin/login" \
  -H 'Content-Type: application/json' -d "{\"password\":\"$NEW_PASS\"}" -o "$TMP/r3.json" -w "%{http_code}" > "$TMP/r3.code"
expect_code "login with new password" 200 "$(cat "$TMP/r3.code")"
grep -q "m365hub_admin" "$JAR" 2>/dev/null \
  && pass "session cookie issued" || fail "no m365hub_admin cookie in jar"

echo "== 4. session says logged in =="
curl -s -m 10 -b "$JAR" "$BASE/api/admin/session" -o "$TMP/r4.json"
[ "$(jget "$TMP/r4.json" "['loggedIn']")" = "true" ] \
  && pass "session loggedIn=true" || fail "session: $(cat "$TMP/r4.json")"

echo "== 5. accounts list (fresh gateway: empty) =="
curl -s -m 10 -b "$JAR" "$BASE/api/accounts" -o "$TMP/r5.json" -w "%{http_code}" > "$TMP/r5.code"
expect_code "GET /api/accounts" 200 "$(cat "$TMP/r5.code")"
[ "$(jget "$TMP/r5.json" "['accounts']")" = "[]" ] \
  && pass "accounts list is empty" || fail "accounts: $(cat "$TMP/r5.json")"

echo "== 6. PKCE start =="
curl -s -m 15 -b "$JAR" -X POST "$BASE/api/auth/start" \
  -H 'Content-Type: application/json' -d '{"flow":"pkce"}' -o "$TMP/r6.json" -w "%{http_code}" > "$TMP/r6.code"
expect_code "POST /api/auth/start pkce" 200 "$(cat "$TMP/r6.code")"
AUTH_URL="$(jget "$TMP/r6.json" "['authUrl']")"
echo "authUrl: $AUTH_URL" | tee -a "$SUMMARY"
case "$AUTH_URL" in
  https://login.microsoftonline.com/*code_challenge=*)
    pass "PKCE auth URL is a Microsoft login URL with a code challenge" ;;
  *) fail "unexpected authUrl: $AUTH_URL" ;;
esac

echo "== 7. device-code start =="
curl -s -m 30 -b "$JAR" -X POST "$BASE/api/auth/start" \
  -H 'Content-Type: application/json' -d '{"flow":"device"}' -o "$TMP/r7.json" -w "%{http_code}" > "$TMP/r7.code"
expect_code "POST /api/auth/start device" 200 "$(cat "$TMP/r7.code")"
USER_CODE="$(jget "$TMP/r7.json" "['userCode']")"
echo "device userCode: $USER_CODE" | tee -a "$SUMMARY"
[ -n "$USER_CODE" ] && [ "$USER_CODE" != "None" ] \
  && pass "device flow returned a user code" || fail "device: $(cat "$TMP/r7.json")"

echo "== 8. bogus PKCE callback is rejected cleanly =="
curl -s -m 60 -b "$JAR" -X POST "$BASE/api/auth/callback" \
  -H 'Content-Type: application/json' \
  -d '{"flow":"pkce","callbackUrl":"https://localhost/callback?code=bogus&state=x"}' \
  -o "$TMP/r8.json" -w "%{http_code}" > "$TMP/r8.code"
expect_code "POST /api/auth/callback (bogus)" 400 "$(cat "$TMP/r8.code")"
[ "$(jget "$TMP/r8.json" "['error']")" = "auth_failed" ] \
  && pass "bogus callback -> auth_failed" || fail "callback: $(cat "$TMP/r8.json")"

echo "== 9. auth status: still zero accounts =="
curl -s -m 10 -b "$JAR" "$BASE/api/auth/status" -o "$TMP/r9.json"
[ "$(jget "$TMP/r9.json" "['count']")" = "0" ] \
  && pass "auth status count=0" || fail "auth status: $(cat "$TMP/r9.json")"

echo "== 10. chat with zero accounts fails cleanly =="
curl -s -m 30 -b "$JAR" -X POST "$BASE/api/chat" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-6.1-sol-reasoning","messages":[{"role":"user","content":"你好"}],"attachments":[]}' \
  -o "$TMP/r10.json" -w "%{http_code}" > "$TMP/r10.code"
expect_code "POST /api/chat (no accounts)" 503 "$(cat "$TMP/r10.code")"
[ "$(jget "$TMP/r10.json" "['error']")" = "no_account" ] \
  && pass "chat -> 503 no_account (wired, fails gracefully)" \
  || fail "chat: $(cat "$TMP/r10.json")"

echo "== screenshot + quit =="
screencapture -x "$TMP/m365hub-account-chat-shot.png" 2>/dev/null || echo "screencapture failed"
osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || pkill -f "M365Hub.app" || true
sleep 2

echo "== summary =="
cat "$SUMMARY"
if [ "$FAIL" = "0" ]; then echo "ACCOUNT-CHAT-TEST: PASS"; exit 0
else echo "ACCOUNT-CHAT-TEST: FAIL"; exit 1; fi
