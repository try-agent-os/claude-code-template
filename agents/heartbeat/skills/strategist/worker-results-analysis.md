---
title: Worker Results Analysis (Reflexion)
summary: Reads all workers' result.md from the last 7 days, finds systemic error/success patterns, writes them into patterns-staging.md, and creates tracker tasks for systemic problems.
read_when: heartbeat_count % 5 == 0 (every 5 strategist cycles ~50 heartbeat); reflection is needed to close the feedback loop.
---

# Skill: Worker Results Analysis (Reflexion)

Reflection cycle: the strategist reads results from all workers in the last N cycles, finds error and success patterns, and closes the feedback loop.

**When to run:** `heartbeat_count % 5 == 0` (every 5 strategist cycles, i.e. every ~50 heartbeat cycles).

## Algorithm

### 1. Collect result.md

Read every `logs/workers/*/result.md`. Claude Code can read these files without extra flags.

For each result.md, capture:
- `task_id` (directory name)
- `status`: done | partial | blocked | failed (from frontmatter)
- `summary` (from frontmatter)
- File creation date (from git log or frontmatter if available)

Focus on results from the last 5-7 days, so you don't process the same data multiple times.

### 2. Group patterns

Split results into categories:

**Errors (status: blocked | failed):**
- Find tasks with the same error type (zombie worker, timeout, MCP unavailable, sandbox restrictions)
- If the same error appears 2+ times → systemic problem
- If a task is blocked across 2+ attempts → escalation candidate

**Successes (status: done | partial):**
- Find tasks with strong results (summary contains concrete numbers, artifacts, insights)
- Identify what worked: task type, skill used, approach
- If a success pattern repeats 2+ times → promotion candidate

**Incomplete / timeout:**
- Tasks that hit MAX_ITERATIONS or TIMEOUT
- Signal of incorrect scope or oversized task

### 3. Write patterns to staging

For each pattern found (error or success), add an entry to `memory/patterns-staging.md`:

```
---
date: YYYY-MM-DD
task_id: strategist-reflexion
pattern: short pattern description (one sentence)
confidence: 0.7
confirmed_in:
  - logs/workers/{task_id_1}/result.md
  - logs/workers/{task_id_2}/result.md
notes: context — why this is a pattern, not a one-off event
---
```

Minimum threshold: pattern confirmed in 2+ result.md. A single event is not a pattern.

### 4. Systemic problems → tracker task

If a systemic problem is found (3+ tasks with one error type), create a task:

```
mcp__saga-mcp__task_create(
  epic_id: <Infra epic id>,  // resolve via memory/epic-map.json
  title: "Fix: <short problem description>",
  description: "Systemic problem detected by reflexion analysis:\n\n<details>\n\nAffected workers: <list of task_ids>\n\nScope: identify root cause and resolve",
  priority: "high"
)
```

### 5. Add to the strategist summary

Add a section to the strategist's final report:

```markdown
## Worker Reflexion
- result.md analyzed: N
- Successes: N (done/partial)
- Failures: N (blocked/failed/timeout)
- New patterns to staging: N
- Systemic problems → tasks created: N
```

## What NOT to do

- Don't read `iter-N-output.txt` (too large) — only `result.md`
- Don't process result.md older than 7 days (already processed)
- Don't duplicate patterns already in `memory/patterns.md` or `memory/patterns-staging.md`
- Don't create a task if the issue already exists as todo/in_progress in the tracker

## Access to logs/workers/

Workers have `--add-dir memory/` to write into patterns-staging.md. Reading `logs/workers/*/result.md` is unrestricted (Claude Code does not gate reads via --add-dir).
