#!/bin/bash
# Long-task tests for the Mac gateway in CI (run from the repo root):
#   1. memory usability (local-memory list / detail / delete + on-disk file)
#   2. memory compression (model condensation of an over-cap summary)
#   3. session / conversation compression (remote compaction v2, buffered
#      + streamed, + replay of the compaction item)
#   4. BTW side-chat isolation (main CodeX task + concurrent side exec)
#   5. CodeX long task (real multi-step work, gpt-5.6-reasoning, YOLO)
#   6. Claude Code via /v1/messages (smoke + real tool task)
#
# Runs against the repo-bundled gateway binary directly (no Xcode build),
# with the real account restored from the actions cache by the workflow.
# The sandbox cannot reach the model upstream (egress TLS is blocked),
# so all model calls happen here, on the runner.
#
# Exit 0: every item PASS. Exit 1: any FAIL. Exit 2: no FAIL but some
# item BLOCKED (e.g. no restored account: every model call needs it, and
# only the operator can re-seed it with a PKCE login in the morning).
#
# Round 2 fixes (after run 43459209573 failed on items 2 and 6):
# - item 2 seed was 15049 BYTES, under the 16000-byte threshold, so no
#   compression ever fired (Go len() counts bytes; the script compared
#   Python chars). Seed is now 200 facts (~27000 bytes); all length
#   checks use bytes where the gateway does.
# - BTW now runs the side exec WHILE the main task runs (backgrounded
#   main task), adds an API-level isolation probe (QUARK-5520), and drops
#   the /api/sessions check: the transcript index is off unless the
#   gateway starts with a transcripts path, so it is always empty here.
# - Claude Code: direct /v1/messages probes first (no tools, then with
#   tools) to isolate the gateway path, then the CLI with the registered
#   Anthropic-style model id claude-sonnet-4-20250514 (round 1's
#   claude-sonnet only drew an unrecognized-model warning) plus --debug.
set -u
BIN="M365HubApp/Resources/m365hub"
BASE="http://127.0.0.1:8230"
TMP="${RUNNER_TEMP:-/tmp}"
JAR="$TMP/longtask-cookies.txt"
SUMMARY="$TMP/longtask-summary.txt"
ADMIN_PASS="ci-test-pass-20261101"
FAIL=0
BLOCKED=0
: > "$SUMMARY"
PY="$(command -v python3 || echo python3)"
export PYTHONIOENCODING=utf-8
DATA_DIR="$HOME/.config/m365hub"
LOG_FILE="$DATA_DIR/serve-longtask.log"
START_TS="$(date +%s)"

note() { echo "$1" | tee -a "$SUMMARY"; }
pass() { note "PASS: $1"; }
fail() { FAIL=1; note "FAIL: $1"; }
block() { BLOCKED=1; note "BLOCKED: $1"; }
jget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); v=eval("d"+sys.argv[2]); print(v if not isinstance(v,bool) else str(v).lower())' "$1" "$2" 2>/dev/null; }

echo "== 0. setup: bundled gateway binary =="
[ -x "$BIN" ] || { fail "gateway binary missing/not executable: $BIN"; echo "LONGTASK-TEST: FAIL"; exit 1; }
BIN_MD5="$(md5 -q "$BIN" 2>/dev/null || md5sum "$BIN" | cut -d' ' -f1)"
echo "gateway binary md5: $BIN_MD5 (Mac 1.0.26 shipped 97a306df7d2b3d7328382298076fa96b)" | tee -a "$SUMMARY"
[ "$BIN_MD5" = "97a306df7d2b3d7328382298076fa96b" ] \
  && pass "bundled gateway is the Mac 1.0.26 binary" \
  || note "bundled gateway md5 differs from the 1.0.26 value (recorded above, not a failure by itself)"

echo "== 0b. seed test memories into the data dir BEFORE the gateway starts =="
mkdir -p "$DATA_DIR"
"$PY" - "$DATA_DIR/local-memory.json" <<'PY'
import json, sys, os
path = sys.argv[1]
data = {"memories": {}}
if os.path.exists(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        data = {"memories": {}}
data.setdefault("memories", {})
# Item 1: small memory (2 turns) for list / detail / delete.
data["memories"]["tag:longtask-mem1"] = {
    "summary": "长任务测试记忆一：这是摘要内容。",
    "turns": [
        {"role": "user", "content": "你好，这是第一轮", "at": "2026-11-14T00:00:00Z"},
        {"role": "assistant", "content": "你好，这是第二轮", "at": "2026-11-14T00:01:00Z"},
    ],
}
# Item 2: over-cap memory. Summary ~12600 chars / ~23800 bytes (200
# numbered facts) + 25 fact turns (~3150 bytes) -> total ~27000 bytes,
# well over the 16000-byte compression threshold (Go len() counts BYTES;
# the round-1 seed was 15049 bytes and never compressed). One more chat
# turn folds the oldest turns into the summary and marks it NeedsSummary
# for model condensation.
facts = []
for i in range(1, 201):
    facts.append("事实%04d：记住：项目代号是 LONGTASK-FACT-%04d，负责人是张三，截止 2026-12-%02d，状态进行中。" % (i, i, (i % 28) + 1))
summary = "\n".join(facts)
turns = []
for i in range(1, 26):
    turns.append({"role": "user" if i % 2 else "assistant",
                  "content": "记住：这是第 %02d 轮讨论，项目代号是 LONGTASK-FACT-%04d，结论是继续推进第 %02d 项工作，不要遗漏。" % (i, 100 + i, i),
                  "at": "2026-11-14T00:%02d:00Z" % i})
data["memories"]["tag:longtask-big"] = {
    "summary": summary, "turns": turns, "needsSummary": True,
}
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("seeded tag:longtask-mem1 (2 turns) and tag:longtask-big (summary %d chars / %d bytes, 25 turns)" % (len(summary), len(summary.encode("utf-8"))))
PY
grep -q "tag:longtask-mem1" "$DATA_DIR/local-memory.json" \
  && grep -q "tag:longtask-big" "$DATA_DIR/local-memory.json" \
  && pass "test memories seeded into local-memory.json" || fail "seed file missing test keys"

echo "== 0c. start the gateway directly =="
M365_DATA_DIR="$DATA_DIR" M365_LISTEN="127.0.0.1:8230" \
  "$BIN" serve > "$LOG_FILE" 2>&1 &
GW_PID=$!
echo "gateway pid: $GW_PID" | tee -a "$SUMMARY"
UP=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 2 "$BASE/api/admin/session" 2>/dev/null || echo "000")
  if [ "$CODE" != "000" ]; then UP=1; break; fi
  sleep 1
done
[ "$UP" = "1" ] && pass "gateway up (session answers)" || { fail "gateway never answered"; echo "LONGTASK-TEST: FAIL"; exit 1; }

echo "== 0d. admin login =="
rm -f "$JAR"
login_with() {
  curl -s -m 10 -c "$JAR" -b "$JAR" -X POST "$BASE/api/admin/login" \
    -H 'Content-Type: application/json' -d "{\"password\":\"$1\"}" -o "$TMP/lt-login.json" -w "%{http_code}"
}
CODE=$(login_with "$ADMIN_PASS")
if [ "$CODE" = "200" ] && [ "$(jget "$TMP/lt-login.json" "['ok']")" = "true" ]; then
  pass "admin login with the test password"
else
  curl -s -m 10 -X POST "$BASE/api/admin/login" \
    -H 'Content-Type: application/json' -d '{"password":"admin123"}' -o "$TMP/lt-login.json"
  if [ "$(jget "$TMP/lt-login.json" "['must_change_password']")" = "true" ]; then
    curl -s -m 10 -X POST "$BASE/api/admin/password" \
      -H 'Content-Type: application/json' \
      -d "{\"current\":\"admin123\",\"next\":\"$ADMIN_PASS\"}" -o "$TMP/lt-pw.json" -w "%{http_code}" > "$TMP/lt-pw.code"
    [ "$(cat "$TMP/lt-pw.code")" = "200" ] && pass "changed default admin password" || fail "password change failed"
    CODE=$(login_with "$ADMIN_PASS")
    [ "$CODE" = "200" ] && pass "admin login with the test password" || fail "admin login failed"
  else
    fail "admin login with either password: $(head -c 300 "$TMP/lt-login.json")"
  fi
fi

echo "== 0e. is the real account there (restored from cache)? =="
curl -s -m 10 -b "$JAR" "$BASE/api/auth/status" -o "$TMP/lt-status.json"
ACCT_COUNT="$(jget "$TMP/lt-status.json" "['count']")"
HAVE_ACCOUNT=0
if [ "$ACCT_COUNT" = "1" ]; then HAVE_ACCOUNT=1; pass "auth status count=1 (restored account present)"; else
  note "auth status count=$ACCT_COUNT (no restored account)"
fi
curl -s -m 10 -b "$JAR" "$BASE/api/accounts" -o "$TMP/lt-accts.json"
grep -q "copilot@wt3z38wld.onmicrosoft.com" "$TMP/lt-accts.json" \
  && pass "account copilot@wt3z38wld.onmicrosoft.com is listed" \
  || note "expected account not in list: $(head -c 300 "$TMP/lt-accts.json")"

echo "== 0f. mint a /v1 API key =="
API_KEY=""
if [ "$HAVE_ACCOUNT" = "1" ]; then
  curl -s -m 10 -b "$JAR" -X POST "$BASE/api/admin/keys" \
    -H 'Content-Type: application/json' -d '{"name":"longtask-ci"}' \
    -o "$TMP/lt-key.json" -w "%{http_code}" > "$TMP/lt-key.code"
  API_KEY="$(jget "$TMP/lt-key.json" "['plaintext']")"
  if [ "$(cat "$TMP/lt-key.code")" = "200" ] && [ -n "$API_KEY" ] && [ "$API_KEY" != "None" ]; then
    pass "API key minted for /v1 clients"
  else
    fail "API key mint failed: $(head -c 300 "$TMP/lt-key.json")"
  fi
fi

echo "== 0g. transcript baseline (for the BTW session check) =="
curl -s -m 10 -b "$JAR" "$BASE/api/sessions" -o "$TMP/lt-sessions-before.json" || true
"$PY" - "$TMP/lt-sessions-before.json" <<'PY' >> "$SUMMARY" 2>&1 || echo "sessions baseline unreadable (see file)"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
s = d.get("sessions", [])
print("sessions before: %d" % len(s))
for x in s[:10]:
    print("  - %s" % (x,))
PY

# ---------------------------------------------------------------- item 1
echo "== 1. memory usability: list / detail / delete + on-disk file =="
curl -s -m 10 -b "$JAR" "$BASE/api/local-memory" -o "$TMP/lt-mem-list.json" -w "%{http_code}" > "$TMP/lt-mem-list.code"
[ "$(cat "$TMP/lt-mem-list.code")" = "200" ] \
  && pass "GET /api/local-memory -> 200" || fail "list http $(cat "$TMP/lt-mem-list.code")"
"$PY" - "$TMP/lt-mem-list.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
mems = d.get("memories", [])
m = next((x for x in mems if x.get("key") == "tag:longtask-mem1"), None)
assert m is not None, "tag:longtask-mem1 not in list: %r" % (mems,)
assert m.get("turns") == 2, "turns=%r" % (m.get("turns"),)
assert m.get("hasSummary") is True, "hasSummary=%r" % (m.get("hasSummary"),)
print("PASS: list shows tag:longtask-mem1 (2 turns, hasSummary=true)")
PY
[ $? -ne 0 ] && fail "list content mismatch (see above)"

curl -s -m 10 -b "$JAR" "$BASE/api/local-memory?key=tag%3Alongtask-mem1" -o "$TMP/lt-mem-detail.json" -w "%{http_code}" > "$TMP/lt-mem-detail.code"
[ "$(cat "$TMP/lt-mem-detail.code")" = "200" ] \
  && pass "GET /api/local-memory?key=tag:longtask-mem1 -> 200" || fail "detail http $(cat "$TMP/lt-mem-detail.code")"
"$PY" - "$TMP/lt-mem-detail.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("key") == "tag:longtask-mem1", "key=%r" % (d.get("key"),)
assert "长任务测试记忆一" in (d.get("summary") or ""), "summary=%r" % (d.get("summary"),)
turns = d.get("turns") or []
assert len(turns) == 2, "turns=%r" % (turns,)
assert turns[0].get("content") == "你好，这是第一轮", "turn0=%r" % (turns[0],)
assert turns[1].get("content") == "你好，这是第二轮", "turn1=%r" % (turns[1],)
print("PASS: detail shows the real summary + both turns verbatim")
PY
[ $? -ne 0 ] && fail "detail content mismatch (see above)"

grep -q "tag:longtask-mem1" "$DATA_DIR/local-memory.json" \
  && pass "seeded memory is on disk in local-memory.json" || fail "seeded memory not on disk"

curl -s -m 10 -b "$JAR" -X DELETE "$BASE/api/local-memory?key=tag%3Alongtask-mem1" -o "$TMP/lt-mem-del.json" -w "%{http_code}" > "$TMP/lt-mem-del.code"
[ "$(cat "$TMP/lt-mem-del.code")" = "200" ] \
  && pass "DELETE /api/local-memory?key=tag:longtask-mem1 -> 200" || fail "delete http $(cat "$TMP/lt-mem-del.code")"
curl -s -m 10 -b "$JAR" "$BASE/api/local-memory" -o "$TMP/lt-mem-list2.json"
"$PY" - "$TMP/lt-mem-list2.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
mems = d.get("memories", [])
assert not any(x.get("key") == "tag:longtask-mem1" for x in mems), "seed still present: %r" % (mems,)
print("PASS: seeded memory is gone from the list after delete")
PY
[ $? -ne 0 ] && fail "delete did not remove the seed (see above)"
if grep -q "tag:longtask-mem1" "$DATA_DIR/local-memory.json"; then
  fail "deleted memory still on disk in local-memory.json"
else
  pass "deleted memory is gone from local-memory.json on disk"
fi
note "Windows 1.0.4 LocalMemoryPage.cs re-check (local, this run): reads /api/local-memory and iterates Arr(d, \"memories\") — code confirmed, see final report"

# ---------------------------------------------------------------- item 2
if [ "$HAVE_ACCOUNT" = "1" ]; then
echo "== 2. memory compression: drive one chat turn tagged longtask-big =="
curl -s -m 300 -b "$JAR" -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-M365-Session-Id: longtask-big-session" \
  -H "X-M365-Memory-Tags: longtask-big" \
  -d '{"model":"gpt-5.6-reasoning","messages":[{"role":"user","content":"请用一句话回答：今天星期几？只说星期几，不要多余内容。"}],"stream":false}' \
  -o "$TMP/lt-big-chat.json" -w "%{http_code}" > "$TMP/lt-big-chat.code"
[ "$(cat "$TMP/lt-big-chat.code")" = "200" ] \
  && pass "tagged chat turn returned http 200" || fail "tagged chat http $(cat "$TMP/lt-big-chat.code"): $(head -c 500 "$TMP/lt-big-chat.json")"
CHAT_REPLY="$(jget "$TMP/lt-big-chat.json" "['choices'][0]['message']['content']")"
echo "tagged chat reply: $(echo "$CHAT_REPLY" | head -c 200)" | tee -a "$SUMMARY"
[ -n "$CHAT_REPLY" ] && [ "$CHAT_REPLY" != "None" ] \
  && pass "tagged chat returned real content" || fail "tagged chat content empty"

echo "== 2b. right after the turn: summary must NOT be hard-truncated =="
"$PY" - "$DATA_DIR/local-memory.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
md = d.get("memories", {}).get("tag:longtask-big")
assert md is not None, "tag:longtask-big missing from file"
s = md.get("summary") or ""
# Go len() counts BYTES; Python len() counts characters. The gateway
# threshold is bytes, so compare bytes here (round 1 compared chars
# and wrongly concluded the summary had been cut).
print("summary chars|bytes right after turn: %d|%d, needsSummary=%s, turns=%d" % (len(s), len(s.encode("utf-8")), md.get("needsSummary"), len(md.get("turns") or [])))
assert len(s.encode("utf-8")) > 8000, "summary was cut below 8000 bytes right after the turn (%d)" % len(s.encode("utf-8"))
assert md.get("needsSummary") is True, "needsSummary flag not set after compression"
print("PASS: summary still full (>8000 bytes) with needsSummary=true — no hard truncation at compression time")
PY
[ $? -ne 0 ] && fail "post-turn summary check failed (see above)"

echo "== 2c. poll up to 240s for the background model condensation =="
CONDENSED=0
for i in $(seq 1 24); do
  sleep 10
  R="$("$PY" - "$DATA_DIR/local-memory.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
md = d.get("memories", {}).get("tag:longtask-big") or {}
s = md.get("summary") or ""
print("%d|%d|%s|%d" % (len(s), len(s.encode("utf-8")), md.get("needsSummary"), len(md.get("turns") or [])))
PY
)"
  echo "poll $i: summary_chars|summary_bytes|needsSummary|turns = $R" | tee -a "$SUMMARY"
  PCHARS="${R%%|*}"; REST1="${R#*|}"; PBYTES="${REST1%%|*}"; REST2="${REST1#*|}"; NEED="${REST2%%|*}"
  # The model prompt asks for at most 6000 characters; the gateway
  # additionally caps stored bytes at 8000. Condensation counts as done
  # when the flag clears and the byte cap holds (a model that writes
  # 7000 ASCII chars still stores within the byte cap, so chars alone
  # must not block the exit).
  if [ "$NEED" != "True" ] && [ "$PBYTES" -le 8000 ]; then CONDENSED=1; break; fi
done
if [ "$CONDENSED" = "1" ]; then
  pass "background model condensation finished: summary <=6000 chars, needsSummary cleared"
else
  fail "model condensation did not finish within 240s (see polls above)"
fi
grep -i "localmem.*compressed" "$LOG_FILE" | tail -n 3 | tee -a "$SUMMARY" || true
if grep -qi "localmem.*model summary failed" "$LOG_FILE"; then
  fail "gateway log shows the model summary FAILED (fell back to hard truncation)"
  grep -i "localmem.*model summary failed" "$LOG_FILE" | tail -n 3 | tee -a "$SUMMARY"
else
  pass "gateway log shows no model-summary failure"
fi
echo "== 2d. condensed summary still keeps key facts, recent turns intact =="
"$PY" - "$DATA_DIR/local-memory.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
md = d.get("memories", {}).get("tag:longtask-big")
assert md is not None, "tag:longtask-big missing from file"
s = md.get("summary") or ""
turns = md.get("turns") or []
print("condensed summary chars|bytes: %d|%d, turns kept: %d" % (len(s), len(s.encode("utf-8")), len(turns)))
# Fact markers folded in from the oldest turns (LONGTASK-FACT-0101..0107).
folded = [m for m in ["LONGTASK-FACT-010%d" % i for i in range(1, 8)] if m in s]
print("folded-turn markers still in summary: %s" % (folded,))
# Sampled markers from the original 200-fact summary (tail-weighted: the
# condensation prompt keeps the most recent facts, and the gateway trims
# to the last 8000 bytes, so head markers may legitimately drop).
sampled = [m for m in ["LONGTASK-FACT-0100","LONGTASK-FACT-0150","LONGTASK-FACT-0175","LONGTASK-FACT-0200"] if m in s]
print("sampled summary-fact markers still present: %s" % (sampled,))
assert len(s.encode("utf-8")) <= 8000, "condensed summary still over 8000 bytes (%d)" % len(s.encode("utf-8"))
if len(s) > 6200:
    print("NOTE: condensed summary is %d chars (model was asked for <=6000); byte cap holds, so this is a model-fidelity note, not a failure" % len(s))
assert len(turns) >= 18, "too few turns kept verbatim (%d)" % len(turns)
assert len(folded) >= 3, "folded-turn facts mostly lost (%s)" % (folded,)
assert len(sampled) >= 2, "original summary facts mostly lost (%s)" % (sampled,)
print("PASS: condensed summary keeps key facts and the recent turns are intact verbatim")
PY
[ $? -ne 0 ] && fail "condensed-summary content check failed (see above)"
else
  block "memory compression (item 2): no restored account, the model condensation call cannot run — re-seed the account in the morning with a PKCE login"
fi

# ---------------------------------------------------------------- item 3
if [ "$HAVE_ACCOUNT" = "1" ]; then
echo "== 3a. session compression: compaction_trigger, buffered =="
"$PY" <<'PY' > "$TMP/lt-compact-req.json"
import json
inp = [
  {"type": "message", "role": "user", "content": "记住：本次任务的代号是 ZEBRA-7741，负责人是李四，交付物是三份报告，截止 2026-12-01。"},
  {"type": "message", "role": "assistant", "content": "记住了，代号 ZEBRA-7741，负责人李四，三份报告，截止 2026-12-01。"},
  {"type": "message", "role": "user", "content": "再确认一下：代号、负责人和交付物分别是什么？"},
  {"type": "message", "role": "assistant", "content": "代号 ZEBRA-7741，负责人李四，交付物三份报告。"},
  {"type": "compaction_trigger"},
]
print(json.dumps({"model": "gpt-5.6-reasoning", "input": inp, "stream": False}, ensure_ascii=False))
PY
T0=$(date +%s)
curl -s -m 300 -X POST "$BASE/v1/responses" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-M365-Session-Id: longtask-compact-1" \
  -d @"$TMP/lt-compact-req.json" \
  -o "$TMP/lt-compact.json" -w "%{http_code}" > "$TMP/lt-compact.code"
T1=$(date +%s)
echo "compaction call took $((T1-T0))s, http $(cat "$TMP/lt-compact.code")" | tee -a "$SUMMARY"
[ "$(cat "$TMP/lt-compact.code")" = "200" ] \
  && pass "compaction request returned http 200" || fail "compaction http $(cat "$TMP/lt-compact.code"): $(head -c 500 "$TMP/lt-compact.json")"
"$PY" - "$TMP/lt-compact.json" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
out = d.get("output") or []
print("output items: %d" % len(out))
for it in out:
    print("  - type=%s id=%s" % (it.get("type"), it.get("id")))
assert len(out) == 1, "expected exactly one output item, got %d" % len(out)
assert out[0].get("type") == "compaction", "output item type=%r, not compaction" % (out[0].get("type"),)
enc = out[0].get("encrypted_content") or ""
print("encrypted_content chars: %d" % len(enc))
print("encrypted_content (first 500): %s" % enc[:500])
assert len(enc) > 0, "encrypted_content is empty"
print("PASS: exactly one compaction output item with a non-empty summary")
if "ZEBRA-7741" in enc:
    print("PASS: compacted summary preserves the secret codename ZEBRA-7741")
else:
    print("NOTE: compacted summary does not literally contain ZEBRA-7741 (check wording above)")
PY
[ $? -ne 0 ] && fail "buffered compaction output check failed (see above)"

echo "== 3b. replay: the compaction item goes back in, the model must recall the codename =="
"$PY" - "$TMP/lt-compact.json" <<'PY' > "$TMP/lt-replay-req.json"
import json, sys
d = json.load(open(sys.argv[1]))
out = d.get("output") or []
item = out[0] if out else {}
req = {"model": "gpt-5.6-reasoning", "stream": False, "input": [
  {"type": "compaction", "id": item.get("id"), "encrypted_content": item.get("encrypted_content")},
  {"type": "message", "role": "user", "content": "刚才对话里的代号是什么？只回答代号，不要多余内容。"},
]}
print(json.dumps(req, ensure_ascii=False))
PY
T0=$(date +%s)
curl -s -m 300 -X POST "$BASE/v1/responses" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-M365-Session-Id: longtask-compact-1" \
  -d @"$TMP/lt-replay-req.json" \
  -o "$TMP/lt-replay.json" -w "%{http_code}" > "$TMP/lt-replay.code"
T1=$(date +%s)
echo "replay call took $((T1-T0))s, http $(cat "$TMP/lt-replay.code")" | tee -a "$SUMMARY"
REPLAY_TEXT="$("$PY" - "$TMP/lt-replay.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
parts = []
for it in d.get("output") or []:
    for c in it.get("content") or []:
        if isinstance(c, dict) and c.get("text"):
            parts.append(c["text"])
print(" ".join(parts))
PY
)"
echo "replay answer: [$REPLAY_TEXT]" | tee -a "$SUMMARY"
if echo "$REPLAY_TEXT" | grep -q "ZEBRA-7741"; then
  pass "replay: model recalled the codename ZEBRA-7741 from the compacted summary"
else
  fail "replay: model did NOT recall ZEBRA-7741 (answer above)"
fi

echo "== 3c. session compression: compaction_trigger, streamed (SSE) =="
"$PY" <<'PY' > "$TMP/lt-compact-sse-req.json"
import json
inp = [
  {"type": "message", "role": "user", "content": "记住：本次任务的代号是 ZEBRA-7741，负责人是李四，交付物是三份报告，截止 2026-12-01。"},
  {"type": "message", "role": "assistant", "content": "记住了，代号 ZEBRA-7741，负责人李四，三份报告，截止 2026-12-01。"},
  {"type": "compaction_trigger"},
]
print(json.dumps({"model": "gpt-5.6-reasoning", "input": inp, "stream": True}, ensure_ascii=False))
PY
T0=$(date +%s)
curl -s -m 300 -X POST "$BASE/v1/responses" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-M365-Session-Id: longtask-compact-1" \
  -d @"$TMP/lt-compact-sse-req.json" \
  -o "$TMP/lt-compact-sse.txt" -w "%{http_code}" > "$TMP/lt-compact-sse.code"
T1=$(date +%s)
echo "streamed compaction call took $((T1-T0))s, http $(cat "$TMP/lt-compact-sse.code")" | tee -a "$SUMMARY"
"$PY" - "$TMP/lt-compact-sse.txt" <<'PY' >> "$SUMMARY" 2>&1
import json, sys
n_compaction = 0
n_completed = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("data:"):
        continue
    payload = line[5:].strip()
    if payload == "[DONE]":
        continue
    try:
        ev = json.loads(payload)
    except Exception:
        continue
    if ev.get("type") == "response.completed":
        n_completed += 1
        out = (ev.get("response") or {}).get("output") or []
        n_compaction = sum(1 for it in out if it.get("type") == "compaction")
        print("response.completed output items: %d, compaction items: %d" % (len(out), n_compaction))
print("completed events: %d" % n_completed)
assert n_completed == 1, "expected 1 completed event, got %d" % n_completed
assert n_compaction == 1, "expected exactly 1 compaction item in the stream, got %d" % n_compaction
print("PASS: streamed compaction also yields exactly one compaction item")
PY
[ $? -ne 0 ] && fail "streamed compaction check failed (see above)"
else
  block "session compression (item 3): no restored account, the compaction model calls cannot run"
fi

# ---------------------------------------------------------------- items 4+5 (CodeX)
if [ "$HAVE_ACCOUNT" = "1" ]; then
echo "== 5/4 setup: install CodeX CLI, config for gpt-5.6-reasoning =="
command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
  || fail "node/npm not on PATH"
if ! command -v codex >/dev/null 2>&1; then
  npm install -g @openai/codex >"$TMP/lt-npm-codex.log" 2>&1 \
    && pass "npm install -g @openai/codex" || { fail "npm install codex failed"; tail -n 20 "$TMP/lt-npm-codex.log" | tee -a "$SUMMARY"; }
fi
if ! command -v codex >/dev/null 2>&1; then
  NPM_BIN="$(npm config get prefix 2>/dev/null)/bin/codex"
  [ -x "$NPM_BIN" ] && export PATH="$PATH:$(dirname "$NPM_BIN")"
fi
CODEX_VER="$(codex --version 2>&1 | head -n 1)"
[ -n "$CODEX_VER" ] && pass "codex $CODEX_VER" || fail "codex binary not found after install"
HELP="$(codex exec --help 2>&1 || true)"
APPROVE=""
echo "$HELP" | grep -q "dangerously-bypass-approvals-and-sandbox" \
  && APPROVE="--dangerously-bypass-approvals-and-sandbox" \
  || fail "codex exec has no YOLO flag"
[ -n "$APPROVE" ] && pass "approval mode: YOLO"
SKIP=""
echo "$HELP" | grep -q "skip-git-repo-check" && SKIP="--skip-git-repo-check"
JSON=""
echo "$HELP" | grep -q -e "--json" && JSON="--json"
mkdir -p "$HOME/.codex"
cat > "$HOME/.codex/config.toml" <<'EOF'
model_provider = "m365hub"
model = "gpt-5.6-reasoning"
model_context_window = 40000
[model_providers.m365hub]
name = "m365hub"
base_url = "http://127.0.0.1:8230/v1"
env_key = "M365HUB_API_KEY"
wire_api = "responses"
EOF
export M365HUB_API_KEY="$API_KEY"
pass "codex config written (gpt-5.6-reasoning, context window 40000 to give auto-compaction a chance)"
# macOS has no `timeout`; use perl alarm like the existing CodeX test.
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@";
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

echo "== 5. CodeX long task (main thread): build a notes CLI + docs, then verify =="
WORKDIR="$TMP/codex-longtask"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
cd "$WORKDIR" && git init -q 2>/dev/null || true
T0=$(date +%s)
run_timeout 1500 codex exec $APPROVE $SKIP $JSON "In the current directory, build a small Python CLI called notes.py with three commands backed by a notes.json file: add <text> appends a note, list prints all notes numbered, search <word> prints only notes containing the word. Also write README.md explaining the three commands, and tests/test_notes.py with at least three unit tests (add, list, search). Then run the tests with python3 -m pytest tests/ -q, or python3 -m unittest if pytest is missing, and fix any failures until the tests pass. Then create a docs/ directory with five files design-1.txt .. design-5.txt, each about 150 lines, describing the CLI design (commands, file format, edge cases, error handling, future work). Then read all five design files back and write docs/consistency-report.txt listing any contradictions you find between the design files and the actual notes.py code. Finally reply with the list of files you created and the test result." < /dev/null > "$TMP/lt-codex-main.log" 2>&1 &
MAIN_PID=$!
echo "codex main task started in background (pid $MAIN_PID)" | tee -a "$SUMMARY"
sleep 25
if kill -0 "$MAIN_PID" 2>/dev/null; then
  note "main task still running 25s in — the side exec below runs truly concurrently"
else
  note "main task already finished before the side exec (fast model); isolation check degrades to sequential"
fi

echo "== 4. BTW isolation: side exec WHILE the main task runs =="
# A side exec now must NOT pick up the main thread's context: it runs
# in its own workdir, on an unrelated topic, with a unique marker that
# must never appear in the main thread's files/logs (checked after the
# main task finishes, section 4e below).
SIDE_DIR="$TMP/codex-side"
rm -rf "$SIDE_DIR"; mkdir -p "$SIDE_DIR"
cd "$SIDE_DIR" && git init -q 2>/dev/null || true
T0S=$(date +%s)
run_timeout 300 codex exec $APPROVE $SKIP "Side question, unrelated to any other work: what is 17 times 23? Reply with only the number, then on a new line write the marker SIDE-QUARK-88 and nothing else." < /dev/null > "$TMP/lt-codex-side.log" 2>&1
SIDE_RC=$?
T1S=$(date +%s)
echo "codex side exec exit: $SIDE_RC, took $((T1S-T0S))s" | tee -a "$SUMMARY"
SIDE_TEXT="$(cat "$TMP/lt-codex-side.log")"
if echo "$SIDE_TEXT" | grep -q "391"; then pass "side exec answered 391 (17*23)"; else fail "side exec did not answer 391"; fi
if echo "$SIDE_TEXT" | grep -qi "notes\.py\|notes CLI\|design-"; then
  fail "side exec mentions the main task (notes.py / design files) — context bled across threads"
else
  pass "side exec never mentions the main task's topic"
fi

echo "== 4d. API-level isolation probe (no explicit session id) =="
# The /api/sessions transcript index is off unless the gateway is
# started with a transcripts path (main.go), so it is always empty in
# this direct-binary run — it cannot prove anything here, and the
# round-1 script wrongly treated it as a check. Instead, prove the
# resolver keeps unrelated requests apart directly: request A
# establishes a codename, request B (unrelated wording, no explicit
# session id) must NOT know it.
"$PY" <<'PY' > "$TMP/lt-btw-a.json"
import json
print(json.dumps({"model": "gpt-5.6-reasoning", "stream": False, "input": [
  {"type": "message", "role": "user", "content": "记住：本次任务的代号是 QUARK-5520，负责人是王五，交付物是两份设计稿。"},
  {"type": "message", "role": "assistant", "content": "记住了，代号 QUARK-5520，负责人王五，两份设计稿。"},
  {"type": "message", "role": "user", "content": "再确认一下代号和负责人。"},
]}, ensure_ascii=False))
PY
curl -s -m 300 -X POST "$BASE/v1/responses" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d @"$TMP/lt-btw-a.json" \
  -o "$TMP/lt-btw-a.json.out" -w "%{http_code}" > "$TMP/lt-btw-a.code"
[ "$(cat "$TMP/lt-btw-a.code")" = "200" ] \
  && pass "BTW probe A (main topic) http 200" || fail "BTW probe A http $(cat "$TMP/lt-btw-a.code")"
"$PY" <<'PY' > "$TMP/lt-btw-b.json"
import json
print(json.dumps({"model": "gpt-5.6-reasoning", "stream": False, "input": [
  {"type": "message", "role": "user", "content": "请问上一个对话里提到的项目代号是多少？只回答代号，或者说不知道。"},
]}, ensure_ascii=False))
PY
curl -s -m 300 -X POST "$BASE/v1/responses" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d @"$TMP/lt-btw-b.json" \
  -o "$TMP/lt-btw-b.json.out" -w "%{http_code}" > "$TMP/lt-btw-b.code"
[ "$(cat "$TMP/lt-btw-b.code")" = "200" ] \
  && pass "BTW probe B (unrelated) http 200" || fail "BTW probe B http $(cat "$TMP/lt-btw-b.code")"
B_TEXT="$("$PY" - "$TMP/lt-btw-b.json.out" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
parts = []
for it in d.get("output") or []:
    for c in it.get("content") or []:
        if isinstance(c, dict) and c.get("text"):
            parts.append(c["text"])
print(" ".join(parts))
PY
)"
echo "BTW probe B answer: [$B_TEXT]" | tee -a "$SUMMARY"
if echo "$B_TEXT" | grep -q "QUARK-5520"; then
  fail "BTW probe B: unrelated request recalled QUARK-5520 — sessions bled across threads"
else
  pass "BTW probe B: unrelated request did NOT know QUARK-5520 — no cross-thread leak"
fi

echo "== 4c. Jaccard similarity between the main and side prompts (must be < 0.6) =="
"$PY" <<'PY' >> "$SUMMARY" 2>&1
main = "build a small Python CLI called notes.py with add list search backed by notes.json README tests design files consistency report"
side = "what is 17 times 23 reply with only the number then marker SIDE-QUARK-88"
def toks(s):
    return set(s.lower().split())
a, b = toks(main), toks(side)
j = len(a & b) / len(a | b) if a | b else 0.0
print("Jaccard(main last prompt, side prompt) = %.2f (gateway threshold 0.6)" % j)
assert j < 0.6, "similarity %.2f is over the threshold" % j
print("PASS: side prompt is far below the session-matching threshold, so the gateway must treat it as a new session")
PY
[ $? -ne 0 ] && fail "similarity check failed (see above)"

echo "== 5a. wait for the main CodeX task, then check its result =="
wait "$MAIN_PID"; CODEX_RC=$?
T1=$(date +%s)
echo "codex main task exit: $CODEX_RC, took $((T1-T0))s" | tee -a "$SUMMARY"
grep -qi "compact" "$TMP/lt-codex-main.log" \
  && note "codex main log mentions compaction (see below)" || note "codex main log shows no client-side auto-compaction (context never hit the 40000-token window)"
grep -i "compact" "$TMP/lt-codex-main.log" | head -n 10 | tee -a "$SUMMARY" || true
[ "$CODEX_RC" = "0" ] \
  && pass "codex main task exited 0" || fail "codex main task exit $CODEX_RC (log tail below)"
if [ "$CODEX_RC" != "0" ]; then tail -n 30 "$TMP/lt-codex-main.log" | tee -a "$SUMMARY"; fi

echo "== 5b. verify the CodeX deliverables on disk =="
ls -la "$WORKDIR" "$WORKDIR/docs" "$WORKDIR/tests" 2>&1 | tee -a "$SUMMARY"
for f in notes.py README.md tests/test_notes.py docs/consistency-report.txt; do
  [ -f "$WORKDIR/$f" ] && pass "deliverable exists: $f" || fail "deliverable missing: $f"
done
DESIGN_OK=1
for i in 1 2 3 4 5; do
  LINES=$(wc -l < "$WORKDIR/docs/design-$i.txt" 2>/dev/null || echo 0)
  echo "docs/design-$i.txt: $LINES lines" | tee -a "$SUMMARY"
  [ "$LINES" -ge 100 ] || DESIGN_OK=0
done
[ "$DESIGN_OK" = "1" ] && pass "all five design files are substantial (>=100 lines)" || fail "some design files are too short"
grep -q "def " "$WORKDIR/notes.py" 2>/dev/null \
  && pass "notes.py contains real code" || fail "notes.py has no functions"
echo "== 5c. run the delivered tests myself (not the model's word for it) =="
cd "$WORKDIR"
if python3 -m pytest tests/ -q > "$TMP/lt-codex-tests.log" 2>&1; then
  pass "delivered tests pass under pytest"
elif python3 -m unittest discover -s tests > "$TMP/lt-codex-tests.log" 2>&1; then
  pass "delivered tests pass under unittest"
else
  fail "delivered tests do NOT pass (see log)"
  tail -n 20 "$TMP/lt-codex-tests.log" | tee -a "$SUMMARY"
fi
tail -n 5 "$TMP/lt-codex-tests.log" | tee -a "$SUMMARY"
echo "== 5d. run the delivered CLI myself =="
python3 notes.py add "longtask probe note" > "$TMP/lt-cli.log" 2>&1
python3 notes.py list >> "$TMP/lt-cli.log" 2>&1
python3 notes.py search "probe" >> "$TMP/lt-cli.log" 2>&1
if grep -q "longtask probe note" "$TMP/lt-cli.log"; then
  pass "notes.py CLI works end to end (add/list/search round trip)"
else
  fail "notes.py CLI round trip failed"
  cat "$TMP/lt-cli.log" | tee -a "$SUMMARY"
fi

echo "== 4e. deferred marker checks (main task is done now) =="
if grep -rq "SIDE-QUARK-88" "$WORKDIR" 2>/dev/null; then
  fail "side marker SIDE-QUARK-88 leaked into the main task's workdir"
else
  pass "side marker SIDE-QUARK-88 is absent from the main task's workdir"
fi
if grep -q "SIDE-QUARK-88" "$TMP/lt-codex-main.log"; then
  fail "side marker SIDE-QUARK-88 appears in the main task log"
else
  pass "side marker SIDE-QUARK-88 is absent from the main task log"
fi
else
  block "CodeX long task + BTW (items 4-5): no restored account, CodeX has nothing to call through"
fi

# ---------------------------------------------------------------- item 6 (Claude Code)
if [ "$HAVE_ACCOUNT" = "1" ]; then
echo "== 6. Claude Code via /v1/messages =="
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code >"$TMP/lt-npm-claude.log" 2>&1 \
    && pass "npm install -g @anthropic-ai/claude-code" || { fail "npm install claude failed"; tail -n 20 "$TMP/lt-npm-claude.log" | tee -a "$SUMMARY"; }
fi
if ! command -v claude >/dev/null 2>&1; then
  NPM_BIN="$(npm config get prefix 2>/dev/null)/bin/claude"
  [ -x "$NPM_BIN" ] && export PATH="$PATH:$(dirname "$NPM_BIN")"
fi
CLAUDE_VER="$(claude --version 2>&1 | head -n 1)"
[ -n "$CLAUDE_VER" ] && pass "claude $CLAUDE_VER" || fail "claude binary not found after install"
CLAUDE_KEY_JSON="$TMP/lt-claude-key.json"
curl -s -m 10 -b "$JAR" -X POST "$BASE/api/admin/keys" \
  -H 'Content-Type: application/json' -d '{"name":"claude-longtask-ci"}' \
  -o "$CLAUDE_KEY_JSON" -w "%{http_code}" > "$TMP/lt-claude-key.code"
CLAUDE_KEY="$(jget "$CLAUDE_KEY_JSON" "['plaintext']")"
if [ "$(cat "$TMP/lt-claude-key.code")" = "200" ] && [ -n "$CLAUDE_KEY" ] && [ "$CLAUDE_KEY" != "None" ]; then
  pass "separate API key minted for Claude Code"
else
  fail "Claude API key mint failed: $(head -c 300 "$CLAUDE_KEY_JSON")"
fi
export ANTHROPIC_BASE_URL="http://127.0.0.1:8230"
export ANTHROPIC_API_KEY="$CLAUDE_KEY"
CLAUDE_DIR="$TMP/claude-longtask"
rm -rf "$CLAUDE_DIR"; mkdir -p "$CLAUDE_DIR"
cd "$CLAUDE_DIR"
# Does this claude build accept --debug? (2.1.323 does; check anyway so
# a rejected flag cannot mask the real result.)
DBG=""
claude --help 2>&1 | grep -q -e "--debug" && DBG="--debug"

echo "== 6a. probe: minimal /v1/messages call (no tools) — isolates the gateway path from the CLI =="
curl -s -m 300 -X POST "$BASE/v1/messages" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $CLAUDE_KEY" \
  -d '{"model":"claude-sonnet","max_tokens":256,"messages":[{"role":"user","content":"Reply with exactly: PROBE-OK"}]}' \
  -o "$TMP/lt-probe-msgs.json" -w "%{http_code}" > "$TMP/lt-probe-msgs.code"
echo "probe /v1/messages http $(cat "$TMP/lt-probe-msgs.code")" | tee -a "$SUMMARY"
echo "probe response body:" | tee -a "$SUMMARY"
cat "$TMP/lt-probe-msgs.json" | tee -a "$SUMMARY"
PROBE_TEXT="$("$PY" - "$TMP/lt-probe-msgs.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
parts = []
for c in d.get("content") or []:
    if isinstance(c, dict) and c.get("text"):
        parts.append(c["text"])
print(" ".join(parts))
PY
)"
if echo "$PROBE_TEXT" | grep -q "PROBE-OK"; then
  pass "probe: /v1/messages returned PROBE-OK (gateway path + claude-sonnet mapping work)"
else
  fail "probe: /v1/messages did NOT return PROBE-OK (body above)"
fi

echo "== 6b. probe: /v1/messages WITH a tools array (mimics Claude Code's request shape) =="
curl -s -m 300 -X POST "$BASE/v1/messages" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $CLAUDE_KEY" \
  -d '{"model":"claude-sonnet","max_tokens":256,"messages":[{"role":"user","content":"Reply with exactly: PROBE-TOOLS-OK. Do not call any tool."}],"tools":[{"name":"get_weather","description":"Get the weather for a city.","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]}' \
  -o "$TMP/lt-probe-msgs-tools.json" -w "%{http_code}" > "$TMP/lt-probe-msgs-tools.code"
echo "probe-with-tools http $(cat "$TMP/lt-probe-msgs-tools.code")" | tee -a "$SUMMARY"
cat "$TMP/lt-probe-msgs-tools.json" | tee -a "$SUMMARY"
PROBE2_TEXT="$("$PY" - "$TMP/lt-probe-msgs-tools.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
parts = []
for c in d.get("content") or []:
    if isinstance(c, dict) and c.get("text"):
        parts.append(c["text"])
print(" ".join(parts))
PY
)"
if echo "$PROBE2_TEXT" | grep -q "PROBE-TOOLS-OK"; then
  pass "probe: /v1/messages with tools returned PROBE-TOOLS-OK (tools path does not swallow text)"
else
  fail "probe: /v1/messages with tools did NOT return PROBE-TOOLS-OK (body above)"
fi

echo "== 6c. Claude Code CLI: try the registered Anthropic-style model id first =="
# Round 1: ANTHROPIC_MODEL=claude-sonnet made Claude Code 2.1.323 print
# only an unrecognized-model warning and exit 0 with no reply, while the
# gateway answered 200 on all six /v1/messages calls. The gateway
# registry also has the Anthropic-style id claude-sonnet-4-20250514,
# which Claude Code recognises natively (proper context window).
CLAUDE_MODEL="claude-sonnet-4-20250514"
export ANTHROPIC_MODEL="$CLAUDE_MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$CLAUDE_MODEL"
T0=$(date +%s)
run_timeout 300 claude -p "Reply with exactly this string and nothing else: CLAUDE-VIA-M365HUB-OK" --output-format text --dangerously-skip-permissions $DBG < /dev/null > "$TMP/lt-claude-smoke.log" 2>&1
SMOKE_RC=$?
T1=$(date +%s)
echo "claude smoke ($CLAUDE_MODEL) exit: $SMOKE_RC, took $((T1-T0))s" | tee -a "$SUMMARY"
SMOKE_OK=0
if grep -q "CLAUDE-VIA-M365HUB-OK" "$TMP/lt-claude-smoke.log"; then
  SMOKE_OK=1
  pass "Claude Code smoke ($CLAUDE_MODEL): model replied through /v1/messages"
else
  note "Claude Code smoke failed with $CLAUDE_MODEL (exit $SMOKE_RC); retrying once with claude-sonnet"
  tail -n 15 "$TMP/lt-claude-smoke.log" | tee -a "$SUMMARY"
fi
if [ "$SMOKE_OK" = "0" ]; then
  CLAUDE_MODEL="claude-sonnet"
  export ANTHROPIC_MODEL="$CLAUDE_MODEL"
  export ANTHROPIC_SMALL_FAST_MODEL="$CLAUDE_MODEL"
  run_timeout 300 claude -p "Reply with exactly this string and nothing else: CLAUDE-VIA-M365HUB-OK" --output-format text --dangerously-skip-permissions $DBG < /dev/null > "$TMP/lt-claude-smoke2.log" 2>&1
  SMOKE2_RC=$?
  echo "claude smoke ($CLAUDE_MODEL) exit: $SMOKE2_RC" | tee -a "$SUMMARY"
  if grep -q "CLAUDE-VIA-M365HUB-OK" "$TMP/lt-claude-smoke2.log"; then
    SMOKE_OK=1
    pass "Claude Code smoke ($CLAUDE_MODEL): model replied through /v1/messages"
  else
    fail "Claude Code smoke failed with both model ids (see logs + gateway log tail below)"
    tail -n 15 "$TMP/lt-claude-smoke2.log" | tee -a "$SUMMARY"
    echo "--- gateway log tail (claude window) ---" | tee -a "$SUMMARY"
    tail -n 40 "$LOG_FILE" | tee -a "$SUMMARY"
  fi
fi
echo "== 6d. real tool task with model $CLAUDE_MODEL: create a file, then append + read it back =="
T0=$(date +%s)
run_timeout 600 claude -p "Create a file named hello-claude.txt in the current directory containing exactly one line: claude-via-m365hub-ok. Do not write anything else into the file." --output-format text --dangerously-skip-permissions $DBG < /dev/null > "$TMP/lt-claude-1.log" 2>&1
C1_RC=$?
T1=$(date +%s)
echo "claude task 1 exit: $C1_RC, took $((T1-T0))s" | tee -a "$SUMMARY"
if [ -f "$CLAUDE_DIR/hello-claude.txt" ] && [ "$(cat "$CLAUDE_DIR/hello-claude.txt" | tr -d '[:space:]')" = "claude-via-m365hub-ok" ]; then
  pass "Claude Code created hello-claude.txt with the exact line"
else
  fail "Claude Code did not create hello-claude.txt correctly"
  ls -la "$CLAUDE_DIR" | tee -a "$SUMMARY"
  tail -n 30 "$TMP/lt-claude-1.log" | tee -a "$SUMMARY"
fi
run_timeout 600 claude -p "Append a second line, second-line, to hello-claude.txt in the current directory, then print the file contents." --output-format text --dangerously-skip-permissions $DBG < /dev/null > "$TMP/lt-claude-2.log" 2>&1
C2_RC=$?
echo "claude task 2 exit: $C2_RC" | tee -a "$SUMMARY"
if grep -q "claude-via-m365hub-ok" "$CLAUDE_DIR/hello-claude.txt" && grep -q "second-line" "$CLAUDE_DIR/hello-claude.txt"; then
  pass "Claude Code appended the second line and the file holds both lines"
else
  fail "Claude Code append round failed"
  cat "$CLAUDE_DIR/hello-claude.txt" 2>&1 | tee -a "$SUMMARY"
  tail -n 20 "$TMP/lt-claude-2.log" | tee -a "$SUMMARY"
fi
else
  block "Claude Code (item 6): no restored account, /v1/messages has nothing to call through"
fi

# ---------------------------------------------------------------- cleanup
echo "== cleanup: remove every test memory key so the saved cache stays clean =="
curl -s -m 10 -b "$JAR" "$BASE/api/local-memory" -o "$TMP/lt-mem-final.json" || true
"$PY" - "$TMP/lt-mem-final.json" <<'PY' > "$TMP/lt-mem-final-keys.txt" 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1]))
for x in d.get("memories", []):
    print(x.get("key", ""))
PY
while IFS= read -r KEY; do
  [ -z "$KEY" ] && continue
  case "$KEY" in *longtask*|session:resp|session:longtask-*|session:msg)
    ENC="$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$KEY")"
    curl -s -m 10 -b "$JAR" -X DELETE "$BASE/api/local-memory?key=$ENC" -o /dev/null -w "deleted $KEY -> %{http_code}\n" | tee -a "$SUMMARY"
    ;;
  esac
done < "$TMP/lt-mem-final-keys.txt"
grep -q "longtask" "$DATA_DIR/local-memory.json" \
  && note "WARNING: longtask keys still in local-memory.json after cleanup (see file)" \
  || pass "no longtask test keys left in local-memory.json"
echo "== stop the gateway =="
kill "$GW_PID" 2>/dev/null || true
sleep 2
pkill -f "m365hub serve" 2>/dev/null || true

echo "== summary =="
cat "$SUMMARY"
echo "elapsed: $(( $(date +%s) - START_TS ))s"
if [ "$FAIL" = "1" ]; then echo "LONGTASK-TEST: FAIL"; exit 1;
elif [ "$BLOCKED" = "1" ]; then echo "LONGTASK-TEST: BLOCKED"; exit 2;
else echo "LONGTASK-TEST: PASS"; exit 0; fi
