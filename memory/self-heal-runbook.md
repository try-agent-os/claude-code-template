# Self-Heal Runbook — AgentOS Catalog

**Updated:** YYYY-MM-DD
**Purpose:** Human-readable reference for AgentOS automatic recovery.
**System:** 3-tier self-healing (DETECT → DIAGNOSE → FIX).
**Architecture:** see `{INSTALL_ROOT}/ARCHITECTURE.md`

---

## Quick navigation

| ID | Pattern | Auto-fix | Tier |
|----|---------|----------|------|
| [RB-001](#rb-001-mcp-restart) | MCP service down | YES | launchctl/systemctl kickstart |
| [RB-002](#rb-002-max_iterations-decompose) | Task too large | YES | Decomposition |
| [RB-003](#rb-003-saga-orphan-reset) | in_progress without worker | YES | Reset to todo |
| [RB-004](#rb-004-dispatcher-gap) | Dispatcher missed wakeups | YES | kickstart dispatcher |
| [RB-005](#rb-005-zombie-flood) | Zombie workers | YES | Kill + reset |
| [RB-006](#rb-006-queue-depth) | Queue overloaded | YES | Pause scheduled checks |
| [RB-007](#rb-007-auth-expired) | Auth expired | NO | Escalate to sysadmin |
| [RB-008](#rb-008-unknown-crash) | Unknown crash | NO | Escalate to sysadmin |

---

## RB-001: MCP Restart

**Trigger:** `diagnosis_type = "mcp_down"` — curl health check returns error or timeout.

**Symptoms:**
- Worker logs `ECONNREFUSED` / `MCP tool not found` / `connection refused`
- `launchctl list | grep {PROJECT_SLUG}` shows PID = "-" for the service (mac)
- `systemctl --user status agent-os-*` shows `inactive`/`failed` (linux)

**Services and ports:**

| Service | Port | launchd label (mac) | systemd unit (linux) |
|---------|------|---------------------|----------------------|
| saga-mcp | 3851 | `com.{PROJECT_SLUG}.saga-mcp` | `agent-os-saga.service` |
| telegram-mcp | 3848 | `com.{PROJECT_SLUG}.telegram-mcp` | `agent-os-telegram.service` |
| claude-peers | 7899 | `com.{PROJECT_SLUG}.claude-peers-broker` | `agent-os-claude-peers.service` |

**Procedure (mac):**

```bash
# 1. Check status
launchctl list | grep {PROJECT_SLUG}

# 2. Identify the failed service (PID = "-" or ExitCode != 0)
# 3. Kickstart
USER_ID=$(id -u)
LABEL="com.{PROJECT_SLUG}.saga-mcp"  # replace with actual service
launchctl kickstart -k "gui/${USER_ID}/${LABEL}"

# 4. Wait 5s, verify
sleep 5
curl -s --max-time 5 http://localhost:3851/health

# 5. Log the result
echo "$(date) | RB-001 | ${LABEL} | kickstart: OK/FAILED" >> logs/health/autofix.log
```

**Procedure (linux):**

```bash
# 1. Check status
systemctl --user status agent-os-*

# 2. Restart the failed unit
UNIT="agent-os-saga"
systemctl --user restart "$UNIT"

# 3. Wait 5s, verify
sleep 5
curl -s --max-time 5 http://localhost:3851/health

# 4. Log the result
echo "$(date) | RB-001 | ${UNIT} | restart: OK/FAILED" >> logs/health/autofix.log
```

**On failure:** create a saga task in the `Infra` epic flagged `ESCALATE`, notify the operator.

**Full runbook:** `{INSTALL_ROOT}/agents/heartbeat/skills/self-heal-autofix.md` → RB-001

---

## RB-002: MAX_ITERATIONS Decompose

**Trigger:** `diagnosis_type = "too_large"` — output.log contains "max_iterations" / "Max iterations" / "iteration 30/30".

**Symptoms:**
- Worker exited but the task is not fully complete
- output.log shows progress, but work was cut off

**Procedure:**

1. Read the original task description: `mcp__saga-mcp__task_get(id: N)`
2. Read `logs/workers/{task_slug}/output.log` — determine what's already done
3. Split the remaining scope into 3–5 subtasks, ≤15 iterations each
4. Create subtasks via `mcp__saga-mcp__task_create` (same `epic_id`)
5. Block the original: `task_update(status: "blocked")` with comment "decomposed into #N1, #N2, #N3"
6. Append to `logs/health/autofix.log`
7. Notify operator with the new task IDs

**Decomposition rules:**
- Each subtask ≤ 15 iterations (conservatively: ≤ 10)
- Description starts with "Continuation of task #X after MAX_ITERATIONS"
- Include "Already done:" extracted from output.log

**Full runbook:** `{INSTALL_ROOT}/agents/heartbeat/skills/self-heal-autofix.md` → RB-002

---

## RB-003: Saga Orphan Reset

**Trigger:** `diagnosis_type = "orphan"` — task is `in_progress` in saga but no corresponding tmux worker exists.

**Symptoms:**
- `mcp__saga-mcp__task_list(status: "in_progress")` returns tasks
- `tmux ls` does not show worker sessions for those tasks

**Procedure:**

```bash
# 1. Find orphan tasks
# via task_list(status="in_progress") + tmux ls

# 2. Reset each orphan to todo
mcp__saga-mcp__task_update(id: N, status: "todo")

# 3. Log
echo "$(date) | RB-003 | task_N | orphan reset to todo" >> logs/health/autofix.log
```

**TBD:** Full automated runbook — in development.

---

## RB-004: Dispatcher Gap

**Trigger:** `diagnosis_type = "dispatcher_gap"` — dispatcher hasn't run for > 45 minutes.

**Detection:** `mtime` of `logs/workers/*/result.md` files — no new files for > 45 min.

**Procedure (mac):**

```bash
USER_ID=$(id -u)
launchctl kickstart -k "gui/${USER_ID}/com.{PROJECT_SLUG}.heartbeat-dispatcher"
launchctl list | grep heartbeat-dispatcher

echo "$(date) | RB-004 | dispatcher | kickstart" >> logs/health/autofix.log
```

**Procedure (linux):**

```bash
systemctl --user start agent-os-dispatcher.service
echo "$(date) | RB-004 | dispatcher | start" >> logs/health/autofix.log
```

**TBD:** Health-watchdog integration for automatic triggering.

---

## RB-005: Zombie Flood

**Trigger:** `diagnosis_type = "zombie_loop"` — > 30% of workers killed as zombies in the last hour.

**Symptoms:**
- `memory/worker-errors.log` contains many "zombie worker killed" entries
- `tmux ls` shows hung worker-* sessions

**Procedure:**

```bash
# 1. Kill all zombie worker sessions
tmux ls | grep "worker-" | awk -F: '{print $1}' | xargs -I{} tmux kill-session -t {}

# 2. Reset all in_progress tasks to todo
# (via task_list + task_update for each)

# 3. Log
echo "$(date) | RB-005 | zombie flood | killed N sessions, reset M tasks" >> logs/health/autofix.log
```

**TBD:** Full automated runbook — in development.

---

## RB-006: Queue Depth

**Trigger:** `diagnosis_type = "queue_depth"` — > 15 todo tasks with no progress.

**Symptoms:**
- `mcp__saga-mcp__task_list(status: "todo")` returns > 15 tasks
- Workers are not draining the queue

**Procedure:**

1. Pause `Scheduled` epic tasks
2. Prioritize user-initiated tasks (other epics)
3. Verify dispatcher is running
4. If needed — run RB-004

**TBD:** Automated runbook — in development.

---

## RB-007: Auth Expired

**Trigger:** `diagnosis_type = "auth_expired"` — worker returned 401 / Unauthorized.

**Auto-fix:** NO — manual action required.

**Procedure:**
1. Determine which service needs re-auth (from output.log)
2. Create saga task in `Infra` epic: "ESCALATE: Auth expired for {service}"
3. Notify operator with instructions for manual reauthorization
4. After re-auth — reset the original task to todo

**TBD:** Detailed runbook per service — in development.

---

## RB-008: Unknown Crash Pattern

**Trigger:** `diagnosis_type = "unknown"` — worker crashed 3+ times without a known pattern.

**Auto-fix:** NO — analysis required.

**Procedure:**
1. Create saga task in `Infra` epic: "ESCALATE: Unknown crash — {task_slug}"
2. Attach log path: `logs/workers/{task_slug}/`
3. Block the original task pending investigation
4. Notify operator

**TBD:** Detailed runbook — in development.

---

## Logs and monitoring

| File | Contents |
|------|----------|
| `logs/health/autofix.log` | All autofix actions with timestamp and result |
| `logs/health/diagnoses/` | JSON diagnoses from L2 (self-heal-diagnose) |
| `logs/health/YYYY-MM-DD-HH.json` | Hourly health snapshots |
| `memory/worker-errors.log` | Worker crash history |

---

## Escalation ladder

```
Tier 1 (auto):       Autofix (RB-001..RB-006) — silent if SUCCESS
     ↓ if FAILED or auto_fixable = false
Tier 2 (saga task):  ESCALATE task in `Infra` epic + notify operator
     ↓ if not picked up within 2h
Tier 3 (Telegram):   Alert operator with the diagnosis
     ↓ if no response within 1h
Tier 4 (direct):     Message the user with full context
```

---

## Related files

- `{INSTALL_ROOT}/agents/heartbeat/skills/self-heal-autofix.md` — L3 autofix skill
- `{INSTALL_ROOT}/agents/heartbeat/skills/self-heal-diagnose.md` — L2 diagnosis
- `{INSTALL_ROOT}/agents/heartbeat/skills/strategist/health-watchdog.md` — L1 detection
