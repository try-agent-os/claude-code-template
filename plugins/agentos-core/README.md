# agentos-core

Slash commands for managing an AgentOS instance from any Claude Code session running on the host (or via SSH).

This is a meta-plugin: it ships operational `/agentos:*` commands that wrap `systemctl`, `journalctl`, `curl` health probes, and `tmux` checks for the AgentOS infrastructure managed by the systemd units shipped in `systemd/agent-os-*.service`, plus a `dagu` skill for driving the routines (cron) engine. No agents or MCP servers.

## Skills

| Skill | What it does |
|---|---|
| `dagu` | Full CLI control over the Dagu routines engine (`agent-os-dagu.service`): start/stop/retry DAG runs, view status/history, validate `routines/*.yaml` before deploy, list genuine (recent) failures. |

## Commands

| Command | What it does |
|---|---|
| `/agentos:status` | systemd unit status + MCP health (claude-peers :7899, saga-mcp :3851) + operator tmux + peer registry + dispatcher next fire |
| `/agentos:restart [unit]` | Restart one or all of: `agent-os-saga`, `agent-os-operator`, `agent-os-dispatcher.timer`. Default `all` does them in dependency order. **Disabled from auto-invocation** — must be called explicitly. |
| `/agentos:verify` | Runs `/opt/agent-os/claude/scripts/verify.sh` (15-check dashboard) and summarizes pass/fail. Falls back to inline checks if verify.sh missing. |
| `/agentos:logs [unit] [lines]` | Tail journalctl logs. Defaults: all `agent-os-*` units, 50 lines. |
| `/agentos:peers` | List peers registered with the claude-peers broker; flags stale (>5 min) entries. |
| `/agentos:heartbeat` | Dispatcher next fire + last 5 cycles' journalctl output. |

## Usage examples

```
# Are we healthy?
/agentos:status

# saga-mcp died, restart everything
/agentos:restart

# Just bounce the operator (e.g., after editing agents/operator/CLAUDE.md)
/agentos:restart operator

# What did the dispatcher do last hour?
/agentos:heartbeat

# Show me errors from operator the last 200 lines
/agentos:logs operator 200
```

## Assumptions

- Linux host with systemd; the 3 AgentOS units (`agent-os-saga.service`, `agent-os-operator.service`, `agent-os-dispatcher.timer`) are installed and managed via `install.sh`.
- claude-peers broker listens on `127.0.0.1:7899`; saga-mcp on `localhost:3851`. Both started by the `agent-os-operator` and `agent-os-saga` units respectively.
- Operator runs in a `tmux` session called `operator` under the `agent-os` system user; the calling Claude session has `sudo -u agent-os tmux …` permission for read-only listing.
- `verify.sh` at `/opt/agent-os/claude/scripts/verify.sh` is shipped by `install.sh` (T07). `/agentos:verify` falls back to inline minimal checks if missing.

## Not yet covered

- `agent-os-claude-peers.service` — claude-peers is a stdio MCP plugin spawned per session by Claude Code itself, not a long-running daemon. No separate systemd unit.
- macOS launchd equivalents (`com.novostudio.*.plist`) — see `launchd/` in template root; these commands assume systemd. A future iteration could detect platform and route to `launchctl`.
