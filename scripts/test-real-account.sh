#!/bin/bash
# Real-account test in the CI Mac environment: add a Microsoft 365 account
# through the device-code flow and send one real chat message.
#
# The Microsoft sign-in is completed by an operator in a browser at
# https://microsoft.com/devicelogin while this script polls the callback.
# No account credential is stored in the repo or the workflow: the device
# code is printed to the job log, the operator signs in there, and this
# script only ever sees the resulting account id and email.
#
# Usage: scripts/test-real-account.sh <path-to-M365Hub.app>
# Exit 0 only if the account is added and the chat returns real content.
set -u
APP="${1:?usage: test-real-account.sh <M365Hub.app>}"
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
JAR="$TMP/m365hub-real-cookies.txt"
SUMMARY="$TMP/m365hub-real-account-summary.txt"
ADMIN_PASS="ci-test-pass-20261101"
FAIL=0
: > "$SUMMARY"

note() { echo "$1" | tee -a "$SUMMARY"; }
fail() { FAIL=1; note "FAIL: $1"; }
pass() { note "PASS: $1"; }
jget() { python3 -c "import json,sys; d=json.load(open('$1')); v=d$2; print(v if not isinstance(v,bool) else str(v).lower())" 2>/dev/null; }

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

echo "== admin login =="
# The earlier account-chat step in this run may already have changed the
# password to ADMIN_PASS; otherwise start from the default and change it.
login_with() {
  curl -s -m 10 -c "$JAR" -b "$JAR" -X POST "$BASE/api/admin/login" \
    -H 'Content-Type: application/json' -d "{\"password\":\"$1\"}" -o "$TMP/a1.json" -w "%{http_code}"
}
CODE=$(login_with "$ADMIN_PASS")
if [ "$CODE" = "200" ] && [ "$(jget "$TMP/a1.json" "['ok']")" = "true" ]; then
  pass "admin login with the test password"
else
  curl -s -m 10 -X POST "$BASE/api/admin/login" \
    -H 'Content-Type: application/json' -d '{"password":"admin123"}' -o "$TMP/a1.json"
  if [ "$(jget "$TMP/a1.json" "['must_change_password']")" = "true" ]; then
    curl -s -m 10 -X POST "$BASE/api/admin/password" \
      -H 'Content-Type: application/json' \
      -d "{\"current\":\"admin123\",\"next\":\"$ADMIN_PASS\"}" -o "$TMP/a2.json" -w "%{http_code}" > "$TMP/a2.code"
    [ "$(cat "$TMP/a2.code")" = "200" ] && pass "changed default admin password" || fail "password change: $(cat "$TMP/a2.json")"
    CODE=$(login_with "$ADMIN_PASS")
    [ "$CODE" = "200" ] && pass "admin login with the test password" || fail "admin login: $(cat "$TMP/a1.json")"
  else
    fail "admin login with either password: $(cat "$TMP/a1.json")"
  fi
fi

echo "== accounts list before =="
curl -s -m 10 -b "$JAR" "$BASE/api/accounts" -o "$TMP/a3.json"
[ "$(jget "$TMP/a3.json" "['accounts']")" = "[]" ] \
  && pass "accounts list starts empty" || note "accounts before: $(cat "$TMP/a3.json")"

echo "== device-code start =="
curl -s -m 30 -b "$JAR" -X POST "$BASE/api/auth/start" \
  -H 'Content-Type: application/json' -d '{"flow":"device"}' \
  -o "$TMP/a4.json" -w "%{http_code}" > "$TMP/a4.code"
[ "$(cat "$TMP/a4.code")" = "200" ] && pass "device flow started" || fail "device start: $(cat "$TMP/a4.json")"
USER_CODE="$(jget "$TMP/a4.json" "['userCode']")"
AUTH_URL="$(jget "$TMP/a4.json" "['authUrl']")"
echo "DEVICE-CODE: $USER_CODE" | tee -a "$SUMMARY"
echo "DEVICE-URL: $AUTH_URL" | tee -a "$SUMMARY"
echo "Sign in at https://microsoft.com/devicelogin with the code above; this script waits for it."

# The job log is too slow to read live (run 12: the code sat in the log for
# ~20 minutes before it showed up in a download, and the 15-minute code
# expired first). Post the code to a GitHub issue instead: the issues API
# reads it back instantly. The code dies in 15 minutes anyway, and the
# issue is closed at the end of this script.
ISSUE_NUM=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
  ISSUE_NUM=$(curl -s -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/ryc2077/M365Hub-mac/issues" \
    -d "{\"title\":\"Real-account test device code\",\"body\":\"Sign in at https://microsoft.com/devicelogin with code: $USER_CODE (expires in 15 minutes). The runner is waiting on the device callback.\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)
  echo "ISSUE: $ISSUE_NUM" | tee -a "$SUMMARY"
else
  echo "no GITHUB_TOKEN; operator must read the code from the job log" | tee -a "$SUMMARY"
fi

echo "== wait for the operator sign-in (one long-poll callback) =="
# CompleteDevice long-polls Microsoft until the user approves, so one call
# with a long timeout is the right shape; the old 40x30s loop only ever
# cut the long-poll off (http 000) and burned the code's lifetime.
ADDED=0
curl -s -m 840 -b "$JAR" -X POST "$BASE/api/auth/callback" \
  -H 'Content-Type: application/json' \
  -d "{\"flow\":\"device\",\"userCode\":\"$USER_CODE\"}" \
  -o "$TMP/a5.json" -w "%{http_code}" > "$TMP/a5.code"
if [ "$(cat "$TMP/a5.code")" = "200" ]; then
  ADDED=1
  echo "ACCOUNT-ADDED: $(cat "$TMP/a5.json")" | tee -a "$SUMMARY"
  pass "device callback completed (account added)"
else
  echo "callback result: http $(cat "$TMP/a5.code") $(cat "$TMP/a5.json" | head -c 400)" | tee -a "$SUMMARY"
  fail "device callback never completed (operator sign-in missing or expired)"
fi
if [ -n "$ISSUE_NUM" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  curl -s -X PATCH -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/ryc2077/M365Hub-mac/issues/$ISSUE_NUM" \
    -d '{"state":"closed"}' >/dev/null || true
fi

echo "== accounts list after =="
curl -s -m 10 -b "$JAR" "$BASE/api/accounts" -o "$TMP/a6.json"
ACCOUNTS="$(jget "$TMP/a6.json" "['accounts']")"
echo "accounts: $ACCOUNTS" | tee -a "$SUMMARY"
echo "$ACCOUNTS" | grep -q "copilot@wt3z38wld.onmicrosoft.com" \
  && pass "account copilot@wt3z38wld.onmicrosoft.com is listed" \
  || fail "expected account not in list: $ACCOUNTS"
curl -s -m 10 -b "$JAR" "$BASE/api/auth/status" -o "$TMP/a7.json"
[ "$(jget "$TMP/a7.json" "['count']")" = "1" ] \
  && pass "auth status count=1" || fail "auth status: $(cat "$TMP/a7.json")"

echo "== real chat with the account =="
curl -s -m 180 -b "$JAR" -X POST "$BASE/api/chat" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-6.1-sol-reasoning","messages":[{"role":"user","content":"你好，请用一句话介绍你自己"}],"attachments":[]}' \
  -o "$TMP/a8.json" -w "%{http_code}" > "$TMP/a8.code"
[ "$(cat "$TMP/a8.code")" = "200" ] && pass "chat returned http 200" || fail "chat http $(cat "$TMP/a8.code"): $(cat "$TMP/a8.json" | head -c 500)"
CONTENT="$(jget "$TMP/a8.json" "['content']")"
if [ -n "$CONTENT" ] && [ "$CONTENT" != "None" ]; then
  echo "CHAT-REPLY: $(echo "$CONTENT" | head -c 500)" | tee -a "$SUMMARY"
  pass "chat returned real content"
else
  fail "chat content empty: $(cat "$TMP/a8.json" | head -c 500)"
fi

echo "== screenshot + quit =="
screencapture -x "$TMP/m365hub-real-account-shot.png" 2>/dev/null || echo "screencapture failed"
osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || pkill -f "M365Hub.app" || true
sleep 2

echo "== summary =="
cat "$SUMMARY"
if [ "$FAIL" = "0" ]; then echo "REAL-ACCOUNT-TEST: PASS"; exit 0
else echo "REAL-ACCOUNT-TEST: FAIL"; exit 1; fi
