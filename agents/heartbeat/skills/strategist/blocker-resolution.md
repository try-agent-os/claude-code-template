---
title: Blocker Resolution
summary: Protocol for working with blocked tasks — first attempt to unblock yourself, then formulate a precise minimal request to the user, then aging analysis after 24h.
read_when: Tasks are in blocked status in queue.md or saga-mcp; need to unblock or formulate a request to the user.
---

# Skill: Blocker Resolution

Protocol for working with blocked tasks in `memory/queue.md`.

## Step 1: Unblock yourself

Before escalating — try to solve it yourself:

- **Can you work around it?** Alternative API, different tool, different approach
- **Can you decompose?** Split into parts, do what's possible now
- **Is the data available another way?** Different source for the same information

Examples:
- "Contact not found" → Telegram CLI, web search, gmail search, tracker, meeting transcripts
- "No API key" → free alternative? Workaround without a key? Another service?
- "No chat access" → list chats, ask for an invite, find a public analog
- "Lacking context" → memory files, telegram history, gmail, transcripts

If you successfully unblocked → change status to `in_progress`, update scope.

## Step 2: A concrete request

If you can't solve it yourself — formulate a request to the user:

**Bad:** "Need GitHub API creds"
**Good:** "Add GITHUB_TOKEN to .env. Create token: Settings → Developer → Personal access tokens → Fine-grained. Scope: repo (read). Expected format: `GITHUB_TOKEN=ghp_xxx`"

Principles:
- Minimum action from the user
- Concrete instruction (where, what, how)
- Link to where to create/find the thing
- Expected format/result

Request → task in memory/queue.md with priority MED, type: `awaiting_user`.

## Step 3: Aging

Every 24h, re-evaluate blocked tasks:

1. **Still relevant?** Context may have changed, priorities may have shifted
2. **New data?** New signals/contacts may have appeared
3. **Alternative path?** With new context there may be a different solution

Aging rules:
- Max 3 escalations per task
- After 3 escalations → status `awaiting_user`, no further escalation
- Task blocked > 7 days with no movement → propose archiving
