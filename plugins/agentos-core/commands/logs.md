---
description: Tail logs from AgentOS systemd units
arguments: [unit-name] [lines]
allowed-tools: Bash(journalctl*)
---

# AgentOS Logs

Unit: $0 (default: all agent-os-*)
Lines: $1 (default: 50)

!`if [ -n "$0" ] && [ "$0" != "all" ]; then journalctl -u "agent-os-$0" -n "${1:-50}" --no-pager 2>&1; else journalctl -u 'agent-os-*' -n "${1:-50}" --no-pager 2>&1; fi`

## Task

Show the logs above to user. If they look normal (just systemd service-start lines, no errors/warnings), say "logs clean". If there are errors/warnings, summarize and suggest the most likely fix (e.g., "saga-mcp keeps restarting — check `/var/log/agent-os/saga-mcp-errors.log` or run /agentos:restart saga").
