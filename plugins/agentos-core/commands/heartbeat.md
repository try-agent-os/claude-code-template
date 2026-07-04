---
description: Show Dagu routines engine recent worker activity (last DAG runs)
allowed-tools: Bash(systemctl*) Bash(journalctl*) Bash(ls:*) Bash(cat:*)
---

# AgentOS Heartbeat

Routines engine status:
!`systemctl status agent-os-dagu --no-pager -n 5 2>&1 | head -10`

Recent routines-engine output (worker launcher / supervisor / strategist DAGs):
!`journalctl -u agent-os-dagu -n 40 --no-pager 2>&1 | tail -40`

## Task

Show the user whether the Dagu routines engine (`agent-os-dagu.service`) is active and what the worker DAGs have been doing recently — `routines/workers.yaml` (launcher, every 5 min), `routines/worker-supervisor.yaml` (supervision, every 1 min), `routines/strategist.yaml` (daily). If `agent-os-dagu` is inactive/failed, suggest `/agentos:restart agent-os-dagu` to bring the worker orchestration back.
