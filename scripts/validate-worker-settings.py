#!/usr/bin/env python3
"""Pre-flight validator for a worker's settings.json.

Claude Code shows a BLOCKING "Settings Warning … 1. Continue / 2. Fix with
Claude / 3. Exit … Enter to confirm" dialog on startup when it loads a
settings.json containing an invalid rule. In a headless tmux worker nobody
presses Enter, so EVERY worker hangs empty until a timeout janitor kills it.
A single bad permission rule (e.g. `mcp__*` in permissions.allow) silently
takes down the whole worker fleet.

This script lints a settings.json for the KNOWN-BAD patterns that trigger
that dialog, BEFORE the launcher spawns any worker:

  1. Broken JSON (file unparseable / missing).
  2. Wildcard-only / wildcard-scoped MCP permission rules in allow|deny, e.g.
     "mcp__*", "mcp__*__foo", "mcp__" — Claude Code rejects these:
       "Wildcard tool name `mcp__*` is not supported in allow rules; an allow
        pattern must name the scope — globs only after literal `mcp__<server>__`".
     Valid MCP rules: "mcp__server", "mcp__server__tool", "mcp__server__*".

Exit codes:
  0  settings valid (or file absent — nothing to validate, not our failure)
  3  settings INVALID — caller must NOT spawn workers
  2  usage error

Usage:
  validate-worker-settings.py <CLAUDE_CONFIG_DIR | path/to/settings.json>
"""

from __future__ import annotations

import json
import os
import sys

LOG_PREFIX = "[validate-worker-settings]"


def log(msg: str) -> None:
    print(f"{LOG_PREFIX} {msg}", file=sys.stderr, flush=True)


def resolve_settings_path(arg: str) -> str:
    """Accept either a CLAUDE_CONFIG_DIR or a direct settings.json path."""
    if os.path.isdir(arg):
        return os.path.join(arg, "settings.json")
    return arg


def bad_mcp_rule(rule: str) -> str | None:
    """Return a human reason if `rule` is an invalid MCP permission rule, else None.

    Valid:   mcp__server | mcp__server__tool | mcp__server__* (glob after literal scope)
    Invalid: mcp__* | mcp__*__x | mcp__ | mcp__*anything (wildcard in/before the scope)
    """
    if not isinstance(rule, str) or not rule.startswith("mcp__"):
        return None
    # Strip any "(specifier)" suffix Claude allows on rules; the tool-name head
    # is what gets validated for the wildcard-scope error.
    head = rule.split("(", 1)[0]
    rest = head[len("mcp__"):]
    # Server scope is everything up to the next "__"; "" if no "__".
    server = rest.split("__", 1)[0]
    if server == "":
        return f"{rule!r}: empty MCP server scope (must be mcp__<server>...)"
    if "*" in server:
        return (
            f"{rule!r}: wildcard in MCP server scope is not supported "
            "(globs allowed only AFTER a literal mcp__<server>__)"
        )
    return None


def validate(path: str) -> int:
    if not os.path.exists(path):
        # No per-agent settings.json → Claude uses defaults, no dialog. Not our
        # failure; let the launcher proceed.
        log(f"no settings.json at {path} — nothing to validate (ok)")
        return 0

    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        log(f"INVALID: {path} is not valid JSON: {e}")
        return 3
    except OSError as e:
        log(f"INVALID: cannot read {path}: {e}")
        return 3

    if not isinstance(data, dict):
        log(f"INVALID: {path} top-level is not an object")
        return 3

    perms = data.get("permissions") or {}
    problems: list[str] = []
    if isinstance(perms, dict):
        for bucket in ("allow", "deny", "ask"):
            rules = perms.get(bucket) or []
            if not isinstance(rules, list):
                continue
            for rule in rules:
                reason = bad_mcp_rule(rule)
                if reason:
                    problems.append(f"permissions.{bucket}: {reason}")

    if problems:
        log(f"INVALID: {path} contains {len(problems)} blocking rule(s):")
        for p in problems:
            log(f"  - {p}")
        log("Claude Code would show a blocking 'Settings Warning' dialog → "
            "headless workers would hang. Refusing to spawn.")
        return 3

    log(f"OK: {path} passed pre-flight (JSON valid, no wildcard-scope MCP rules)")
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        log("usage: validate-worker-settings.py <CLAUDE_CONFIG_DIR | settings.json>")
        return 2
    return validate(resolve_settings_path(sys.argv[1]))


if __name__ == "__main__":
    sys.exit(main())
