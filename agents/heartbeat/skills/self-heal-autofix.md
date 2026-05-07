---
title: Self-Heal Autofix (L3 FIX)
summary: Automatic AgentOS recovery via 8 runbooks (RB-001..RB-008): MCP restart, task decomposition, orphan reset, dispatcher restart, zombie flood mitigation. Called after L2 diagnosis.
read_when: Called after self-heal-diagnose.md with a populated diagnosis JSON; diagnosis_type is set and auto_fixable=true. For auth_expired and unknown — escalate.
---

# Skill: Self-Heal Autofix (Level 3: FIX)

**Purpose:** Automatically recover AgentOS based on diagnosis (L2) results.
**Trigger:** Called after `self-heal-diagnose.md` with a populated diagnosis JSON.
**Inputs:** `diagnosis_type` + `saga_task_id` + (for mcp_down) name of the failed service.
**Outputs:** entry in `logs/health/autofix.log`, tracker task update, operator notification.

---

## Mapping: diagnosis_type → Runbook

| diagnosis_type | Runbook | auto_fixable |
|----------------|---------|--------------|
| `mcp_down` | RB-001 | YES |
| `too_large` / MAX_ITERATIONS | RB-002 | YES |
| `orphan` | RB-003 | YES |
| `dispatcher_gap` | RB-004 | YES |
| `zombie_loop` | RB-005 | YES |
| `rate_limit` | RB-006 | YES (wait) |
| `auth_expired` | RB-007 | NO → escalate |
| `unknown` | RB-008 | NO → escalate |

NOTE: launchd service labels in this runbook use `com.<PROJECT_SLUG>.<service>`. Replace `<PROJECT_SLUG>` with your deployment's slug. Epic IDs resolve via `memory/epic-map.json` — references like "Infra epic" mean the AgentOS infrastructure epic.

---

## RB-001: MCP Restart Autofix

**Trigger:** `diagnosis_type = "mcp_down"` — one of the MCP services isn't responding to the health check.

### Step 1: Identify the failed service

Probe all three MCPs via curl:

```bash
# saga-mcp (port 3851)
curl -s --max-time 3 http://localhost:3851/health 2>&1
STATUS_SAGA=$?

# telegram-mcp (port 3848)
curl -s --max-time 3 http://localhost:3848/health 2>&1
STATUS_TG=$?

# claude-peers (port 7899)
curl -s --max-time 3 http://127.0.0.1:7899/health 2>&1
STATUS_PEERS=$?
```

Port → launchd label mapping:

| Port | Service | launchd label |
|------|---------|---------------|
| 3851 | saga-mcp | `com.<PROJECT_SLUG>.saga-mcp` |
| 3848 | telegram-mcp | `com.<PROJECT_SLUG>.telegram-mcp` |
| 7899 | claude-peers | `com.<PROJECT_SLUG>.claude-peers-broker` |

You can also cross-check via:

```bash
launchctl list | grep <PROJECT_SLUG>
# Format: PID | ExitCode | Label
# PID = "-" means service not running
# ExitCode != 0 means service crashed
```

### Step 2: Kickstart the failed service

```bash
FAILED_LABEL="com.<PROJECT_SLUG>.saga-mcp"  # replace with the actual label
USER_ID=$(id -u)

launchctl kickstart -k "gui/${USER_ID}/${FAILED_LABEL}"
```

The `-k` flag = kill + restart (safer than just start; idempotent).

### Step 3: Wait 5 seconds, recheck health

```bash
sleep 5

# Health check on the corresponding port
# For saga-mcp:
HEALTH=$(curl -s --max-time 5 http://localhost:3851/health 2>&1)

# Cross-check via launchctl
launchctl list | grep "${FAILED_LABEL}"
```

### Step 4: Record result in autofix.log

```bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if echo "$HEALTH" | grep -qiE "ok|healthy|running"; then
  RESULT="SUCCESS"
else
  RESULT="FAILED"
fi

echo "${TIMESTAMP} | RB-001 | ${FAILED_LABEL} | kickstart: ${RESULT} | health: ${HEALTH}" >> logs/health/autofix.log
```

### Step 5: On SUCCESS

1. Repeat health check after 10 sec to confirm stability
2. If a worker task was tied to this MCP — reset its status to `todo` (so the dispatcher restarts it):

   ```
   mcp__saga-mcp__task_update(id: <saga_task_id>, status: "todo")
   ```

3. Notify operator:

   ```
   [AUTOFIX OK] RB-001: {FAILED_LABEL} restarted. Worker {task_slug} reset to todo.
   ```

### Step 6: On FAILURE

1. Record FAILED in autofix.log
2. Create an escalation task in the Infra epic:

   ```
   mcp__saga-mcp__task_create(
     epic_id: <Infra epic id>,
     title: "ESCALATE: MCP {FAILED_LABEL} did not recover after kickstart",
     description: "RB-001 autofix didn't help. Manual diagnosis required.\n\nEvidence:\n- launchctl kickstart executed\n- health check after 5s: {HEALTH}\n\nNext steps:\n1. Check logs: ~/Library/Logs/<PROJECT_SLUG>/{label}.log\n2. Verify plist in ~/Library/LaunchAgents/\n3. Manual restart or reboot",
     priority: "high"
   )
   ```

3. Notify operator:

   ```
   [AUTOFIX FAILED] RB-001: {FAILED_LABEL} did not recover. Sysadmin task #N created. Manual diagnosis required.
   ```

---

## RB-002: MAX_ITERATIONS Decompose

**Trigger:** `diagnosis_type = "too_large"` — worker hit MAX_ITERATIONS and the task isn't done.

**Detector:** the worker's output.log contains lines like:
- `"max_iterations"` / `"max iterations reached"` / `"Max iterations"`
- `"reached iteration limit"` / `"iteration 30/30"`

### Step 1: Read the original task description

```
mcp__saga-mcp__task_get(id: <saga_task_id>)
```

Save: `title`, `description`, `epic_id`.

### Step 2: Read the latest iter-output

```bash
# Find the latest iteration log
ls -t logs/workers/{task_slug}/iter-*-output.txt 2>/dev/null | head -1
# or
cat logs/workers/{task_slug}/output.log 2>/dev/null | tail -200
```

Goal: figure out **what's already done** and **what's left**.

### Step 3: Determine done vs remaining

Inspect output for completed-step signals:
- Mentions of "done", "created", "wrote", "updated", "sent"
- Commits (`git commit` in output)
- Created files (Write tool calls in the log)

Determine the remaining scope: anything mentioned in the description that didn't appear in the output.

### Step 4: Create 3-5 subtasks

Split the remaining scope into chunks of <= 15 iterations each:

```
mcp__saga-mcp__task_create(
  epic_id: <original epic_id>,
  title: "<Original title> — part 1/3: <what specifically>",
  description: "Continuation of task #<original_id> after MAX_ITERATIONS.\n\nAlready done (from output.log):\n- ...\n\nThis part's scope:\n- ...\n\nRelated files:\n- logs/workers/{task_slug}/output.log",
  priority: "medium"
)
```

For sequential steps — use `depends_on` if your tracker API supports it. Otherwise just create them in execution order.

### Step 5: Block the original task

```
mcp__saga-mcp__task_update(
  id: <saga_task_id>,
  status: "blocked",
  description: "<existing_description>\n\n---\n[DECOMPOSED YYYY-MM-DD] MAX_ITERATIONS. Split into subtasks: #N1, #N2, #N3"
)
```

### Step 6: Record in autofix.log

```bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "${TIMESTAMP} | RB-002 | task_${SAGA_TASK_ID} | decomposed into #N1,#N2,#N3 | subtasks: 3" >> logs/health/autofix.log
```

### Step 7: Notify operator

```
[AUTOFIX OK] RB-002: task #<id> ({title}) hit MAX_ITERATIONS.
Decomposed into 3 subtasks: #N1, #N2, #N3.
Original task blocked.
```

---

## RB-003: Tracker Orphan Reset

**Trigger:** `diagnosis_type = "orphan"` — task is `in_progress` in the tracker, but no tmux worker session exists.

### Step 1: Get the list of in_progress tasks

```
mcp__saga-mcp__task_list(status: "in_progress")
```

Save the list: `[{id, title}, ...]`

### Step 2: For each task — derive slug and check tmux

Slug = transliterated title + spaces replaced with `-` + lowercase. Examples:
- "Scan Telegram chats" → `scan-telegram-chats`
- "Outreach Andrew Golman" → `outreach-andrew-golman`

```bash
# For each slug:
SLUG="<task-slug>"
tmux ls 2>/dev/null | grep "^worker-${SLUG}"
STATUS=$?
# STATUS=0 → session exists (live worker)
# STATUS=1 → session not found (orphan)
```

### Step 3: Reset orphan tasks to todo

For each task whose tmux session is missing:

```
mcp__saga-mcp__task_update(id: <task_id>, status: "todo")
```

### Step 4: Record in autofix.log

```bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
echo "${TIMESTAMP} | RB-003 | orphan reset: ${SLUG} (#${TASK_ID})" >> memory/autofix.log
```

If no orphans were found:

```bash
echo "${TIMESTAMP} | RB-003 | no orphans found" >> memory/autofix.log
```

### Step 5: Notify operator (only if tasks were reset)

```
[AUTOFIX OK] RB-003: reset N orphan tasks to todo: {slug1}, {slug2}
```

---

## RB-004: Dispatcher Restart

**Trigger:** `diagnosis_type = "dispatcher_gap"` — dispatcher hasn't run in over 45 minutes (gap in cycle continuity).

### Step 1: Check the dispatcher's last exit

```bash
USER_ID=$(id -u)
launchctl print "gui/${USER_ID}/com.<PROJECT_SLUG>.heartbeat-dispatcher" 2>&1 | grep -E "last-exit|time-since"
```

Expected output contains `time since last exit` — seconds since the last run.

### Step 2: Estimate the gap

```bash
# Alternatively — check git log for the last dispatcher commit
git log --oneline --since="45 minutes ago" -- agents/heartbeat/ | head -5

# Or check the most recent strategist log directory
ls -lt logs/workers/ | head -10
```

If the gap > 45 minutes (2700 seconds) — kickstart.

### Step 3: Kickstart the dispatcher

```bash
USER_ID=$(id -u)
launchctl kickstart -k "gui/${USER_ID}/com.<PROJECT_SLUG>.heartbeat-dispatcher"
```

`-k` = kill + restart (idempotent).

### Step 4: Record in autofix.log

```bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
echo "${TIMESTAMP} | RB-004 | dispatcher restarted" >> memory/autofix.log
```

If the gap is normal:

```bash
echo "${TIMESTAMP} | RB-004 | dispatcher OK, no restart needed" >> memory/autofix.log
```

### Step 5: Notify operator

```
[AUTOFIX OK] RB-004: dispatcher restarted (gap > 45 min).
```

---

## RB-005: Zombie Flood

**Trigger:** `diagnosis_type = "zombie_loop"` — too high a fraction of zombie workers in the last 2 hours.

### Step 1: Count zombies in the last 2h from worker-errors.log

```bash
# 2 hours ago timestamp
TWO_HOURS_AGO=$(date -v-2H '+%Y-%m-%d %H:%M' 2>/dev/null || date -d '2 hours ago' '+%Y-%m-%d %H:%M')

# Count zombie entries within 2h
ZOMBIE_COUNT=$(grep -E "zombie|crashed|MAX_ITER" memory/worker-errors.log 2>/dev/null | \
  awk -v cutoff="${TWO_HOURS_AGO}" '$0 >= cutoff' | wc -l | tr -d ' ')
```

### Step 2: Count total workers in 2h

```bash
# Worker dirs created in the last 2h
TOTAL_WORKERS=$(find logs/workers/ -maxdepth 1 -type d -newer /tmp/.rb005-marker 2>/dev/null | wc -l | tr -d ' ')
# Alt: count by result.md timestamp
TOTAL_WORKERS=$(find logs/workers/ -name "result.md" -newer /tmp/.rb005-cutoff 2>/dev/null | wc -l | tr -d ' ')
```

### Step 3: Compute zombie rate

```bash
if [ "${TOTAL_WORKERS}" -gt 0 ]; then
  # integer division: zombie_rate * 100
  ZOMBIE_RATE=$(( ZOMBIE_COUNT * 100 / TOTAL_WORKERS ))
else
  ZOMBIE_RATE=0
fi
```

### Step 4: If zombie_rate > 30% — flood mitigation

```bash
# 4a: Kill all worker-* tmux sessions
tmux ls 2>/dev/null | grep "^worker-" | cut -d: -f1 | while read SESSION; do
  tmux kill-session -t "${SESSION}" 2>/dev/null
done

KILLED_COUNT=$(tmux ls 2>/dev/null | grep -c "^worker-" || echo 0)
```

```
# 4b: Reset all in_progress tasks to todo
mcp__saga-mcp__task_list(status: "in_progress")
# For each task:
mcp__saga-mcp__task_update(id: <task_id>, status: "todo")
```

### Step 5: Record in autofix.log

```bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
echo "${TIMESTAMP} | RB-005 | zombie flood: ${ZOMBIE_COUNT}/${TOTAL_WORKERS} (${ZOMBIE_RATE}%) | killed: ${KILLED_COUNT} workers" >> memory/autofix.log
```

If no flood:

```bash
echo "${TIMESTAMP} | RB-005 | zombie rate OK: ${ZOMBIE_RATE}% (threshold: 30%)" >> memory/autofix.log
```

### Step 6: Notify operator

```
[AUTOFIX OK] RB-005: zombie flood detected (${ZOMBIE_RATE}%).
Killed ${KILLED_COUNT} worker sessions. All in_progress reset to todo.
Monitor next cycle.
```

---

## Escalation procedure (auto_fixable=false)

For `auth_expired` (RB-007) and `unknown` (RB-008):

### RB-007: Auth Expired

```
mcp__saga-mcp__task_create(
  epic_id: <Infra epic id>,
  title: "ESCALATE: auth expired for worker {task_slug}",
  description: "Worker {task_slug} returned 401/Unauthorized.\n\nManual re-auth required:\n1. Identify which service requires auth (from output.log)\n2. Re-auth via browser\n3. Update tokens/cookies in .env or memory/\n4. After re-auth — reset task #{saga_task_id} to todo",
  priority: "high"
)
```

### RB-008: Unknown Pattern

```
mcp__saga-mcp__task_create(
  epic_id: <Infra epic id>,
  title: "ESCALATE: unknown crash pattern — {task_slug}",
  description: "Worker crashed {crash_count} times with no known pattern.\n\nLogs: logs/workers/{task_slug}/\nDiagnosis: logs/health/diagnoses/{task_slug}-{timestamp}.json\n\nRequired: manual log analysis + decision (block/retry/fix)",
  priority: "medium"
)
```

---

## Final checklist after any runbook

1. [ ] Result recorded in `logs/health/autofix.log`
2. [ ] Tracker task status updated (todo / blocked / escalation task created)
3. [ ] Operator notified (one of: OK / FAILED / ESCALATED)
4. [ ] On SUCCESS: verify the fix worked (second health check / new worker starts)

---

## Related files

- `<REPO_URL>/agents/heartbeat/skills/self-heal-diagnose.md` — L2 diagnosis (previous step)
- `<REPO_URL>/memory/self-heal-runbook.md` — runbook catalog
- `<REPO_URL>/research/self-healing-architecture.md` — full architecture
