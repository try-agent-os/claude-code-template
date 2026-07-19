#!/bin/bash
# context-usage.sh — report the operator session's current context fill.
#
# Prints a single line:
#   "<pct> <used_tokens> <window> <transcript_bytes> <transcript_mtime_epoch>"
# (integers). On any failure (no transcript, unreadable, no usage records yet)
# prints "0 0 <window> 0 0" and exits 0 — callers treat 0% as "nothing to do",
# never as an error. The 5th field is the epoch mtime of the live transcript,
# used by operator-watchdog.sh block (D) to measure session inactivity (every
# message / tool-call rewrites the transcript, so mtime is a reliable idle
# clock). 0 on failure paths = "no transcript to measure" (block D skips).
# Legacy readers using `read -r A B C D _` are unaffected (5th field dropped).
#
# NOTE on the 4th field (transcript_bytes): token-% alone UNDER-reports the real
# bloat failure mode. An observed degraded transcript was 26 MB on disk yet only
# ~61% token fill (huge tool RESULTS — file reads, command output, JSON — inflate
# the on-disk/in-memory transcript far beyond the prompt token count that `usage`
# reports). Tool-call emission degrades and replies get silently dropped well
# before tokens hit 70%. So callers also gate on raw byte size.
#
# This mirrors the statusline gauge (.claude/statusline.sh): context size =
# input + cache_creation + cache_read of the LAST assistant turn in the
# transcript jsonl (cache_read already folds in earlier prompt tokens, so the
# latest turn matches /context). Used by detect-and-restart.sh to force a
# fresh session BEFORE a bloated context degrades tool-call emission — an
# observed failure mode where an outgoing reply was silently dropped.
#
# Env knobs (all optional):
#   OPERATOR_CONFIG_DIR   — CLAUDE_CONFIG_DIR of the operator session
#                           (default: /var/lib/agent-os/claude-config/server)
#   OPERATOR_PROJECT_KEY  — the projects/<key> dir for the operator cwd. Claude
#                           Code derives it from the cwd by replacing '/' with
#                           '-'; by default we derive it the same way from this
#                           repo's agents/operator path, so a non-default
#                           INSTALL_ROOT works without configuration.
#   CLAUDE_MODEL_CONTEXT_WINDOW — raw token window (default 1_000_000 for [1m])
#   OPERATOR_TRANSCRIPT   — explicit transcript path (overrides discovery; tests)

set -uo pipefail

# Self-locating: this script lives at <repo>/scripts/operator-autocompact/.
_CU_REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONFIG_DIR="${OPERATOR_CONFIG_DIR:-/var/lib/agent-os/claude-config/server}"
PROJECT_KEY="${OPERATOR_PROJECT_KEY:-$(printf '%s' "$_CU_REPO/agents/operator" | tr '/.' '--')}"
WINDOW="${CLAUDE_MODEL_CONTEXT_WINDOW:-1000000}"
[[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=1000000

TRANSCRIPT="${OPERATOR_TRANSCRIPT:-}"
if [ -z "$TRANSCRIPT" ]; then
  TRANSCRIPT=$(ls -t "$CONFIG_DIR/projects/$PROJECT_KEY/"*.jsonl 2>/dev/null | head -1)
fi

if [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
  echo "0 0 $WINDOW 0 0"
  exit 0
fi

TBYTES=$(stat -c%s "$TRANSCRIPT" 2>/dev/null || echo 0)
[[ "$TBYTES" =~ ^[0-9]+$ ]] || TBYTES=0

TMTIME=$(stat -c%Y "$TRANSCRIPT" 2>/dev/null || echo 0)
[[ "$TMTIME" =~ ^[0-9]+$ ]] || TMTIME=0

python3 - "$TRANSCRIPT" "$WINDOW" "$TBYTES" "$TMTIME" <<'PYEOF'
import json, sys

path, window, tbytes, tmtime = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
last = None
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            usage = (rec.get("message") or {}).get("usage")
            if usage:
                last = usage
except OSError:
    pass

if not last:
    print(f"0 0 {window} {tbytes} {tmtime}")
else:
    used = (
        last.get("input_tokens", 0)
        + last.get("cache_creation_input_tokens", 0)
        + last.get("cache_read_input_tokens", 0)
    )
    pct = (used * 100) // window if window else 0
    print(f"{pct} {used} {window} {tbytes} {tmtime}")
PYEOF
