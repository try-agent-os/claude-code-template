---
title: Self-Heal Diagnose (L2 DIAGNOSE)
summary: Automatically diagnoses a failed worker — reads logs, grep-classifies the crash cause (rate_limit, mcp_down, too_large, zombie_loop, etc.), produces a JSON diagnosis under logs/health/diagnoses/.
read_when: Called by the strategist or health-watchdog when crash_streak >= 3, MAX_ITER, or zombie; root cause is needed before attempting an autofix.
---

# Skill: Self-Heal Diagnose (Level 2: DIAGNOSE)

**Purpose:** Automatically diagnose a failed worker before attempting a fix.
**Trigger:** Called by strategist or health-watchdog when an anomaly is detected (crash_streak >= 3, MAX_ITER, zombie).
**Output:** `logs/health/diagnoses/{task_slug}-{timestamp}.json` with a classified cause.

---

## Inputs

- `task_slug` — slug of the failing task (e.g. `outreach-draft-acme`)
- `saga_task_id` — task ID in the tracker (if known)
- `crash_count` — number of consecutive failures

---

## Diagnosis algorithm

### Step 1: Find the worker logs

```bash
# Find all iteration logs
ls -t logs/workers/{task_slug}/iter-*-output.txt 2>/dev/null | head -5

# If no iter logs — look for the general log
ls -t logs/workers/{task_slug}/ 2>/dev/null
cat logs/workers/{task_slug}/output.log 2>/dev/null | tail -100
```

### Step 2: Read the last 100 lines of output

```bash
cat logs/workers/{task_slug}/iter-*-output.txt 2>/dev/null | tail -100
# or, single file:
tail -100 logs/workers/{task_slug}/iter-1-output.txt 2>/dev/null
```

### Step 3: Grep patterns for classification

Run each grep, record matches:

```bash
LOGFILE="logs/workers/{task_slug}/iter-*-output.txt"

# Rate limit / API overload
grep -i "rate.limit\|429\|too many requests\|overloaded\|retry after" $LOGFILE

# Auth / token expired
grep -i "unauthorized\|401\|invalid.*token\|auth.*failed\|authentication" $LOGFILE

# MCP not found or down
grep -i "mcp.*not found\|tool.*not found\|connection refused\|ECONNREFUSED\|mcp.*unavailable\|localhost.*refused" $LOGFILE

# Task too large
grep -i "max.iter\|MAX_ITERATIONS\|maximum.*iteration\|too many.*step" $LOGFILE

# No matching task / desync
grep -i "no matching task\|queue.*empty\|no task.*found\|orphan" $LOGFILE

# Zombie / timeout
grep -i "zombie\|timeout\|killed\|timed out\|hung" $LOGFILE
```

### Step 4: Probe infrastructure (if diagnosis_type = unknown)

```bash
# launchd service status (substitute your <PROJECT_SLUG>)
launchctl list | grep <PROJECT_SLUG> | awk '{print $3, $1}'

# MCP server health (ports are deployment-specific)
curl -s --max-time 3 http://localhost:3848/health 2>&1  # telegram-mcp
curl -s --max-time 3 http://localhost:3851/health 2>&1  # saga-mcp
curl -s --max-time 3 http://127.0.0.1:7899/health 2>&1  # claude-peers
```

---

## Classification (diagnosis_type)

| Pattern matched | diagnosis_type | auto_fixable | escalation_level |
|-----------------|----------------|--------------|-----------------|
| `rate limit` / `429` / `overloaded` | `rate_limit` | true | 0 |
| `unauthorized` / `401` / `invalid token` | `auth_expired` | false | 2 |
| `MCP.*not found` / `ECONNREFUSED.*3851\|3848\|7899` | `mcp_down` | true | 1 |
| `MAX_ITERATIONS` / `max.iter` | `too_large` | true | 1 |
| `no matching task` / `queue.*empty` | `orphan` | true | 0 |
| `zombie` / `killed` + repeated | `zombie_loop` | true | 1 |
| Nothing matched | `unknown` | false | 2 |

### escalation_level values

- `0` — autofix without notification
- `1` — autofix + notify operator
- `2` — escalate to sysadmin + notify operator

---

## Step 5: Produce and write the diagnosis

### JSON format

```json
{
  "task_slug": "outreach-draft-acme",
  "saga_task_id": 143,
  "crash_count": 6,
  "timestamp": "2026-04-08T10:17:00Z",
  "diagnosis_type": "mcp_down",
  "root_cause": "MCP connection refused at localhost:3851 (saga-mcp)",
  "evidence": [
    "ECONNREFUSED at localhost:3851",
    "MCP tool saga-mcp__task_list: connection error"
  ],
  "infrastructure_healthy": false,
  "auto_fixable": true,
  "escalation_level": 1,
  "recommended_action": "RB-001: launchctl kickstart com.<PROJECT_SLUG>.saga-mcp"
}
```

### Output path

```bash
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
OUTFILE="logs/health/diagnoses/{task_slug}-${TIMESTAMP}.json"
```

Write the JSON to the file via heredoc or the Write tool.

---

## Step 6: Determine recommended_action

| diagnosis_type | recommended_action |
|----------------|-------------------|
| `rate_limit` | `WAIT: pause task 1h, retry later` |
| `auth_expired` | `ESCALATE: manual re-auth required, block task` |
| `mcp_down` | `RB-001: launchctl kickstart {failed_mcp_service}` |
| `too_large` | `RB-002: decompose task into 3-5 subtasks <= 15 iterations` |
| `orphan` | `RB-003: tracker task_update id={id} status=todo` |
| `zombie_loop` | `RB-005: kill worker tmux session + reset in_progress tasks` |
| `unknown` | `ESCALATE: full sysadmin review, attach logs` |

---

## Example output

After calling the skill:
1. File `logs/health/diagnoses/{task_slug}-{timestamp}.json` is created
2. Logged to `logs/health/diagnoses/` for audit
3. Diagnosis is returned to the caller for fix decisions

---

## Related skills

- `health-watchdog` — calls this skill on anomaly detection
- `self-heal-autofix` — next step: runs the autofix based on diagnosis_type
- `<REPO_URL>/research/self-healing-architecture.md` — full architecture (if you keep architecture docs)
