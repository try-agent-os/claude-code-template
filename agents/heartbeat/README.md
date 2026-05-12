# Heartbeat — Ephemeral Dispatcher

Cron-based AgentOS dispatcher. Runs every 3 min, executes one cycle, exits. No memory between cycles — all state lives on disk.

## Launch

Cron job (installed from `start.sh` or by hand):
```bash
*/3 * * * * ${REPO_ROOT}/agents/heartbeat/dispatcher.sh >> ${REPO_ROOT}/logs/dispatcher.log 2>&1
```

## Cycle algorithm

1. Increment `heartbeat_count` in `memory/context.md`
2. Collect worker results (`worker-collector.sh`)
3. Route new tasks from saga-mcp (`mcp__saga-mcp__task_list`) → launch workers
4. Check schedule (`memory/schedule.md`)
5. Watchdog (stuck workers, lost tasks)
6. Strategist (every 10 cycles, Opus)
7. Git commit + push
8. Notify operator via claude-peers

Details: `dispatcher-prompt.md`

## Structure

```
agents/heartbeat/
  CLAUDE.md                  # Context for auto-discovery
  dispatcher.sh              # Cron entry point (atomic lock)
  dispatcher-prompt.md       # Dispatcher algorithm
  strategist-prompt.md       # Prompt for the strategist worker
  worker-launcher.sh         # Launch worker in tmux
  worker-collector.sh        # Collect worker results
  worker-prompt-template.md  # Worker prompt template
  skills/                    # Procedural skills for workers
```

## Dependencies

- Claude Code CLI (`claude`)
- tmux (for workers)
- launchd
- jq (JSON parsing)
