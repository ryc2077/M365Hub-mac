#!/bin/bash
# Desktop-flow test: does the reasoning model the desktop app uses
# (gpt-6.1-sol-reasoning) actually call tools through this gateway?
#
# Background: the command-line CodeX (model gpt-4-auto) calls tools fine
# in CI, but the user's desktop CodeX (default model
# gpt-6.1-sol-reasoning, same gateway on their Mac) only talks about a
# plan and never acts. Two variables differ at once -- the client
# (desktop app vs CLI) and the model (reasoning vs auto) -- so this
# script tests the model on its own, through the same gateway, on both
# API shapes a desktop client could use:
#   P1 control: /v1/responses, gpt-4-auto, tools         (known good)
#   P2: /v1/responses stream, gpt-6.1-sol-reasoning, tools
#   P4: /v1/chat/completions stream, gpt-6.1-sol-reasoning, tools
#   P5: CLI (codex exec) with model gpt-6.1-sol-reasoning, one file write
#   P7: the response.completed event itself must carry the function_call
#       (the old stream sent an empty output array there, and the old
#       chat-completions stream dropped tool_calls from its chunk, so a
#       strict client saw no calls even though the CLI -- which reads the
#       individual output_item events -- worked fine)
#   P8: /v1/responses with NO tools at all (the exact shape the desktop
#       app sends). The gateway must inject the default CodeX tools
#       (shell/read/apply_patch) so the model still emits a function call
#       instead of falling back to its own Linux container.
# If the reasoning model calls tools here, the gateway + model are fine
# and the fault is in the desktop app itself. If it does not (or takes
# many minutes to emit a single call), the model is the problem and the
# desktop's default model should change to gpt-4-auto.
#
# Self-contained: relaunches the app (the CodeX step quits it on exit),
# mints its own /v1 key, and quits the app on the way out so the cache
# save step can run cleanly.
# Usage: scripts/test-desktop-flow.sh <path-to-M365Hub.app>
set -u
APP="${1:?usage: test-desktop-flow.sh <M365Hub.app>}"
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
JAR="$TMP/m365hub-desktop-flow-cookies.txt"
SUMMARY="$TMP/m365hub-desktop-flow-summary.txt"
ADMIN_PASS="ci-test-pass-20261101"
FAIL=0
: > "$SUMMARY"
PY="$(command -v python3 || echo python3)"
export PYTHONIOENCODING=utf-8

note() { echo "$1" | tee -a "$SUMMARY"; }
fail() { FAIL=1; note "FAIL: $1"; }
pass() { note "PASS: $1"; }
jget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); v=eval("d"+sys.argv[2]); print(v if not isinstance(v,bool) else str(v).lower())' "$1" "$2" 2>/dev/null; }

quit_app() {
  osascript -e 'tell application "M365Hub" to quit' 2>/dev/null || pkill -f "M365Hub.app" 2>/dev/null || true
}
trap quit_app EXIT

echo "== launch the app and wait for its gateway =="
rm -f "$JAR"
open "$APP" || echo "open failed (exit $?)"
UP=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 2 "$BASE/api/admin/session" || echo "000")
  if [ "$CODE" = "200" ]; then UP=1; break; fi
  sleep 1
done
[ "$UP" = "1" ] && pass "gateway up (session answers)" || fail "gateway never answered"

echo "== admin login + mint a /v1 API key =="
CODE=$(curl -s -m 10 -c "$JAR" -b "$JAR" -X POST "$BASE/api/admin/login" \
  -H 'Content-Type: application/json' -d "{\"password\":\"$ADMIN_PASS\"}" \
  -o "$TMP/d0.json" -w "%{http_code}")
[ "$CODE" = "200" ] && [ "$(jget "$TMP/d0.json" "['ok']")" = "true" ] \
  && pass "admin login" || fail "admin login: $(cat "$TMP/d0.json" | head -c 300)"
curl -s -m 10 -b "$JAR" "$BASE/api/auth/status" -o "$TMP/d0s.json"
[ "$(jget "$TMP/d0s.json" "['count']")" = "1" ] \
  && pass "auth status count=1" || fail "auth status: $(cat "$TMP/d0s.json" | head -c 300)"
KEY_JSON=$("$PY" -c "import json,sys; print(json.dumps({'name':'desktop-flow-ci'}))")
curl -s -m 10 -b "$JAR" -X POST "$BASE/api/admin/keys" \
  -H 'Content-Type: application/json' -d "$KEY_JSON" \
  -o "$TMP/d0k.json" -w "%{http_code}" > "$TMP/d0k.code"
API_KEY="$(jget "$TMP/d0k.json" "['plaintext']")"
if [ "$(cat "$TMP/d0k.code")" = "200" ] && [ -n "$API_KEY" ] && [ "$API_KEY" != "None" ]; then
  pass "API key minted"
else
  fail "API key mint failed: $(cat "$TMP/d0k.json" | head -c 300)"
fi

# One function tool, same shape a coding client would send. The model
# must call it to answer; a text-only reply is a tool-call failure.
TOOLS_JSON='[{"type":"function","name":"run_shell","description":"Run a shell command and return its output","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to run"}},"required":["command"]}}]'
PROMPT="Use the run_shell tool to run the command uname -s and report exactly what it printed. You must call the tool; do not just guess the answer."

# P1 control: /v1/responses, gpt-4-auto (known good from the CLI test).
echo "== P1 control: /v1/responses, gpt-4-auto, tools =="
P1_JSON=$("$PY" -c "import json,sys; print(json.dumps({'model':'gpt-4-auto','input':sys.argv[1],'tools':json.loads(sys.argv[2]),'stream':False}))" "$PROMPT" "$TOOLS_JSON")
START=$(date +%s)
curl -s -m 180 -X POST "$BASE/v1/responses" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d "$P1_JSON" -o "$TMP/desktop-p1.json" -w "%{http_code}" > "$TMP/desktop-p1.code"
ELAPSED=$(( $(date +%s) - START ))
echo "P1: http $(cat "$TMP/desktop-p1.code") in ${ELAPSED}s" | tee -a "$SUMMARY"
if grep -q "function_call" "$TMP/desktop-p1.json" 2>/dev/null; then
  pass "P1: gpt-4-auto returned a function_call in ${ELAPSED}s"
else
  fail "P1: gpt-4-auto returned NO function_call in ${ELAPSED}s: $(head -c 300 "$TMP/desktop-p1.json")"
fi

# P2: /v1/responses stream, gpt-6.1-sol-reasoning (the desktop's model).
echo "== P2: /v1/responses stream, gpt-6.1-sol-reasoning, tools =="
P2_JSON=$("$PY" -c "import json,sys; print(json.dumps({'model':'gpt-6.1-sol-reasoning','input':sys.argv[1],'tools':json.loads(sys.argv[2]),'stream':True}))" "$PROMPT" "$TOOLS_JSON")
START=$(date +%s)
curl -s -m 420 -N -X POST "$BASE/v1/responses" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d "$P2_JSON" -o "$TMP/desktop-p2.log" -w "%{http_code}" > "$TMP/desktop-p2.code"
ELAPSED=$(( $(date +%s) - START ))
echo "P2: http $(cat "$TMP/desktop-p2.code") in ${ELAPSED}s" | tee -a "$SUMMARY"
if grep -q "function_call" "$TMP/desktop-p2.log" 2>/dev/null; then
  pass "P2: gpt-6.1-sol-reasoning returned a function_call (stream) in ${ELAPSED}s"
else
  fail "P2: gpt-6.1-sol-reasoning returned NO function_call (stream) in ${ELAPSED}s"
  tail -c 500 "$TMP/desktop-p2.log" | tee -a "$SUMMARY"
fi
grep -q "response.completed" "$TMP/desktop-p2.log" 2>/dev/null \
  && pass "P2: stream reached response.completed" \
  || fail "P2: stream did NOT reach response.completed"

# P7: the completed event itself must carry the function call. The old
# stream sent response.completed with an empty output array, so a client
# that reads tool calls from the completed event (rather than from the
# individual output_item events, as the CodeX CLI does) saw no calls.
echo "== P7: response.completed output carries the function_call =="
P7_OUT=$("$PY" -c '
import json,sys
found=False
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line=line.strip()
    if line.startswith("data:") and "response.completed" in line:
        try: payload=json.loads(line[5:])
        except Exception: continue
        out=payload.get("response",{}).get("output",[])
        found=any(isinstance(it,dict) and it.get("type")=="function_call" for it in out)
        break
print("yes" if found else "no")
' "$TMP/desktop-p2.log")
[ "$P7_OUT" = "yes" ] \
  && pass "P7: response.completed output contains a function_call" \
  || fail "P7: response.completed output has NO function_call"

# P8: no tools at all (the exact shape the desktop app sends). The gateway
# must inject the default CodeX tools (shell/read/apply_patch) so the model
# still emits a function call instead of falling back to its own container.
echo "== P8: /v1/responses, gpt-6.1-sol-reasoning, NO tools (desktop shape) =="
P8_PROMPT="Run the shell command uname -s on this machine and report exactly what it printed. Use the shell tool to run it; do not just guess the answer."
P8_JSON=$("$PY" -c "import json,sys; print(json.dumps({'model':'gpt-6.1-sol-reasoning','input':sys.argv[1],'stream':False}))" "$P8_PROMPT")
START=$(date +%s)
curl -s -m 420 -X POST "$BASE/v1/responses" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d "$P8_JSON" -o "$TMP/desktop-p8.json" -w "%{http_code}" > "$TMP/desktop-p8.code"
ELAPSED=$(( $(date +%s) - START ))
echo "P8: http $(cat "$TMP/desktop-p8.code") in ${ELAPSED}s" | tee -a "$SUMMARY"
P8_OUT=$("$PY" -c '
import json,sys
try: d=json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: print("no"); sys.exit()
out=d.get("output",[])
names=[it.get("name") for it in out if isinstance(it,dict) and it.get("type")=="function_call"]
print("yes" if "shell" in names else "no")
' "$TMP/desktop-p8.json")
[ "$P8_OUT" = "yes" ] \
  && pass "P8: no-tools request still returned a shell function_call in ${ELAPSED}s (default tools injected)" \
  || fail "P8: no-tools request returned NO shell function_call in ${ELAPSED}s: $(head -c 400 "$TMP/desktop-p8.json")"

# P4: /v1/chat/completions stream, gpt-6.1-sol-reasoning (the other shape
# a desktop client could use).
echo "== P4: /v1/chat/completions stream, gpt-6.1-sol-reasoning, tools =="
P4_JSON=$("$PY" -c "import json,sys; print(json.dumps({'model':'gpt-6.1-sol-reasoning','messages':[{'role':'user','content':sys.argv[1]}],'tools':json.loads(sys.argv[2]),'stream':True}))" "$PROMPT" "$TOOLS_JSON")
START=$(date +%s)
curl -s -m 420 -N -X POST "$BASE/v1/chat/completions" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d "$P4_JSON" -o "$TMP/desktop-p4.log" -w "%{http_code}" > "$TMP/desktop-p4.code"
ELAPSED=$(( $(date +%s) - START ))
echo "P4: http $(cat "$TMP/desktop-p4.code") in ${ELAPSED}s" | tee -a "$SUMMARY"
if grep -q "tool_calls" "$TMP/desktop-p4.log" 2>/dev/null; then
  pass "P4: gpt-6.1-sol-reasoning returned tool_calls (chat completions stream) in ${ELAPSED}s"
else
  fail "P4: gpt-6.1-sol-reasoning returned NO tool_calls (chat completions stream) in ${ELAPSED}s"
  tail -c 500 "$TMP/desktop-p4.log" | tee -a "$SUMMARY"
fi
grep -q "\[DONE\]" "$TMP/desktop-p4.log" 2>/dev/null \
  && pass "P4: stream reached [DONE]" \
  || fail "P4: stream did NOT reach [DONE]"

# P5: the CLI with the reasoning model. Same client as the proven
# gpt-4-auto run, only the model changes, so this isolates the model.
echo "== P5: CLI (codex exec) with model gpt-6.1-sol-reasoning =="
if ! command -v codex >/dev/null 2>&1; then
  npm install -g @openai/codex >"$TMP/desktop-npm.log" 2>&1 \
    && pass "npm install -g @openai/codex" || fail "npm install failed"
fi
CODEX_VER="$(codex --version 2>&1 | head -n 1)"
[ -n "$CODEX_VER" ] && pass "codex $CODEX_VER" || fail "codex binary not found"
mkdir -p "$HOME/.codex"
cat > "$HOME/.codex/config.toml" <<'EOF'
model_provider = "m365hub"
model = "gpt-6.1-sol-reasoning"
[model_providers.m365hub]
name = "m365hub"
base_url = "http://127.0.0.1:8230/v1"
env_key = "M365HUB_API_KEY"
wire_api = "responses"
EOF
export M365HUB_API_KEY="$API_KEY"
P5_DIR="$TMP/codex-reasoning-test"
rm -rf "$P5_DIR"; mkdir -p "$P5_DIR"
cd "$P5_DIR" && git init -q 2>/dev/null || true
HELP="$(codex exec --help 2>&1 || true)"
APPROVE=""; echo "$HELP" | grep -q "dangerously-bypass-approvals-and-sandbox" && APPROVE="--dangerously-bypass-approvals-and-sandbox"
SKIP=""; echo "$HELP" | grep -q "skip-git-repo-check" && SKIP="--skip-git-repo-check"
START=$(date +%s)
if command -v timeout >/dev/null 2>&1; then
  timeout 420 codex exec $APPROVE $SKIP "Create a file named reasoning-model.txt in the current directory containing exactly one line: reasoning-model-ok. Do not write anything else into the file." < /dev/null > "$TMP/desktop-p5.log" 2>&1
else
  perl -e 'alarm shift; exec @ARGV' 420 codex exec $APPROVE $SKIP "Create a file named reasoning-model.txt in the current directory containing exactly one line: reasoning-model-ok. Do not write anything else into the file." < /dev/null > "$TMP/desktop-p5.log" 2>&1
fi
P5_RC=$?
ELAPSED=$(( $(date +%s) - START ))
echo "P5: codex exit $P5_RC in ${ELAPSED}s" | tee -a "$SUMMARY"
if [ -f "$P5_DIR/reasoning-model.txt" ] && [ "$(cat "$P5_DIR/reasoning-model.txt")" = "reasoning-model-ok" ]; then
  pass "P5: CLI with gpt-6.1-sol-reasoning created the file in ${ELAPSED}s"
else
  fail "P5: CLI with gpt-6.1-sol-reasoning did NOT create the file in ${ELAPSED}s"
  tail -n 20 "$TMP/desktop-p5.log" | tee -a "$SUMMARY"
fi

echo "== summary =="
cat "$SUMMARY"
if [ "$FAIL" = "0" ]; then echo "DESKTOP-FLOW-TEST: PASS"; exit 0
else echo "DESKTOP-FLOW-TEST: FAIL"; exit 1; fi
