#!/usr/bin/env bash
# SessionStart hook — recall recent Telegram context after operator restart.
#
# When the autocompact restart timer fires (or any other systemctl restart of
# agent-os-operator), this hook runs on the fresh Claude session before the first
# user prompt arrives. It injects the last ~20 messages with the user plus a list
# of any unanswered IN messages so the next channel push from Telegram is
# answered as a continuation of the prior thread, not a fresh "what did you mean?"
# request.
#
# Mode dispatch: Claude Code passes the matcher type as $1 (`startup`, `resume`,
# `clear`, `compact`). We inject only for `startup` and `resume` — `clear`/`compact`
# are user-initiated mid-session, where the operator already has context.
#
# Output: plain stdout text (per Claude Code hooks contract, stdout from
# SessionStart is appended as additional context). Exit 0 unconditionally —
# context injection failures must never block boot.
#
# Required config: OPERATOR_CHAT_ID (the user's Telegram chat id). If unset the
# hook exits 0 without injecting context.

set -uo pipefail

MODE="${1:-startup}"
case "$MODE" in
  startup|resume) ;;
  *) exit 0 ;;
esac

TG_DB="${OPERATOR_TG_DB:-/opt/agent-os/claude/plugins/telegram/messages.db}"
CHAT_ID="${OPERATOR_CHAT_ID:-}"
STATE_DIR="${AUTOCOMPACT_STATE_DIR:-/var/lib/agent-os}"

# Drain stdin if anything is piped in (Claude Code may send JSON for SessionStart).
cat >/dev/null 2>&1 || true

[ -n "$CHAT_ID" ] || exit 0
[ -r "$TG_DB" ] || exit 0

RECENT_JSON="$(sqlite3 "$TG_DB" ".mode json" \
  "SELECT direction, datetime(created_at) AS ts, COALESCE(text,'') AS text
   FROM messages WHERE chat_id=$CHAT_ID
   ORDER BY created_at DESC LIMIT 20;" 2>/dev/null || echo "[]")"

UNANSWERED_JSON="$(sqlite3 "$TG_DB" ".mode json" \
  "SELECT datetime(created_at) AS ts, COALESCE(text,'') AS text
   FROM messages
   WHERE chat_id=$CHAT_ID
     AND direction='in'
     AND created_at > datetime('now', '-24 hours')
     AND created_at > COALESCE(
       (SELECT MAX(created_at) FROM messages WHERE chat_id=$CHAT_ID AND direction='out'),
       '1970-01-01'
     )
   ORDER BY created_at DESC;" 2>/dev/null || echo "[]")"

RESTARTED_FLAG="$STATE_DIR/operator-restarted-since-last-msg.flag"
RESTART_TS=""
if [ -f "$RESTARTED_FLAG" ]; then
  RESTART_TS="$(stat -c '%y' "$RESTARTED_FLAG" 2>/dev/null | cut -d. -f1 || true)"
fi

python3 - "$RECENT_JSON" "$UNANSWERED_JSON" "$RESTART_TS" <<'PYEOF'
import json, sys

recent_raw, unans_raw, restart_ts = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    recent = json.loads(recent_raw or "[]")
except Exception:
    recent = []
try:
    unans = json.loads(unans_raw or "[]")
except Exception:
    unans = []

out = []
out.append("[OPERATOR SESSION-START — recall recent Telegram thread]")
out.append("")
if restart_ts:
    out.append(f"This session likely follows an autocompact silence-restart at {restart_ts} UTC.")
    out.append("Dedup flag is set: no further auto-restart until the user writes.")
    out.append("")

if recent:
    out.append("Last 20 Telegram messages with the user (chronological):")
    for r in reversed(recent):
        d = r.get("direction", "")
        direction = "IN " if d == "in" else "OUT"
        ts = r.get("ts", "")
        txt = (r.get("text") or "").replace("\r", "").replace("\n", " ¶ ").strip()
        if len(txt) > 400:
            txt = txt[:400] + "…"
        out.append(f"- [{direction}] {ts}  {txt}")
    out.append("")
else:
    out.append("No prior Telegram history with the user in this DB.")
    out.append("")

if unans:
    out.append(f"Unanswered IN messages from the user (last 24h, no OUT after): {len(unans)}")
    for u in unans:
        ts = u.get("ts", "")
        txt = (u.get("text") or "").replace("\r", "").replace("\n", " ¶ ").strip()
        if len(txt) > 200:
            txt = txt[:200] + "…"
        out.append(f"- [{ts}] {txt}")
    out.append("")
    out.append("Acknowledge and respond to each on the next prompt. Also: telegram-mcp will re-push them as [MISSED at ...] channel notifications.")
else:
    out.append("No unanswered IN from the user in last 24h.")
out.append("")
out.append("Treat the next incoming Telegram message as a CONTINUATION of this thread.")

print("\n".join(out))
PYEOF

exit 0
