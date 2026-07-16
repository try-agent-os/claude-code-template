#!/usr/bin/env bash
# PreCompact hook — capture the tail of the live session transcript BEFORE
# Claude Code compacts (summarizes) the context window.
#
# Fires: before both /compact (manual) and auto-compaction (matcher "*").
# Claude Code v2.1.90+ hook type. Docs: code.claude.com/docs/en/hooks
#
# Payload (stdin JSON): session_id, transcript_path, cwd, trigger, ...
#
# Side effects (never blocks compaction — always exit 0):
#   1. Writes last N conversation messages ->
#      ${PRECOMPACT_SNAPSHOT_DIR}/precompact-{session}-{ts}.md
#      (default dir: ${AGENTOS_HOOKS_LOG_DIR:-/tmp/agentos-hooks})
#   2. If cwd is an operator session (…/agents/operator) -> ALSO copies the
#      snapshot to $CLAUDE_PROJECT_DIR/memory/operator-context-snapshot.md so
#      the operator can Read one well-known path after the window is truncated.
#
# This is transcript-level context: the actual last messages of THIS session,
# as opposed to any external state (chat/queue/task) snapshot you may also run.
#
# Config:
#   PRECOMPACT_MSG_COUNT     tail length in messages (default 30)
#   PRECOMPACT_SNAPSHOT_DIR  output directory (default $AGENTOS_HOOKS_LOG_DIR)

set -uo pipefail

HOOK_NAME="precompact-snapshot"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

SESSION_ID="$(json '.session_id')"
TRANSCRIPT_PATH="$(json '.transcript_path')"
CWD="$(json '.cwd')"
TRIGGER="$(json '.trigger')"
MSG_COUNT="${PRECOMPACT_MSG_COUNT:-30}"

: "${SESSION_ID:=unknown}"
: "${TRIGGER:=unknown}"

OUT_DIR="${PRECOMPACT_SNAPSHOT_DIR:-${AGENTOS_HOOKS_LOG_DIR:-/tmp/agentos-hooks}}"
mkdir -p "$OUT_DIR" 2>/dev/null || OUT_DIR=/tmp

TS_UTC="$(date -u +%Y-%m-%dT%H-%M-%SZ 2>/dev/null || echo unknown)"
OUT="${OUT_DIR}/precompact-${SESSION_ID}-${TS_UTC}.md"

log "trigger=$TRIGGER session=$SESSION_ID transcript=$TRANSCRIPT_PATH cwd=$CWD -> $OUT"

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
  log "transcript unreadable, writing stub"
  {
    printf '# PreCompact snapshot (transcript unavailable)\n\n'
    printf '**Session:** %s\n**Trigger:** %s\n**Generated:** %s\n' \
      "$SESSION_ID" "$TRIGGER" "$(date -u -Iseconds 2>/dev/null)"
  } > "$OUT" 2>/dev/null || true
  exit 0
fi

PYTHONDONTWRITEBYTECODE=1 python3 - "$TRANSCRIPT_PATH" "$SESSION_ID" "$TRIGGER" "$MSG_COUNT" > "$OUT" 2>/dev/null <<'PYEOF'
import json, sys, datetime

path, session, trigger, count = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    n = max(1, int(count))
except ValueError:
    n = 30

def render_content(content):
    """Flatten a message .content (string or block array) to readable text."""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            parts.append((block.get("text") or "").strip())
        elif btype == "thinking":
            # keep a marker but not the full chain-of-thought
            parts.append("_[thinking]_")
        elif btype == "tool_use":
            name = block.get("name", "?")
            inp = block.get("input", {})
            summary = ""
            if isinstance(inp, dict):
                for k in ("command", "file_path", "path", "pattern", "description", "query"):
                    if k in inp and inp[k]:
                        summary = f"{k}={str(inp[k])[:160]}"
                        break
            parts.append(f"_[tool_use: {name}{(' · ' + summary) if summary else ''}]_")
        elif btype == "tool_result":
            c = block.get("content")
            if isinstance(c, list):
                txt = " ".join(
                    (b.get("text") or "") for b in c
                    if isinstance(b, dict) and b.get("type") == "text"
                )
            else:
                txt = str(c or "")
            txt = txt.replace("\r", "").replace("\n", " ").strip()
            if len(txt) > 300:
                txt = txt[:300] + "…"
            parts.append(f"_[tool_result: {txt}]_" if txt else "_[tool_result]_")
    return "\n".join(p for p in parts if p)

msgs = []
try:
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") not in ("user", "assistant"):
                continue
            m = obj.get("message") or {}
            role = m.get("role") or obj.get("type")
            text = render_content(m.get("content"))
            if not text:
                continue
            ts = obj.get("timestamp", "")
            msgs.append((role, ts, text))
except OSError:
    pass

tail = msgs[-n:]

out = []
out.append("# PreCompact context snapshot\n")
out.append(f"**Session:** {session}")
out.append(f"**Trigger:** {trigger} (compaction)")
out.append(f"**Generated:** {datetime.datetime.utcnow().isoformat()}Z")
out.append(f"**Messages captured:** {len(tail)} (of {len(msgs)} total, tail N={n})\n")
out.append("Read this as **the immediate prior conversation** of this session. "
           "The context window was about to be compacted (summarized); these are the "
           "last raw messages before that happened.\n")
out.append("---\n")
for role, ts, text in tail:
    label = "🧑 User" if role == "user" else "🤖 Assistant"
    header = f"### {label}" + (f" · {ts}" if ts else "")
    out.append(header)
    out.append(text)
    out.append("")

sys.stdout.write("\n".join(out))
PYEOF

if [ ! -s "$OUT" ]; then
  log "python produced empty output"
fi

# Operator session → mirror to a stable path inside the repo.
case "$CWD" in
  */agents/operator|*/agents/operator/*)
    DEST="${CLAUDE_PROJECT_DIR}/memory/operator-context-snapshot.md"
    if cp -f "$OUT" "$DEST" 2>/dev/null; then
      log "mirrored to $DEST (operator session)"
    else
      log "failed to mirror to $DEST"
    fi
    ;;
esac

exit 0
