#!/bin/bash
# Real-account test via PKCE in the CI Mac environment.
#
# Why PKCE instead of the device-code flow: PKCE uses the Office web
# Copilot client (c0ab8ce9...), not the FOCI "Microsoft Office" client
# (d3590ed6...) the device-code flow uses, so a Conditional Access policy
# that blocks the latter may still allow this one.
#
# Round trip (the runner cannot receive input mid-run, so it goes through
# a GitHub issue): the runner starts PKCE and posts the auth URL to an
# issue; the operator opens it in a browser, signs in, copies the full
# address-bar URL from the nativeclient landing page (it contains code=
# and state=), and posts it as a comment on the same issue; this script
# polls the comments and completes the callback. The pending login
# expires 10 minutes after the start, so the poll runs at most 9 minutes.
# The comment carrying the code is deleted right after use.
#
# Usage: scripts/test-real-account-pkce.sh <path-to-M365Hub.app>
# Exit 0 only if the account is added and the chat returns real content.
set -u
APP="${1:?usage: test-real-account-pkce.sh <M365Hub.app>}"
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
JAR="$TMP/m365hub-real-cookies.txt"
SUMMARY="$TMP/m365hub-real-account-pkce-summary.txt"
ADMIN_PASS="ci-test-pass-20261101"
REPO="ryc2077/M365Hub-mac"
FAIL=0
: > "$SUMMARY"

note() { echo "$1" | tee -a "$SUMMARY"; }
fail() { FAIL=1; note "FAIL: $1"; }
pass() { note "PASS: $1"; }
jget() { python3 -c "import json,sys; d=json.load(open('$1')); v=d$2; print(v if not isinstance(v,bool) else str(v).lower())" 2>/dev/null; }
gh_api() { curl -s -H "Authorization: Bearer ${GITHUB_TOKEN:?no GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO$1" "${@:2}"; }

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
login_with() {
  curl -s -m 10 -c "$JAR" -b "$JAR" -X POST "$BASE/api/admin/login" \
    -H 'Content-Type: application/json' -d "{\"password\":\"$1\"}" -o "$TMP/p1.json" -w "%{http_code}"
}
CODE=$(login_with "$ADMIN_PASS")
if [ "$CODE" = "200" ] && [ "$(jget "$TMP/p1.json" "['ok']")" = "true" ]; then
  pass "admin login with the test password"
else
  curl -s -m 10 -X POST "$BASE/api/admin/login" \
    -H 'Content-Type: application/json' -d '{"password":"admin123"}' -o "$TMP/p1.json"
  if [ "$(jget "$TMP/p1.json" "['must_change_password']")" = "true" ]; then
    curl -s -m 10 -X POST "$BASE/api/admin/password" \
      -H 'Content-Type: application/json' \
      -d "{\"current\":\"admin123\",\"next\":\"$ADMIN_PASS\"}" -o "$TMP/p2.json" -w "%{http_code}" > "$TMP/p2.code"
    [ "$(cat "$TMP/p2.code")" = "200" ] && pass "changed default admin password" || fail "password change: $(cat "$TMP/p2.json")"
    CODE=$(login_with "$ADMIN_PASS")
    [ "$CODE" = "200" ] && pass "admin login with the test password" || fail "admin login: $(cat "$TMP/p1.json")"
  else
    fail "admin login with either password: $(cat "$TMP/p1.json")"
  fi
fi

echo "== accounts list before =="
curl -s -m 10 -b "$JAR" "$BASE/api/accounts" -o "$TMP/p3.json"
[ "$(jget "$TMP/p3.json" "['accounts']")" = "[]" ] \
  && pass "accounts list starts empty" || note "accounts before: $(cat "$TMP/p3.json")"

echo "== PKCE start =="
curl -s -m 30 -b "$JAR" -X POST "$BASE/api/auth/start" \
  -H 'Content-Type: application/json' -d '{"flow":"pkce"}' \
  -o "$TMP/p4.json" -w "%{http_code}" > "$TMP/p4.code"
[ "$(cat "$TMP/p4.code")" = "200" ] && pass "PKCE flow started" || fail "PKCE start: $(cat "$TMP/p4.json")"
AUTH_URL="$(jget "$TMP/p4.json" "['authUrl']")"
echo "PKCE-AUTH-URL: $AUTH_URL" | tee -a "$SUMMARY"
[ -n "$AUTH_URL" ] || fail "PKCE start returned no authUrl"

# Post the auth URL to an issue and wait for the callback URL as a comment.
ISSUE_NUM=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
  ISSUE_BODY="Open this URL in a browser and sign in as copilot@wt3z38wld.onmicrosoft.com. After sign-in the browser lands on the nativeclient page; copy the FULL address-bar URL (it contains code= and state=) and post it as a comment on this issue, nothing else. The runner polls comments for up to 9 minutes (the pending login expires 10 minutes after the start).

AUTH-URL: $AUTH_URL"
  ISSUE_JSON=$(python3 -c "import json,sys; print(json.dumps({'title':'Real-account test PKCE auth URL','body':sys.argv[1]}))" "$ISSUE_BODY")
  ISSUE_NUM=$(gh_api "/issues" -X POST -d "$ISSUE_JSON" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)
  echo "ISSUE: $ISSUE_NUM" | tee -a "$SUMMARY"
else
  fail "no GITHUB_TOKEN; the PKCE round trip needs it"
fi
[ -n "$ISSUE_NUM" ] || fail "issue creation failed"

echo "== poll issue comments for the callback URL (up to 9 minutes) =="
CALLBACK_URL=""
COMMENT_ID=""
for i in $(seq 1 27); do
  sleep 20
  FOUND=$(gh_api "/issues/$ISSUE_NUM/comments" \
    | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if 'code=' in (c.get('body') or ''):
        print(str(c['id']) + '\t' + c['body'])
        break
" 2>/dev/null)
  if [ -n "$FOUND" ]; then
    COMMENT_ID="${FOUND%%$'\t'*}"
    COMMENT_BODY="${FOUND#*$'\t'}"
    CALLBACK_URL=$(echo "$COMMENT_BODY" | grep -o 'https://[^[:space:]"]*code=[^[:space:]"]*' | head -n 1)
    [ -n "$CALLBACK_URL" ] || CALLBACK_URL="$COMMENT_BODY"
    echo "CALLBACK-URL found (comment $COMMENT_ID)" | tee -a "$SUMMARY"
    break
  fi
  echo "poll $i: no callback comment yet"
done
[ -n "$CALLBACK_URL" ] || fail "no callback URL comment appeared within 9 minutes"

echo "== PKCE callback =="
if [ -n "$CALLBACK_URL" ]; then
  # Build the JSON body in a variable first: nesting a double-quoted
  # python -c call inside "$(...)" inside curl's -d "..." breaks on the
  # runner's shell (the dict braces get brace-expanded and python sees
  # two mangled fragments). The same build-then-pass shape already works
  # for the issue creation above.
  CALLBACK_JSON=$(python3 -c "import json,sys; print(json.dumps({'flow':'pkce','callbackUrl':sys.argv[1]}))" "$CALLBACK_URL")
  [ -n "$CALLBACK_JSON" ] || fail "could not build the callback JSON body"
  curl -s -m 60 -b "$JAR" -X POST "$BASE/api/auth/callback" \
    -H 'Content-Type: application/json' \
    -d "$CALLBACK_JSON" \
    -o "$TMP/p5.json" -w "%{http_code}" > "$TMP/p5.code"
  if [ "$(cat "$TMP/p5.code")" = "200" ]; then
    echo "ACCOUNT-ADDED: $(cat "$TMP/p5.json")" | tee -a "$SUMMARY"
    pass "PKCE callback completed (account added)"
  else
    fail "PKCE callback http $(cat "$TMP/p5.code"): $(cat "$TMP/p5.json" | head -c 500)"
  fi
  # Delete the comment carrying the one-shot code, best effort.
  if [ -n "$COMMENT_ID" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    gh_api "/issues/comments/$COMMENT_ID" -X DELETE >/dev/null 2>&1 || true
  fi
fi

echo "== accounts list after =="
curl -s -m 10 -b "$JAR" "$BASE/api/accounts" -o "$TMP/p6.json"
ACCOUNTS="$(jget "$TMP/p6.json" "['accounts']")"
echo "accounts: $ACCOUNTS" | tee -a "$SUMMARY"
echo "$ACCOUNTS" | grep -q "copilot@wt3z38wld.onmicrosoft.com" \
  && pass "account copilot@wt3z38wld.onmicrosoft.com is listed" \
  || fail "expected account not in list: $ACCOUNTS"
curl -s -m 10 -b "$JAR" "$BASE/api/auth/status" -o "$TMP/p7.json"
[ "$(jget "$TMP/p7.json" "['count']")" = "1" ] \
  && pass "auth status count=1" || fail "auth status: $(cat "$TMP/p7.json")"

echo "== real chat with the account =="
curl -s -m 180 -b "$JAR" -X POST "$BASE/api/chat" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-6.1-sol-reasoning","messages":[{"role":"user","content":"你好，请用一句话介绍你自己"}],"attachments":[]}' \
  -o "$TMP/p8.json" -w "%{http_code}" > "$TMP/p8.code"
[ "$(cat "$TMP/p8.code")" = "200" ] && pass "chat returned http 200" || fail "chat http $(cat "$TMP/p8.code"): $(cat "$TMP/p8.json" | head -c 500)"
CONTENT="$(jget "$TMP/p8.json" "['content']")"
if [ -n "$CONTENT" ] && [ "$CONTENT" != "None" ]; then
  echo "CHAT-REPLY: $(echo "$CONTENT" | head -c 500)" | tee -a "$SUMMARY"
  pass "chat returned real content"
else
  fail "chat content empty: $(cat "$TMP/p8.json" | head -c 500)"
fi

echo "== screenshot (the app stays running: the gateway is handed off to the CodeX test, which quits the app when it is done) =="
screencapture -x "$TMP/m365hub-real-account-pkce-shot.png" 2>/dev/null || echo "screencapture failed"
sleep 2
if [ -n "$ISSUE_NUM" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  gh_api "/issues/$ISSUE_NUM" -X PATCH -d '{"state":"closed"}' >/dev/null 2>&1 || true
fi

echo "== summary =="
cat "$SUMMARY"
if [ "$FAIL" = "0" ]; then echo "REAL-ACCOUNT-PKCE-TEST: PASS"; exit 0
else echo "REAL-ACCOUNT-PKCE-TEST: FAIL"; exit 1; fi
