---
description: Show heartbeat dispatcher recent activity (last 5 cycles)
allowed-tools: Bash(systemctl*) Bash(journalctl*) Bash(ls:*) Bash(cat:*)
---

# AgentOS Heartbeat

Dispatcher next scheduled fire:
!`systemctl list-timers agent-os-dispatcher.timer --no-pager 2>&1 | head -5`

Last 5 dispatcher runs:
!`journalctl -u agent-os-dispatcher.service -n 30 --no-pager 2>&1 | tail -30`

## Task

Show user when the dispatcher last ran, when next fire is, and any errors in the last 5 cycles. If dispatcher hasn't run in > 2× the configured interval, suggest `/agentos:restart dispatcher.timer` to re-arm.
