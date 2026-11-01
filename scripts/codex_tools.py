#!/usr/bin/env python3
"""List the distinct tool names used in a `codex exec --json` log.

Usage: codex_tools.py <logfile>
Prints one tool name per line, sorted. Prints nothing when the log has
no tool-call items (plain output, or the model called nothing).

Codex CLI 0.166.0 --json emits one JSON object per line; tool calls
appear as {"type": "item.started"|"item.completed",
"item": {"type": "<tool-type>", ...}}. The tool types seen so far:
  command_execution -> shell (the model runs /bin/bash -lc '...')
  file_change       -> apply_patch (item.changes lists path + kind)
No separate read item type was observed: the model reads files through
the shell (e.g. sed -n '2p' file). No web_search or plan item type
appeared in Mac CI run 21 either, so those tools are reported only if
a matching item type ever shows up.
The older function_call shape (type == "function_call" with a "name")
is still accepted, in case a future codex version emits it.
"""
import json
import sys

# CLI --json item type -> tool name shown in the test summary.
ITEM_TOOL = {
    "command_execution": "shell",
    "file_change": "apply_patch",
    "web_search": "web_search",
    "web_search_call": "web_search",
    "plan": "update_plan",
    "update_plan": "update_plan",
}


def walk(o, out):
    if isinstance(o, dict):
        if o.get("type") == "function_call" and o.get("name"):
            out.add(str(o["name"]))
        item = o.get("item")
        if isinstance(item, dict):
            tool = ITEM_TOOL.get(str(item.get("type", "")))
            if tool:
                out.add(tool)
        for v in o.values():
            walk(v, out)
    elif isinstance(o, list):
        for v in o:
            walk(v, out)


def main():
    names = set()
    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                walk(obj, names)
    except Exception as e:
        print(f"parse-error: {e}", file=sys.stderr)
        return 1
    for n in sorted(names):
        print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
