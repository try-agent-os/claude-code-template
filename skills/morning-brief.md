---
name: morning-brief
description: Morning briefing — gathers today's meetings, due tasks, PR status, pending replies, and hot topics. Sends it to the user in Telegram via the operator.
type: scheduled
trigger: morning-brief, morning briefing, good morning, morning
read_when: morning-brief, daily briefing
---

# Skill: Morning Brief

Daily morning briefing. Gathers context for the day and sends a summary to the user in Telegram.

## When to run

- Daily in the morning on schedule (`memory/schedule.md`: `morning-brief`, 24h)
- Task priority: medium

---

## Algorithm

### Step 1: Google Calendar — today's meetings

Fetch today's events via `mcp__claude_ai_Google_Calendar__list_events` (if the Calendar MCP is connected).

Format for each event:
- `HH:MM — Title`
- If `needsAction` — append `(not confirmed!)`

If there are no events — write "Free day".

---

### Step 2: Reply Watchdog — waiting on a user reply

Scan `../../memory/contacts/*.md` for signs of a pending reply:

```bash
PENDING=()
for f in ../../memory/contacts/*.md; do
  name=$(grep -m1 "^# " "$f" | sed 's/# //')
  # Signs of a waiting reply:
  if grep -q "replied\|proposed a meeting\|hasn't replied yet\|no reply to proposal\|pending_reply: true\|last_contact_direction: incoming" "$f"; then
    # Skip if DONE/closed/archived
    if ! grep -qi "DONE\|closed\|archived" "$f"; then
      next=$(grep 'Next step' "$f" | head -1 | sed 's/.*Next step[^:]*://;s/^\s*//')
      last=$(grep -o "### 2026-[0-9-]*" "$f" | tail -1)
      PENDING+=("• $name — $next ($last)")
    fi
  fi
done
```

If `PENDING` is non-empty — add a block to the final message:

```
⚡ Waiting on reply:
• [Name] — [one-line context]
```

If there are no pending — don't add the block (don't spam).

---

### Step 3: Hot topics

Read `../../memory/context.md` (if it exists). Extract 2-3 hottest items:
- Active deals (waiting for signature/reply)
- Critical deadlines
- Urgent tasks

---

### Step 4: Assemble and send via the operator

Message format (skip blocks with empty values):

```
🌅 DD.MM — Good morning!

📅 Today:
• HH:MM — Title
• HH:MM — Title (not confirmed!)

🔥 Hot:
• [item 1]
• [item 2]

⚡ Waiting on reply:
• [Name] — [context]
```

Send via claude-peers (the operator will forward to Telegram):

```bash
PEERS=$(curl -s http://127.0.0.1:7899/list-peers -H 'Content-Type: application/json' -d '{"scope":"machine","cwd":"/","git_root":null}')
OPERATOR_ID=$(echo "$PEERS" | python3 -c "import json,sys; peers=json.load(sys.stdin); print(next((p['id'] for p in peers if 'operator' in p.get('cwd','')), ''))")
if [ -n "$OPERATOR_ID" ]; then
  curl -s http://127.0.0.1:7899/send-message \
    -H 'Content-Type: application/json' \
    -d "{\"to_id\": \"$OPERATOR_ID\", \"from_id\": \"morning-brief\", \"text\": \"<MESSAGE>\"}"
fi
```

---

### Step 5: Update check-log

```bash
echo "morning-brief | $(date '+%Y-%m-%d %H:%M') | sent" >> ../../memory/check-log.md
```

---

## Errors

| Situation | Action |
|-----------|--------|
| Google Calendar unavailable | Skip Step 1, continue |
| Operator not found in peers | Skip sending, record in result.md |
| `memory/contacts/` empty | Step 2 → don't add the block |
