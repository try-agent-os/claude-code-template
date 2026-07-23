# Proposals — Procedural Memory

Workers write here proposals for improving an agent's CLAUDE.md based on experience executing tasks.

## How to read the queue (the single canonical way)

```bash
scripts/proposals-pending.sh            # paths of pending proposals, one per line
scripts/proposals-pending.sh --count    # just the number
scripts/proposals-pending.sh --all      # "<path>\t<status>" for every proposal
```

The script takes the status **only from the YAML frontmatter**, and only from the top
level of the directory (`archive/` is not the queue).

> ⛔ **Never assemble the queue by grepping for the status line** (`grep -l 'status:<space>pending'`
> and every variant of it). Grep looks at the whole file and reports as pending: this
> README, batch reviews (`REVIEW-*.md`), and the `### After` blocks of already-applied
> proposals that propose a new frontmatter. On 2026-07-23 a queue signal built that way
> showed 8 items against 1 real pending proposal — a queue that is mostly phantoms stops
> being read, and the live proposal drowns in them. Fix plus fixture test:
> `scripts/proposals-pending.sh`, `scripts/proposals-pending-test.sh`.
>
> For the same reason, **never write a literal status key with a value at the start of a
> line anywhere outside your own frontmatter** — not in examples, not in quotes. Use an
> angle-bracket placeholder or wrap it in inline code.

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
status: <one value from the table below>
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

The status is the only field the queue lives by: a typo in it means the proposal does
not exist for whatever reads the queue.

## Statuses

| Status | Meaning |
|--------|---------|
| `pending` | Awaits user review — **only this status reaches the digest** |
| `approved` | Approved; the edit is waiting to be applied |
| `applied` | The edit shipped; a commit link sits at the end of the proposal |
| `rejected` | Rejected by user; the reason is written into the file |
| `superseded` | Replaced by a later proposal (linked from the file) |
| `forwarded` | Handed to another instance/repo; it lives on there |

## `archive/`

Reviewed proposals and **every summary artifact** — batch reviews (`REVIEW-YYYY-MM-DD.md`),
triages (`TRIAGE-YYYY-MM-DD.md`) — belong in `memory/proposals/archive/`. A summary sitting
next to the live queue is not just visual noise: it quotes other proposals' statuses, and
any directory-wide scan used to count those quotes as live queue entries.
