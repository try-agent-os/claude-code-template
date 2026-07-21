---
title: Health Watchdog (L1 DETECT)
summary: Detects AgentOS system anomalies — crash_streak, zombie rate, dispatcher gap, MCP health, orphan tasks. Creates tasks in the Infra epic and notifies operator on critical anomalies.
read_when: Beginning of every strategist cycle; run first to assess system health before any business tasks.
---

# Health Watchdog Skill

**Purpose:** Detect AgentOS system anomalies (Level 1: DETECT). Runs at the beginning of every strategist cycle.

**Sources:** `memory/worker-errors/` (errors, rotated monthly — `YYYY-MM.log`), `memory/worker-activity/` (worker lifecycle + dispatcher_gap, rotated monthly), saga-mcp, launchd, MCP health endpoints.

NOTE: Epic IDs resolve via `memory/epic-map.json`. References like "Infra epic" mean the AgentOS infrastructure epic. launchd labels use the form `com.{PROJECT_SLUG}.<service>`.

---

## Algorithm

### Step 1: Compute crash metrics over the "since last run" window

```bash
python3 scripts/health-watchdog-window.py            # human-readable
python3 scripts/health-watchdog-window.py --json     # for the Step 6.1 snapshot
python3 scripts/health-watchdog-window.py --log-line # the line for watchdog.log (Step 7)
```

Exit code: `0` — no anomaly, `1` — anomaly (go to Step 6), `2` — **data-integrity ALARM**
(the current month's log is missing/empty while the previous month's is not). On `2` the
metrics below do **not** mean "healthy" — they were never computed; fix the data source and
do not write OK to watchdog.log.

**The window is "events since the previous watchdog run", not wall-clock.** It used to be a
hardcoded "last 2 hours" — a constant chosen when the caller fired every 30 min. Once the
strategist moved to a daily schedule (`routines/strategist.yaml`), that window only ever
covered the two quiet hours before the run, so the metric became vacuous **by construction**:
crashes happened outside it and were discarded as "stale" while the log reported `crash_rate=0`
run after run. The lower bound now comes from the timestamp of the last line in
`logs/health/watchdog.log` — the window self-tunes to the real cadence and survives the next
schedule change (no line → 24h fallback, `source=fallback` in the output).

**Paths are absolute against the main checkout** (`REPO_ROOT`, defaults to the parent of the
script's directory), not relative to cwd. The strategist may run from a git worktree while
`memory/worker-errors/*.log` are gitignored — if an older month was committed before that rule
and the current one was not, the directory looks populated, the current month is simply absent,
no file-not-found is raised, and the metrics compute to zero in silence. The script reads the
main checkout and alarms on exactly that gap ("zero is always an alarm").

The script groups worker-errors lines by `task_slug` and counts over the window:
`total_workers` (starts from worker-activity), `crashed`, `zombie`, `max_iter`, `crash_rate`,
`zombie_rate`, `max_iter_rate`, and `crash_streak` per slug (consecutive crash/zombie;
`auto-blocked` breaks the streak — it is an intervention). Monthly rotation and windows that
straddle a month boundary are handled automatically. To replay the past — `--since`/`--now`:

```bash
python3 scripts/health-watchdog-window.py --since 2026-01-13T00:00 --now 2026-01-15T00:00
# STREAK <slug> = 3 / ANOMALY crash_streak = 3 -> <slug> (exit 1)
```

**For dispatcher_gap:** use `memory/worker-activity/$(date +%Y-%m).log` (NOT worker-errors).
Find the latest `dispatcher_start` line — that's the timestamp of the most recent successful dispatcher run.
worker-errors only contains failures and isn't updated for successful cycles — it's wrong for gap detection.
If the latest line may sit in the previous month, also `tail` the previous month's file.

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
launchctl list | grep {PROJECT_SLUG}
```

For each service check the "Status" column (first column):
- `0` = running normally
- nonzero = error on last start
- missing = not loaded

Key services: `com.{PROJECT_SLUG}.heartbeat-dispatcher`, `com.{PROJECT_SLUG}.strategist`, `com.{PROJECT_SLUG}.saga-mcp`, `com.{PROJECT_SLUG}.telegram-mcp`, `com.{PROJECT_SLUG}.claude-peers`.

### Step 4: Check MCP health

```bash
curl -s http://localhost:3851/health     # saga-mcp
curl -s http://localhost:3848/health     # telegram-mcp
curl -s http://127.0.0.1:7899/health     # claude-peers
```

HTTP 200 with body `{"status":"ok"}` (or similar) = healthy.
No response or error = MCP unavailable.

### Step 5: Compute metrics and check thresholds

The first four crash-contour metrics are computed by Step 1 — **do not recount them by eye from
a `tail`**: recounting over a hardcoded "last 2 hours" is exactly what produced a vacuous zero
run after run.

| Metric | Formula | Anomaly threshold |
|--------|---------|-------------------|
| `crash_streak[task]` | max consecutive "crashed"/"zombie" for one slug (broken by `auto-blocked`) | >= 3 |
| `max_iter_rate` | `max_iter / total_workers` over the since-last-run window | >= 0.40 (40%) |
| `crash_rate` | `(crashed + zombie) / total_workers` over the since-last-run window | >= 0.40 (40%) |
| `zombie_rate` | `zombie / total_workers` over the since-last-run window | >= 0.30 (30%) |
| `data_integrity` | exit 2 from Step 1 — month log missing/empty while the previous one is not | any ALARM |
| `dispatcher_gap` | time since last `dispatcher_start` line in `memory/worker-activity/$(date +%Y-%m).log` | > 45 min |
| `queue_depth` | `todo_count` with no new launches | > 15 |
| `saga_orphan` | `saga_orphan_count` | > 3 |

If `total_workers == 0` over the window that is NOT automatically "quiet and healthy": check
Step 1's exit code first. `2` = there is no data (fix the source), `0` with a live
worker-activity log = a genuinely quiet window, and dispatcher_gap becomes the primary indicator.

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
    "window": {"since": "<ISO of the previous run>", "hours": <float>, "source": "watchdog.log|fallback"},
    "crash_rate": <float>,
    "max_iter_rate": <float>,
    "zombie_rate": <float>,
    "total_workers": <int>,
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
- `crash_rate` >= 0.40 over the since-last-run window
- Step 1 returned exit 2 (integrity ALARM — the watchdog went blind, critical on its own)
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
- Append a line to `logs/health/watchdog.log` — take it ready-made from Step 1, do not hand-write it:

  ```bash
  mkdir -p logs/health
  python3 scripts/health-watchdog-window.py --log-line >> logs/health/watchdog.log
  ```

  ```
  <ISO datetime> | OK | window=<H>h(since <ISO>, watchdog.log) workers=<N> crash_rate=<X> max_iter_rate=<X> worst_streak=<N>(<slug>) | -
  ```

  **This line's timestamp is the input of the NEXT run** (the lower bound of its window), so it
  must be appended EVERY run, including a fully green one. A missed line loses no events — the
  window simply stretches back to the previous entry — but it breaks the readability of the cadence.

- Continue with the regular strategist algorithm

---

## Recommended actions per anomaly

| Anomaly | Recommended action |
|---------|--------------------|
| `crash_streak >= 3` | Block task in tracker (task_update status="blocked"), append cause to description. No retry. |
| `max_iter_rate >= 40%` | Inspect queue task sizes, decompose large ones. Tag a task "decompose" in Infra epic. |
| `crash_rate >= 40%` | Check MCP availability, compare with last successful runs. "diagnose" task in Infra epic. |
| `zombie_rate >= 30%` | Zombie flood — kill all worker-* tmux sessions, reset in_progress to todo. |
| `dispatcher_gap > 45 min` | Check launchd: `launchctl kickstart -k gui/$(id -u)/com.{PROJECT_SLUG}.heartbeat-dispatcher`. |
| `queue_depth > 15` | Pause scheduled tasks, reprioritize — surface only user tasks at top. |
| `saga_orphan > 3` | Run reset: for each orphan task `task_update(status: "todo")`. |
| `MCP down` | Kickstart: `launchctl kickstart -k gui/$(id -u)/com.{PROJECT_SLUG}.<service-name>`. |

---

## Related documents

- `{REPO_URL}/research/self-healing-architecture.md` — full 3-level self-healing architecture
- `{REPO_URL}/memory/worker-errors/` — source of error/crash data (rotated monthly: `YYYY-MM.log`)
- `{REPO_URL}/memory/worker-activity/` — dispatcher_start + worker lifecycle, rotated monthly (`YYYY-MM.log`)
- `{REPO_URL}/scripts/health-watchdog-window.py` — Step 1 metrics over the since-last-run window
- `{REPO_URL}/agents/heartbeat/strategist-prompt.md` — caller prompt
