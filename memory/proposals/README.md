# Proposals — Procedural Memory

Workers write here proposals for improving an agent's CLAUDE.md based on experience executing tasks.

## Lifecycle

```
Worker discovered a better way → wrote a proposal in memory/proposals/
Dispatcher (watchdog) → if proposal > 1 day old → notifies operator
Operator → forwards to user in Telegram (approve/reject)
User approves → sysadmin applies the change to the agent's CLAUDE.md
User rejects → file deleted, entry written to learnings.md
```

## File format

File name: `{YYYY-MM-DD}-{task-id}.md`

```markdown
---
date: YYYY-MM-DD
task_id: <saga task id>
agent: heartbeat|operator|sysadmin|<worker-name>
file: agents/{agent}/CLAUDE.md (or another file)
status: pending|approved|rejected
---

## Proposal

What to change and why.

## Change

### Before
<current text>

### After
<proposed text>

## Rationale

Why this will improve the agent's behavior. Concrete experience from the task.
```

## Statuses

| Status | Meaning |
|--------|---------|
| `pending` | Awaits user review |
| `approved` | Approved; sysadmin applies |
| `rejected` | Rejected by user |
