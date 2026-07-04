# Heartbeat — Worker Spawn Layer

This directory backs the AgentOS worker spawn layer. There is **no LLM dispatcher**: worker orchestration is token-free (pure bash + Python) and scheduled by the **Dagu routines engine** (`agent-os-dagu.service`). This file is context for the strategist worker and for anyone editing the orchestration.

Full project context: [`CLAUDE.md`](../../CLAUDE.md) (repo root).

> **Pre-flight configuration.** Set your values during initial setup:
> - `{INSTALL_ROOT}` — root of the AgentOS repo
> - epic IDs — auto-resolved from `memory/epic-map.json` at runtime (built on first install by `init-epics.sh`; default epics: Default / Research / Business / Infra / Scheduled)
> - `{PROJECT_ID}` — project ID in saga-mcp
> - Ports: `3851` (saga-mcp), `7899` (claude-peers broker) — defaults are aligned across all agents

## Orchestration (token-free, Dagu-driven)

Three DAGs under [`routines/`](../../routines/) run the lifecycle — none of them call an LLM to route or collect:

1. `routines/workers.yaml` (every 5 min) → `scripts/worker-launcher-tick.sh`: picks the top pickable `todo` from the task backend, fills `worker-prompt-template.md`, spawns ONE interactive worker via `scripts/spawn-worker.sh`, marks the task `in_progress`.
2. `routines/worker-supervisor.yaml` (every 1 min) → `scripts/worker-supervisor.sh`: one consolidated supervision tick (terminal-status no-op, startup-dialog Enter, wall-clock-cap state-flip, pane-stall kill, orphan-sweep — a task `in_progress` with no live tmux session gets requeued). Single kill-authority.
3. `routines/strategist.yaml` (daily) → `strategist.sh`: spawns the strategist worker via `spawn-worker.sh`.

Workers self-report: each worker calls `/done` or `/blocked` to set its terminal status, notify the operator via claude-peers, and kill its own tmux session. There is no result-file polling and no stream-json parsing.

## Worker routing

`worker-launcher-tick.sh` fills `worker-prompt-template.md` for the picked task. The base template ships without specialized sub-agents: all workers run as generic (only the root CLAUDE.md is loaded). If your system gains specialized agents (researcher, outreacher, etc.), add them under `agents/` and wire up routing in the tick.

## Skills Library (for workers)

Each skill file under `skills/` has YAML frontmatter with a `read_when` field. The worker matches the task text against every skill's `read_when` and reads the relevant ones.

Bundled skills (12 generic): `self-improvement-loop`, `self-upgrade-scan`, `self-heal-{diagnose,autofix}`, `memory-search`, `event-correlation`, plus 6 strategist skills under `skills/strategist/` (`signal-analysis`, `blocker-resolution`, `business-analysis`, `self-improvement`, `worker-results-analysis`, `health-watchdog`).

Skill index: [`skills/README.md`](skills/README.md). Add domain-specific skills by dropping a markdown file with `read_when` frontmatter into `skills/`. Reference patterns from a real deployment live in [`examples/skills/`](../../examples/skills/) (Novo Studio specifics — copy-adapt as needed).

## Connectors (for reference — workers use these directly)

Connectors are optional — workers use whichever ones are configured in your system:

| Service | Tool prefix |
|---------|------------|
| Google Calendar | `mcp__claude_ai_Google_Calendar__*` |
| Gmail | `mcp__claude_ai_Gmail__*` |
| Google Docs | `mcp__claude_ai_Google_Docs__GOOGLEDOCS_*` |
| Google Sheets | `mcp__claude_ai_Google_Sheets__GOOGLESHEETS_*` |
| Telegram bot | `mcp__telegram__*` |
| Saga (task tracker) | `mcp__saga-mcp__*` |
| Claude peers (inter-agent) | HTTP API on `localhost:7899` (curl) |

## Anti-patterns (FORBIDDEN)

- Adding an LLM back into the launcher/supervisor tick — orchestration is token-free by design
- Giving anything other than the supervisor tick authority to kill workers (single kill-authority)
- Polling result files or parsing stream-json — workers self-report via `/done` / `/blocked`
- Launching more than one worker per launcher tick
