#!/usr/bin/env python3
"""Claude Code statusline: model + context fill.

Reads statusline JSON from stdin, prints one line.

Context %:
  1. Preferred — the `context_window` object Claude Code passes on stdin
     (v2.1.132+): used_percentage + context_window_size, already matched to
     /context. This survives /compact correctly (server-reported).
  2. Fallback — sum input + cache_creation + cache_read from the LAST assistant
     turn in transcript_path (older clients that don't send context_window).

Window heuristic (fallback only):
  - env CLAUDE_MODEL_CONTEXT_WINDOW wins (numeric, raw tokens)
  - model.id ending in `[1m]` -> 1_000_000
  - everything else            -> 200_000

A high-fill marker is appended so a glance at the tmux pane flags a bloated
session before output degrades: ' !' at >=70%, ' !!' at >=85%.
"""
import json
import os
import sys

DEFAULT_WINDOW = 200_000
EXT_WINDOW = 1_000_000


def humanize(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M".rstrip("0").rstrip(".")
    if n >= 1_000:
        return f"{n // 1000}k"
    return str(n)


def window_for(model_id: str) -> int:
    env = os.environ.get("CLAUDE_MODEL_CONTEXT_WINDOW", "").strip()
    if env.isdigit():
        return int(env)
    if model_id and model_id.endswith("[1m]"):
        return EXT_WINDOW
    return DEFAULT_WINDOW


def from_context_window(cw: dict, window: int):
    """Return (used_tokens, window) from the stdin context_window object, or None."""
    if not isinstance(cw, dict):
        return None
    size = cw.get("context_window_size")
    if isinstance(size, (int, float)) and size > 0:
        window = int(size)
    cu = cw.get("current_usage") or {}
    if isinstance(cu, dict) and cu:
        used = (
            cu.get("input_tokens", 0)
            + cu.get("cache_creation_input_tokens", 0)
            + cu.get("cache_read_input_tokens", 0)
        )
        if used:
            return used, window
    pct = cw.get("used_percentage")
    if isinstance(pct, (int, float)) and pct >= 0:
        return int(pct * window / 100), window
    return None


def last_usage(transcript_path: str):
    if not transcript_path or not os.path.exists(transcript_path):
        return None
    last = None
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = rec.get("message") or {}
                usage = msg.get("usage")
                if usage:
                    last = usage
    except OSError:
        return None
    return last


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        data = {}

    model = data.get("model") or {}
    model_id = model.get("id") or ""
    model_name = model.get("display_name") or model_id or "claude"

    window = window_for(model_id)

    used = None
    cw = from_context_window(data.get("context_window") or {}, window)
    if cw is not None:
        used, window = cw
    else:
        usage = last_usage(data.get("transcript_path"))
        if usage is not None:
            used = (
                usage.get("input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
            )

    if used is None:
        ctx = "ctx -"
    else:
        pct = (used * 100) // window if window else 0
        mark = " !!" if pct >= 85 else (" !" if pct >= 70 else "")
        ctx = f"ctx {pct}%{mark} ({humanize(used)}/{humanize(window)})"

    # cwd: show the agent's working directory so that in a park of tmux
    # sessions it is immediately obvious where each agent lives. $HOME -> ~.
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or ""
    home = os.environ.get("HOME", "")
    if home and cwd.startswith(home):
        cwd = "~" + cwd[len(home):]

    line = f"  {model_name}  |  {ctx}"
    if cwd:
        line += f"  |  {cwd}"
    sys.stdout.write(line)


main()
