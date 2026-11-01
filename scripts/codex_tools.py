#!/usr/bin/env python3
"""List the distinct tool (function_call) names in a `codex exec --json` log.

Usage: codex_tools.py <logfile>
Prints one tool name per line, sorted. Prints nothing when the log has
no function_call items (plain output, or the model called nothing).

The JSONL shape varies across codex versions, so every object is walked
recursively and any dict with type == "function_call" and a "name" counts.
"""
import json
import sys


def walk(o, out):
    if isinstance(o, dict):
        if o.get("type") == "function_call" and o.get("name"):
            out.add(str(o["name"]))
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
