#!/bin/bash
# CodeX tool-call test for the Mac gateway in CI.
#
# Runs after the Real account test (PKCE) step, against the SAME gateway
# the PKCE script started: the PKCE script leaves the app (and its
# gateway) running, and this script quits the app when it is done. The
# PKCE step has already added the real Microsoft 365 account, so the
# gateway has a healthy account for Codex to call through. (Same shape
# as the Windows test, which went green on run 21, and the sandbox
# verification of 2026-10-26, where Codex created hello.txt, appended a
# line and cat it.)
#
# Flow: confirm the gateway + account are there -> admin login -> mint a
# /v1 API key -> npm install the Codex CLI -> write ~/.codex/config.toml
# (m365hub provider, wire_api=responses, model gpt-4-auto) -> two
# `codex exec` rounds: create hello.txt with one exact line, then append
# a second line and cat it. Both file contents are verified on disk, so
# a model merely claiming it did the work fails the test.
#
# YOLO mode (--dangerously-bypass-approvals-and-sandbox) is used on
# purpose: CodeX 0.166.0's --approve-for-me routes every command through
# an automatic "guardian" review that fails against this gateway
# (Windows run 17), and the workspace-write sandbox does not work on the
# Windows runner (Windows run 18). The runner is an ephemeral throwaway
# VM with no user data, so YOLO is contained here.
#
# Usage: scripts/test-codex-mac.sh (run from the repo root)
# Exit 0 only if both tool-call rounds really wrote the files.
set -u
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
JAR="$TMP/m365hub-codex-mac-cookies.txt"
SUMMARY="$TMP/m365hub-codex-mac-summary.txt"
ADMIN_PASS="ci-test-pass-20261101"
WORKDIR="$TMP/codex-mac-test"
FAIL=0
: > "$SUMMARY"
PY="$(command -v python3 || echo python3)"
export PYTHONIOENCODING=utf-8
"$PY" -c "import sys; sys.exit(0)" 2>/dev/null \
  || { echo "FATAL: no working python ($PY) for the JSON checks"; exit 1; }

note() { echo "$1" | tee -a "$SUMMARY"; }
fail() { FAIL=1; note "FAIL: $1"; }
pass() { note "PASS: $1"; }
# Read one JSON value from a file. The path and the key expression travel
# as argv, never interpolated into the -c string.
jget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); v=eval("d"+sys.argv[2]); print(v if not isinstance(v,bool) else str(v).lower())' "$1" "$2" 2>/dev/null; }

# macOS has no `timeout` command (BSD userland; exit 127), so run a
# command with a deadline the portable way: GNU timeout when it exists,
# otherwise perl's alarm (perl ships with macOS and the runner).
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@";
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# The PKCE script left the app (and its gateway) running; this script
# quits the app on the way out, success or failure.
quit_app() {
  osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || pkill -f "M365Hub.app" 2>/dev/null || true
}
trap quit_app EXIT

echo "== gateway still up (handed off by the PKCE step) =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$BASE/api/admin/session" || echo "000")
[ "$CODE" = "200" ] && pass "gateway up (session answers)" || fail "gateway not answering: http $CODE"

echo "== admin login + mint a /v1 API key =="
rm -f "$JAR"
CODE=$(curl -s -m 10 -c "$JAR" -b "$JAR" -X POST "$BASE/api/admin/login" \
  -H 'Content-Type: application/json' -d "{\"password\":\"$ADMIN_PASS\"}" \
  -o "$TMP/c1.json" -w "%{http_code}")
[ "$CODE" = "200" ] && [ "$(jget "$TMP/c1.json" "['ok']")" = "true" ] \
  && pass "admin login" || fail "admin login: $(cat "$TMP/c1.json" | head -c 300)"
# The PKCE step's account must still be there, or Codex has nothing to
# call through.
curl -s -m 10 -b "$JAR" "$BASE/api/auth/status" -o "$TMP/c3.json"
[ "$(jget "$TMP/c3.json" "['count']")" = "1" ] \
  && pass "auth status count=1" || fail "auth status: $(cat "$TMP/c3.json" | head -c 300)"
KEY_JSON=$("$PY" -c "import json,sys; print(json.dumps({'name':'codex-mac-ci'}))")
curl -s -m 10 -b "$JAR" -X POST "$BASE/api/admin/keys" \
  -H 'Content-Type: application/json' -d "$KEY_JSON" \
  -o "$TMP/c2.json" -w "%{http_code}" > "$TMP/c2.code"
API_KEY="$(jget "$TMP/c2.json" "['plaintext']")"
if [ "$(cat "$TMP/c2.code")" = "200" ] && [ -n "$API_KEY" ] && [ "$API_KEY" != "None" ]; then
  pass "API key minted"
else
  fail "API key mint failed: $(cat "$TMP/c2.json" | head -c 300)"
fi

echo "== install Codex CLI =="
command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
  || fail "node/npm not on PATH"
# npm's global bin dir is on PATH on the runner; if codex is still not
# found after install, fall back to the npm prefix bin location.
if ! command -v codex >/dev/null 2>&1; then
  npm install -g @openai/codex >"$TMP/npm-codex.log" 2>&1 \
    && pass "npm install -g @openai/codex" || { fail "npm install failed"; tail -n 20 "$TMP/npm-codex.log" | tee -a "$SUMMARY"; }
fi
if ! command -v codex >/dev/null 2>&1; then
  NPM_BIN="$(npm config get prefix 2>/dev/null)/bin/codex"
  [ -x "$NPM_BIN" ] && export PATH="$PATH:$(dirname "$NPM_BIN")"
fi
CODEX_VER="$(codex --version 2>&1 | head -n 1)"
[ -n "$CODEX_VER" ] && pass "codex $CODEX_VER" || fail "codex binary not found after install"
# YOLO mode: the flag sets both knobs (approvals never, sandbox
# danger-full-access). Verify it exists in this codex build instead of
# guessing. Do NOT combine it with -c approval_policy or -s - the flag
# already sets both.
HELP="$(codex exec --help 2>&1 || true)"
APPROVE=""
if echo "$HELP" | grep -q "dangerously-bypass-approvals-and-sandbox"; then APPROVE="--dangerously-bypass-approvals-and-sandbox";
else fail "codex exec has no --dangerously-bypass-approvals-and-sandbox flag"; fi
[ -n "$APPROVE" ] && pass "approval mode: YOLO (--dangerously-bypass-approvals-and-sandbox)"
SKIP=""
echo "$HELP" | grep -q "skip-git-repo-check" && SKIP="--skip-git-repo-check"

echo "== Codex config (m365hub provider) =="
mkdir -p "$HOME/.codex"
cat > "$HOME/.codex/config.toml" <<'EOF'
model_provider = "m365hub"
model = "gpt-4-auto"
[model_providers.m365hub]
name = "m365hub"
base_url = "http://127.0.0.1:8230/v1"
env_key = "M365HUB_API_KEY"
wire_api = "responses"
EOF
export M365HUB_API_KEY="$API_KEY"
pass "codex config written ($HOME/.codex/config.toml)"

echo "== CodeX tool call, round 1: create hello.txt =="
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
cd "$WORKDIR" && git init -q 2>/dev/null || true
run_timeout 300 codex exec $APPROVE $SKIP "Create a file named hello.txt in the current directory containing exactly one line: codex-via-m365hub-mac-ok. Do not write anything else into the file." < /dev/null > "$TMP/codex1.log" 2>&1
echo "codex round 1 exit: $?" | tee -a "$SUMMARY"
# The session header must show approval: never, or the guardian path
# is back and the run will fail the same way Windows run 17 did.
grep -q "approval: never" "$TMP/codex1.log" \
  && pass "codex ran with approval: never" \
  || fail "codex did not run with approval: never (guardian path may be back)"
# YOLO sets the sandbox to danger-full-access; if the header shows
# anything else, the flag did not take effect.
grep -q "sandbox: danger-full-access" "$TMP/codex1.log" \
  && pass "codex ran with sandbox: danger-full-access (YOLO)" \
  || fail "codex sandbox is not danger-full-access (YOLO flag may not have taken effect)"
if [ -f "$WORKDIR/hello.txt" ]; then
  CONTENT="$(cat "$WORKDIR/hello.txt")"
  echo "hello.txt: [$CONTENT]" | tee -a "$SUMMARY"
  [ "$CONTENT" = "codex-via-m365hub-mac-ok" ] \
    && pass "round 1: hello.txt created with the exact line" \
    || fail "round 1: hello.txt content wrong"
else
  fail "round 1: hello.txt was not created"
  tail -n 30 "$TMP/codex1.log" | tee -a "$SUMMARY"
fi

echo "== CodeX tool call, round 2: append + cat =="
cd "$WORKDIR"
run_timeout 300 codex exec $APPROVE $SKIP "Append a second line, second-line, to hello.txt in the current directory, then print the file contents with cat." < /dev/null > "$TMP/codex2.log" 2>&1
echo "codex round 2 exit: $?" | tee -a "$SUMMARY"
# Substring match on purpose: round 1's file may have no trailing
# newline (the model may use printf without \n to satisfy "exactly one
# line"), so the appended line can end up glued onto the same line.
# Whole-line (-x) matching would fail that even though the append really
# happened (Windows run 20).
if grep -q "codex-via-m365hub-mac-ok" "$WORKDIR/hello.txt" && grep -q "second-line" "$WORKDIR/hello.txt"; then
  pass "round 2: second line appended, both lines present"
  echo "hello.txt now:" | tee -a "$SUMMARY"
  cat "$WORKDIR/hello.txt" | tee -a "$SUMMARY"
else
  fail "round 2: hello.txt does not have both lines"
  cat "$WORKDIR/hello.txt" 2>&1 | tee -a "$SUMMARY"
  tail -n 20 "$TMP/codex2.log" | tee -a "$SUMMARY"
fi

echo "== CodeX tools coverage: every supported tool, one round each =="
# The user's Mac Codex kept replying with a plan and calling no tools at
# all, so this section proves each tool actually fires through this
# gateway, one round per tool, with the effect verified on disk (not by
# the model claiming it). --json (when this codex build has it) gives a
# JSONL transcript; scripts/codex_tools.py lists the function_call names
# in it, so we know exactly which tool the model used for each round.
TOOLS_PY="scripts/codex_tools.py"
[ -f "$TOOLS_PY" ] || TOOLS_PY=""
JSON=""
echo "$HELP" | grep -q -e "--json" && JSON="--json"
[ -n "$JSON" ] && pass "codex exec supports --json (tool names will be recorded)" \
  || note "codex exec has no --json flag here; tool names cannot be recorded, disk effects still verify the work"
tools_used() { # $1 = log file; prints space-separated tool names, or empty
  if [ -n "$JSON" ] && [ -n "$TOOLS_PY" ]; then
    "$PY" "$TOOLS_PY" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
  fi
}
tool_called() { # $1 = tools string, $2 = tool name
  case " $1 " in *" $2 "*) return 0;; *) return 1;; esac
}
TOOLS_DIR="$WORKDIR/tools"
mkdir -p "$TOOLS_DIR"
cd "$TOOLS_DIR"

echo "== round 3: shell tool (uname) =="
run_timeout 300 codex exec $APPROVE $SKIP $JSON "Run the shell command uname -s and write its output (exactly one word, no extra text) into a file named shell-os.txt in the current directory." < /dev/null > "$TMP/codex3.log" 2>&1
T3_TOOLS="$(tools_used "$TMP/codex3.log")"
[ -n "$T3_TOOLS" ] && note "round 3 tools used: $T3_TOOLS"
if [ -f "$TOOLS_DIR/shell-os.txt" ] && [ "$(cat "$TOOLS_DIR/shell-os.txt" | tr -d '[:space:]')" = "Darwin" ]; then
  pass "round 3: shell tool wrote shell-os.txt (Darwin)"
  tool_called "$T3_TOOLS" "shell" && pass "round 3: shell tool call recorded" \
    || { [ -n "$JSON" ] && fail "round 3: shell tool call NOT recorded (tools: $T3_TOOLS)"; }
else
  fail "round 3: shell-os.txt missing or wrong"
  tail -n 20 "$TMP/codex3.log" | tee -a "$SUMMARY"
fi

echo "== round 4: apply_patch create =="
run_timeout 300 codex exec $APPROVE $SKIP $JSON "Use the file editing tool (apply_patch) to create a new file named patch-created.txt in the current directory with exactly these two lines: first-patch-line and second-patch-line. Do not use shell commands to create the file." < /dev/null > "$TMP/codex4.log" 2>&1
T4_TOOLS="$(tools_used "$TMP/codex4.log")"
[ -n "$T4_TOOLS" ] && note "round 4 tools used: $T4_TOOLS"
if grep -q "first-patch-line" "$TOOLS_DIR/patch-created.txt" 2>/dev/null && grep -q "second-patch-line" "$TOOLS_DIR/patch-created.txt" 2>/dev/null; then
  pass "round 4: patch-created.txt exists with both lines"
  tool_called "$T4_TOOLS" "apply_patch" && pass "round 4: apply_patch call recorded" \
    || { [ -n "$JSON" ] && fail "round 4: apply_patch call NOT recorded (tools: $T4_TOOLS)"; }
else
  fail "round 4: patch-created.txt missing or wrong"
  tail -n 20 "$TMP/codex4.log" | tee -a "$SUMMARY"
fi

echo "== round 5: apply_patch edit =="
run_timeout 300 codex exec $APPROVE $SKIP $JSON "Use the file editing tool (apply_patch) to change the second line of patch-created.txt to second-patch-line-edited. Do not use shell commands to edit the file." < /dev/null > "$TMP/codex5.log" 2>&1
T5_TOOLS="$(tools_used "$TMP/codex5.log")"
[ -n "$T5_TOOLS" ] && note "round 5 tools used: $T5_TOOLS"
if grep -q "second-patch-line-edited" "$TOOLS_DIR/patch-created.txt" 2>/dev/null; then
  pass "round 5: second line edited in place"
  tool_called "$T5_TOOLS" "apply_patch" && pass "round 5: apply_patch call recorded" \
    || { [ -n "$JSON" ] && fail "round 5: apply_patch call NOT recorded (tools: $T5_TOOLS)"; }
else
  fail "round 5: patch-created.txt was not edited"
  cat "$TOOLS_DIR/patch-created.txt" 2>&1 | tee -a "$SUMMARY"
  tail -n 20 "$TMP/codex5.log" | tee -a "$SUMMARY"
fi

echo "== round 6: read tool =="
run_timeout 300 codex exec $APPROVE $SKIP $JSON "Read the file patch-created.txt with the file reading tool and tell me its second line in your reply." < /dev/null > "$TMP/codex6.log" 2>&1
T6_TOOLS="$(tools_used "$TMP/codex6.log")"
[ -n "$T6_TOOLS" ] && note "round 6 tools used: $T6_TOOLS"
if grep -q "second-patch-line-edited" "$TMP/codex6.log"; then
  pass "round 6: model read the file and reported the edited second line"
else
  fail "round 6: model did not report the edited second line"
  tail -n 20 "$TMP/codex6.log" | tee -a "$SUMMARY"
fi

echo "== round 7: apply_patch delete =="
run_timeout 300 codex exec $APPROVE $SKIP $JSON "Use the file editing tool (apply_patch) to delete the file shell-os.txt in the current directory." < /dev/null > "$TMP/codex7.log" 2>&1
T7_TOOLS="$(tools_used "$TMP/codex7.log")"
[ -n "$T7_TOOLS" ] && note "round 7 tools used: $T7_TOOLS"
if [ ! -f "$TOOLS_DIR/shell-os.txt" ]; then
  pass "round 7: shell-os.txt deleted"
  tool_called "$T7_TOOLS" "apply_patch" && pass "round 7: apply_patch call recorded" \
    || { [ -n "$JSON" ] && fail "round 7: apply_patch call NOT recorded (tools: $T7_TOOLS)"; }
else
  fail "round 7: shell-os.txt still exists"
  tail -n 20 "$TMP/codex7.log" | tee -a "$SUMMARY"
fi

echo "== round 8: web_search probe (informational only) =="
run_timeout 300 codex exec $APPROVE $SKIP $JSON "Search the web for the latest released version of the OpenAI Codex CLI and tell me the version number you found." < /dev/null > "$TMP/codex8.log" 2>&1
T8_TOOLS="$(tools_used "$TMP/codex8.log")"
[ -n "$T8_TOOLS" ] && note "round 8 tools used: $T8_TOOLS"
# Informational: the gateway may not implement web search at all, and
# that is a finding to report (and fix), not a reason to fail the run.
# A FAIL here would mask the core tools result.
if tool_called "$T8_TOOLS" "web_search"; then
  note "round 8: web_search IS supported through this gateway"
elif grep -qiE "0\.[0-9]+\.[0-9]+" "$TMP/codex8.log"; then
  note "round 8: model reported a version number without a web_search call (may be from memory)"
else
  note "round 8: web_search was NOT called (gateway may not implement it)"
fi

echo "== round 9: multi-step task (update_plan) =="
run_timeout 300 codex exec $APPROVE $SKIP $JSON "Do these three steps in order: 1) create plan-a.txt containing exactly the word apple, 2) create plan-b.txt containing exactly the word banana, 3) create plan-c.txt containing exactly the word cherry. Report each step as you finish it." < /dev/null > "$TMP/codex9.log" 2>&1
T9_TOOLS="$(tools_used "$TMP/codex9.log")"
[ -n "$T9_TOOLS" ] && note "round 9 tools used: $T9_TOOLS"
if [ "$(cat "$TOOLS_DIR/plan-a.txt" 2>/dev/null | tr -d '[:space:]')" = "apple" ] \
  && [ "$(cat "$TOOLS_DIR/plan-b.txt" 2>/dev/null | tr -d '[:space:]')" = "banana" ] \
  && [ "$(cat "$TOOLS_DIR/plan-c.txt" 2>/dev/null | tr -d '[:space:]')" = "cherry" ]; then
  pass "round 9: all three files created with the right words"
  tool_called "$T9_TOOLS" "update_plan" && note "round 9: update_plan call recorded" \
    || note "round 9: update_plan was NOT called (model did the steps without it)"
else
  fail "round 9: plan-a/b/c.txt missing or wrong"
  ls -la "$TOOLS_DIR" | tee -a "$SUMMARY"
  tail -n 20 "$TMP/codex9.log" | tee -a "$SUMMARY"
fi

echo "== summary =="
cat "$SUMMARY"
if [ "$FAIL" = "0" ]; then echo "CODEX-MAC-TEST: PASS"; exit 0
else echo "CODEX-MAC-TEST: FAIL"; exit 1; fi
