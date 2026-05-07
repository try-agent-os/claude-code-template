---
description: Restart one or all AgentOS systemd units
arguments: [service-name]
disable-model-invocation: true
allowed-tools: Bash(systemctl restart*) Bash(systemctl is-active*) Bash(sudo systemctl*) Bash(journalctl*)
---

# AgentOS Restart

Service to restart: $0 (default: all)

Currently running:
!`systemctl is-active agent-os-saga agent-os-operator agent-os-dispatcher.timer 2>&1`

## Task

If $0 is empty or "all", restart all 3 systemd units in correct order:
1. agent-os-saga.service (broker first — saga-mcp tracker daemon)
2. agent-os-operator.service (depends on saga; will respawn the tmux session and re-register peer)
3. agent-os-dispatcher.timer (re-arm the heartbeat schedule)

Use `sudo systemctl restart <unit>` for each. Wait 2 seconds between, verify is-active after each.

If $0 names a specific unit, restart only that one + dependents (e.g., restarting agent-os-saga requires restarting agent-os-operator since it depends on saga-mcp).

After restart, run /agentos:status to verify green.

If restart fails, report `journalctl -u <unit> -n 30 --no-pager` for diagnosis.
