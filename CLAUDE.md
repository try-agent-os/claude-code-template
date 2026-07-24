# AgentOS

> Open-source AgentOS template for Claude Code. Three-tier agent topology (sysadmin / operator / heartbeat) on top of saga-mcp + claude-peers + telegram-mcp. Deployable to a VPS in one command.

This file is **shared context** for every agent working in this repo. When Claude Code starts from a subdirectory `agents/{role}/`, the per-agent `CLAUDE.md` is loaded *in addition to* this one.

For full architecture detail: [`ARCHITECTURE.md`](ARCHITECTURE.md). For onboarding: [`README.md`](README.md).

## Default role (when launched from repo root)

If you are running without an agent-specific `CLAUDE.md` (just `claude` from the repo root), you are the **sysadmin** — system architect, infrastructure keeper. Decompose tasks, design configs, debug, refactor.

Detailed role doc: [`agents/sysadmin/CLAUDE.md`](agents/sysadmin/CLAUDE.md).

If you are running from `agents/{role}/` — follow that role's `CLAUDE.md`. This file is shared context only.

## Three-tier agent topology

| Agent | Role | Lifecycle | Primary channel |
|-------|------|-----------|-----------------|
| **sysadmin** | Architecture, configs, debug, refactor | Manual (terminal) | direct user dialogue |
| **operator** | User-facing interface | tmux persistent + channel push | Telegram |
| **heartbeat** | Worker spawn layer — token-free launcher tick + supervisor + daily strategist | Dagu routines (`agent-os-dagu.service`) | task backend queue |

Each agent's role doc: `agents/{role}/CLAUDE.md`. Personality: `agents/{role}/SOUL.md`. MCP wiring: `agents/{role}/.mcp.json`.

Workers are *temporary* interactive `claude` tmux sessions. The Dagu-scheduled `routines/workers.yaml` tick (token-free bash+Python, every 5 min) picks the top pickable `todo` from the task backend and spawns one worker via `scripts/spawn-worker.sh`; `routines/worker-supervisor.yaml` (every 1 min) keeps them healthy. A worker self-finalizes by calling `/done` or `/blocked`, which sets the task's terminal status, notifies the operator, and kills its own tmux session.

## MCP servers (default bundle)

| Server | Port | Purpose |
|--------|------|---------|
| **saga-mcp** | 3851 | Task tracker (projects > epics > tasks > subtasks) |
| **claude-peers** | 7899 | Inter-agent messaging (channel push + HTTP fallback) |
| **telegram-mcp** | 3848 | Telegram bot interface (operator-only) |

All three are bundled by default; `install.sh --minimal` skips telegram-mcp.

## Tasks (saga-mcp)

Tasks live in saga-mcp (`localhost:3851`). MCP tools: `mcp__saga-mcp__*`.

Default epics (created on first install via `init-epics.sh`, IDs persisted in `memory/epic-map.json`):
- `Default` — uncategorized
- `Research`
- `Business`
- `Infra` — system / template / config work
- `Scheduled` — recurring checks

Create a task:
```
mcp__saga-mcp__task_create(
  epic_id: <id from memory/epic-map.json>,
  title: "...",
  description: "Context. Scope: steps. Criteria: how to verify.",
  priority: "high|medium|low",
  tags: ["source:user|operator|sysadmin|dispatcher|strategist|worker"]
)
```

View: `mcp__saga-mcp__tracker_dashboard(project_id: {PROJECT_ID})` or `task_list()`.

Lifecycle: `todo → in_progress → done | blocked`. Workers update status on completion.

## Repository structure

```
agents/
  sysadmin/         CLAUDE.md, SOUL.md, .mcp.json, docs/
  operator/         CLAUDE.md, SOUL.md, .mcp.json, .claude/, start.sh
  heartbeat/        CLAUDE.md, SOUL.md, .mcp.json,
                    worker-prompt-template.md, strategist.sh, hooks/, skills/
memory/
  context.md, decisions.md, learnings.md,    # current state
  patterns.md, patterns-staging.md,           # confidence-scored patterns
  people.md, contacts/,                       # CRM index
  schedule.md, check-log.md,                  # cron-like checks
  proposals/, postmortems/,                   # workflow docs
  performance.md, signals.md, opportunities.md,
  epic-map.json                               # queue epic name → id (generated)
plugins/            vendored claude-code plugins (see .claude-plugin/marketplace.json)
scripts/            worker fleet, watchdogs, queue + scheduled-check layer
systemd/            linux unit files (one per service)
launchd/            mac plists (mirror of systemd/)
examples/skills/    reference skills from a real deployment (Novo Studio)
.claude/            settings.json + hooks (project-scope)
install.sh          one-command VPS bring-up
```

## Shared principles

- **Act, don't ask.** Confirmation only for irreversible external actions.
- **Atomic changes.** One change → one commit → one verification.
- **Auto-document.** After any infrastructure change, `ARCHITECTURE.md` and `README.md` reflect current state.
- **Memory-as-files.** No DB for human-readable state. `memory/*.md` is git-tracked, agent-readable.
- **Reversibility-respected.** Reversible without confirmation. Irreversible with confirmation.

## Safety

| Action | Without confirmation | Requires confirmation | Forbidden |
|--------|----------------------|-----------------------|-----------|
| Read files in `agents/`, `memory/`, `examples/`, `plugins/` | ✓ | | |
| Edit files in `agents/`, `memory/` | ✓ | | |
| Git: `add`, `commit` | ✓ | | |
| Git: `push` | | ✓ | |
| External API (email, Telegram send, GitHub PR) | | ✓ | |
| Publish content | | ✓ | |
| Change credentials | | ✓ | |
| `rm -rf`, `sudo`, `dd if=`, `mkfs` | | | ✗ |
| Access files outside repo | | | ✗ |
| Pass credentials to subagents | | | ✗ |

## Session wrap-up

Before ending an interactive session:
1. Update `memory/context.md` if it changed
2. Record meaningful decisions in `memory/decisions.md`
3. Convert unfinished work into saga tasks via `mcp__saga-mcp__task_create`

For agent-specific behavior, see the role doc in `agents/{role}/CLAUDE.md`.
