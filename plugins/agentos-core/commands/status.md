---
description: Show AgentOS systemd unit status, MCP health endpoints, and tmux operator state
allowed-tools: Bash(systemctl status*) Bash(systemctl is-active*) Bash(systemctl list-timers*) Bash(curl localhost:*) Bash(curl 127.0.0.1:*) Bash(tmux ls*) Bash(jq:*) Bash(sudo -u agent-os tmux*)
---

# AgentOS Status

## systemd units
!`systemctl is-active agent-os-saga.service agent-os-operator.service agent-os-dagu.service 2>&1`

## Service status (last 3 lines each)
!`for u in agent-os-saga agent-os-operator agent-os-dagu; do echo "── $u ──"; systemctl status "$u" --no-pager -n 3 2>&1; done`

## MCP health
- claude-peers (:7899): !`curl -fsS http://127.0.0.1:7899/health 2>&1 | head -c 200 || echo "FAIL"`
- saga-mcp (:3851):    !`curl -fsS http://localhost:3851/health 2>&1 | head -c 200 || echo "FAIL"`

## Operator tmux
!`sudo -u agent-os tmux ls 2>&1 | grep -E '^(operator|caffeinate)' || echo "no tmux"`

## Peer registration
!`curl -sf http://127.0.0.1:7899/list-peers -H 'Content-Type: application/json' -d '{"scope":"machine","cwd":"/","git_root":null}' 2>&1 | jq -r '.[] | "\(.id) \(.cwd)"' 2>&1 | head -10 || echo "broker unreachable"`

## Routines engine (worker DAGs)
!`systemctl is-active agent-os-dagu.service 2>&1; journalctl -u agent-os-dagu -n 5 --no-pager 2>&1 | tail -5`

## Task

Summarize the status above. Highlight any FAIL/inactive in red. If everything green, say "AgentOS healthy ✓ <count> peers / <units> services". If issues, suggest most likely fix (e.g., "saga-mcp inactive — try /agentos:restart saga-mcp").
