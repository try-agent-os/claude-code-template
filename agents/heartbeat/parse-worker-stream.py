#!/usr/bin/env python3
"""
parse-worker-stream.py — Worker stream-json parser

Reads stream-json from stdin (claude --output-format stream-json).
- Writes readable text to stdout (for iter-N-output.txt)
- Writes cost JSON to cost_file (positional arg)

Usage:
  claude ... --output-format stream-json | python3 parse-worker-stream.py /path/to/iter-1-cost.json
"""

import sys
import json

cost_file = sys.argv[1] if len(sys.argv) > 1 else None

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        print(line, flush=True)
        continue

    t = msg.get("type", "")

    if t == "assistant" and "message" in msg:
        for block in msg["message"].get("content", []):
            if block.get("type") == "text":
                text = block["text"].strip()
                if text:
                    print(text, flush=True)
            elif block.get("type") == "thinking":
                # Skip thinking blocks in output
                pass

    elif t == "result":
        # Write cost data to file
        if cost_file:
            cost_data = {
                "total_cost_usd": msg.get("total_cost_usd", 0),
                "num_turns": msg.get("num_turns", 0),
                "duration_ms": msg.get("duration_ms", 0),
                "subtype": msg.get("subtype", ""),
                "is_error": msg.get("is_error", False),
                "usage": msg.get("usage", {}),
                "modelUsage": msg.get("modelUsage", {}),
            }
            try:
                with open(cost_file, "w") as f:
                    json.dump(cost_data, f, indent=2)
            except Exception as e:
                print(f"[cost-parse] ERROR writing cost file: {e}", file=sys.stderr)
        # Print cost summary to stderr (visible in tmux output.log)
        cost = msg.get("total_cost_usd", 0)
        duration = msg.get("duration_ms", 0) / 1000
        turns = msg.get("num_turns", 0)
        is_err = msg.get("is_error", False)
        status = "FAIL" if is_err else "DONE"
        print(f"[cost] {status} | ${cost:.4f} | {duration:.0f}s | {turns} turns", flush=True)
