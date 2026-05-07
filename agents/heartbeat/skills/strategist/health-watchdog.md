---
title: Health Watchdog (L1 DETECT)
summary: Detects AgentOS system anomalies — crash_streak, zombie rate, dispatcher gap, MCP health, orphan tasks. Creates tasks in the Infra epic and notifies operator on critical anomalies.
read_when: Beginning of every strategist cycle; run first to assess system health before any business tasks.
---

# Health Watchdog Skill

**Purpose:** Detect AgentOS system anomalies (Level 1: DETECT). Runs at the beginning of every strategist cycle.

**Sources:** `memory/worker-errors.log` (errors), `memory/worker-activity.log` (dispatcher_gap), saga-mcp, launchd, MCP health endpoints.

NOTE: Epic IDs resolve via `memory/epic-map.json`. References like "Infra epic" mean the AgentOS infrastructure epic. launchd labels use the form `com.<PROJECT_SLUG>.<service>`.

---

## Algorithm

### Step 1: Read error and activity logs

```bash
tail -50 memory/worker-errors.log
tail -20 memory/worker-activity.log
```

Group worker-errors.log lines by `task_slug` (first field after the date). For each slug, count:
- `crash_streak` — consecutive "crashed" or "zombie" entries
- `max_iter_count` — "MAX_ITERATIONS" hits in the last 50 lines
- `zombie_count` — "zombie" hits

From all worker-errors.log lines, define a **2-hour window** (4 dispatcher cycles):
- Find lines with timestamp >= (now - 2h)
- Count: `total_workers_2h`, `crashed_2h`, `max_iter_2h`, `zombie_2h`

**For dispatcher_gap:** use `memory/worker-activity.log` (NOT worker-errors.log).
Find the latest `dispatcher_start` line — that's the timestamp of the most recent successful dispatcher run.
worker-errors.log only contains failures and isn't updated for successful cycles — it's wrong for gap detection.

### Step 2: Check the tracker queue

```
mcp__saga-mcp__task_list(project_id: 1, status: "in_progress")
mcp__saga-mcp__task_list(project_id: 1, status: "todo")
```

Count:
- `in_progress_count` — currently running tasks
- `todo_count` — pending tasks
- `saga_orphan_count` — in_progress tasks not updated in > 2h (updated_at field)

### Step 3: Check launchd

```bash
launchctl list | grep <PROJECT_SLUG>
```

For each service check the "Status" column (first column):
- `0` = running normally
- nonzero = error on last start
- missing = not loaded

Key services: `com.<PROJECT_SLUG>.heartbeat-dispatcher`, `com.<PROJECT_SLUG>.strategist`, `com.<PROJECT_SLUG>.saga-mcp`, `com.<PROJECT_SLUG>.telegram-mcp`, `com.<PROJECT_SLUG>.claude-peers`.

### Step 4: Check MCP health

```bash
curl -s http://localhost:3851/health     # saga-mcp
curl -s http://localhost:3848/health     # telegram-mcp
curl -s http://127.0.0.1:7899/health     # claude-peers
```

HTTP 200 with body `{"status":"ok"}` (or similar) = healthy.
No response or error = MCP unavailable.

### Step 5: Compute metrics and check thresholds

| Metric | Formula | Anomaly threshold |
|--------|---------|-------------------|
| `crash_streak[task]` | max consecutive "crashed"/"zombie" for one slug | >= 3 |
| `max_iter_rate` | `max_iter_2h / total_workers_2h` | >= 0.40 (40%) |
| `crash_rate` | `(crashed_2h + zombie_2h) / total_workers_2h` | >= 0.40 (40%) |
| `zombie_rate` | `zombie_2h / total_workers_2h` | >= 0.30 (30%) |
| `dispatcher_gap` | time since last `dispatcher_start` line in `memory/worker-activity.log` | > 45 min |
| `queue_depth` | `todo_count` with no new launches | > 15 |
| `saga_orphan` | `saga_orphan_count` | > 3 |

If `total_workers_2h == 0` — dispatcher_gap becomes the primary indicator.

### Step 6: When an anomaly is detected

**6.1. Write a health snapshot:**

```bash
mkdir -p logs/health
```

Create or update `logs/health/$(date +%Y-%m-%d-%H).json`:

```json
{
  "timestamp": "<ISO datetime>",
  "heartbeat_count": <N>,
  "metrics": {
    "crash_rate_2h": <float>,
    "max_iter_rate_2h": <float>,
    "zombie_rate_2h": <float>,
    "total_workers_2h": <int>,
    "dispatcher_gap_min": <int>,
    "todo_count": <int>,
    "in_progress_count": <int>,
    "saga_orphan_count": <int>
  },
  "anomalies": [
    {"type": "<anomaly>", "value": <value>, "threshold": <threshold>, "details": "<slug or service>"}
  ],
  "infrastructure": {
    "saga_mcp": "<ok|down>",
    "telegram_mcp": "<ok|down>",
    "claude_peers": "<ok|down>",
    "launchd_errors": ["<service>"]
  }
}
```

**6.2. Create a task in the tracker (Infra epic):**

```
mcp__saga-mcp__task_create(
  project_id: 1,
  epic_id: <Infra epic id>,
  title: "Self-heal: <anomaly type> — <short description>",
  description: "**Anomaly:** <metric> = <value> (threshold: <threshold>)\n\n**Data:** <details from log>\n\n**Time:** <timestamp>\n\n**Recommended action:** <from table below>",
  priority: "high"
)
```

**6.3. Notify operator (only on critical anomaly):**

Critical = any of:
- `crash_streak` >= 3 for any task_slug
- `crash_rate_2h` >= 0.40
- Any MCP service unavailable
- `dispatcher_gap` > 45 min

```
list_peers(scope: "machine")
```

→ find peer with `cwd` containing "operator"
→

```
send_message(to_id: <operator_peer_id>, message: "[HEALTH ALERT] <anomaly type>\nSymptom: <metric> = <value>\nTask: tracker #<task_id>\nProposed: <action>")
```

If the operator peer isn't found — skip the notification; the tracker task is enough.

### Step 7: When no anomalies

If all metrics are normal:
- Do NOT create a tracker task
- Do NOT notify operator
- Append a brief line to `logs/health/watchdog.log`:

  ```
  <ISO datetime> | OK | workers_2h=<N> crash_rate=<X>% max_iter_rate=<X>%
  ```

- Continue with the regular strategist algorithm

---

## Recommended actions per anomaly

| Anomaly | Recommended action |
|---------|--------------------|
| `crash_streak >= 3` | Block task in tracker (task_update status="blocked"), append cause to description. No retry. |
| `max_iter_rate >= 40%` | Inspect queue task sizes, decompose large ones. Tag a task "decompose" in Infra epic. |
| `crash_rate >= 40%` | Check MCP availability, compare with last successful runs. "diagnose" task in Infra epic. |
| `zombie_rate >= 30%` | Zombie flood — kill all worker-* tmux sessions, reset in_progress to todo. |
| `dispatcher_gap > 45 min` | Check launchd: `launchctl kickstart -k gui/$(id -u)/com.<PROJECT_SLUG>.heartbeat-dispatcher`. |
| `queue_depth > 15` | Pause scheduled tasks, reprioritize — surface only user tasks at top. |
| `saga_orphan > 3` | Run reset: for each orphan task `task_update(status: "todo")`. |
| `MCP down` | Kickstart: `launchctl kickstart -k gui/$(id -u)/com.<PROJECT_SLUG>.<service-name>`. |

---

## Related documents

- `<REPO_URL>/research/self-healing-architecture.md` — full 3-level self-healing architecture
- `<REPO_URL>/memory/worker-errors.log` — source of error/crash data
- `<REPO_URL>/memory/worker-activity.log` — dispatcher_start records for the dispatcher_gap metric
- `<REPO_URL>/agents/heartbeat/strategist-prompt.md` — caller prompt
