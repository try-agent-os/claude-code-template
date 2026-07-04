# Heartbeat — Worker Spawn Layer

Worker orchestration for AgentOS. There is **no LLM dispatcher** — orchestration is token-free (pure bash + Python) and driven by the **Dagu routines engine** (`agent-os-dagu.service`). This directory holds the worker prompt template, the strategist entry point, and the skills library that workers pull from.

## How workers get launched

Three Dagu DAGs under [`routines/`](../../routines/) drive the lifecycle:

| DAG | Schedule | Runs | What it does |
|-----|----------|------|--------------|
| `routines/workers.yaml` | every 5 min | `scripts/worker-launcher-tick.sh` | Token-free (no LLM). Picks the top pickable `todo` from the task backend, fills `worker-prompt-template.md`, spawns ONE interactive worker via `scripts/spawn-worker.sh`. |
| `routines/worker-supervisor.yaml` | every 1 min | `scripts/worker-supervisor.sh` | One consolidated supervision tick — terminal-status no-op, startup-dialog Enter, wall-clock-cap state-flip, pane-stall kill, orphan-sweep (a task `in_progress` with no live tmux session gets requeued). Single kill-authority. |
| `routines/strategist.yaml` | daily | `strategist.sh` | Spawns the strategist worker via `spawn-worker.sh`. |

## Worker model

`scripts/spawn-worker.sh` launches a REAL interactive `claude` session in a detached tmux session (`worker-<slug>`), prompt passed as a positional arg. The prompt ends with a `/goal` directive; a goal evaluator decides each turn whether the worker is done. The worker self-finalizes by calling `/done` or `/blocked` (`.claude/commands/{done,blocked}.md`), which comment on the task, set the terminal status (in_review / blocked), notify the operator via claude-peers, and kill the worker's own tmux session.

Each main-repo worker runs in its own isolated `git worktree` on branch `worker/<slug>`; `/done` fast-forward-merges it to `origin/main`. There is no `result.md` polling and no stream-json parsing.

## Structure

```
agents/heartbeat/
  CLAUDE.md                  # Context for auto-discovery
  SOUL.md                    # Personality
  strategist.sh              # Strategist entry point (spawns strategist worker)
  strategist-prompt.md       # Prompt for the strategist worker
  worker-prompt-template.md  # Worker prompt template
  hooks/                     # Lifecycle hooks
  skills/                    # Procedural skills for workers
```

## Dependencies

- Claude Code CLI (`claude`)
- tmux (for workers)
- Dagu (`agent-os-dagu.service` — the routines engine)
- jq + python3 (token-free tick logic)
