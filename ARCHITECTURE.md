# AgentOS Architecture

> **Reference document.** This is the architecture of the AgentOS template, not of any specific deployment. Placeholders such as `{PROJECT_NAME}`, `{PROJECT_SLUG}`, `{INSTALL_ROOT}`, `{INSTALL_ROOT}`, `{INSTALL_ROOT}` and `{TIMEZONE}` are substituted by `install.sh` when the template is bootstrapped into a real project.

## Overview

AgentOS is a system of autonomous AI agents that manage a `{PROJECT_NAME}` workspace on the user's machine. Agents run inside Claude Code sessions (persistent tmux or ephemeral launchd/systemd jobs), communicate through MCP servers, and execute tasks pulled from a queue.

```
┌─────────────────────────────────────────────────────────────┐
│                        AgentOS                              │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌─────────────┐  ┌────────┐  │
│  │ sysadmin │  │ operator │  │  heartbeat  │  │  saga  │  │
│  │(terminal)│  │(telegram)│  │(launchd/eph │  │  dash  │  │
│  │  manual  │  │ channel  │  │  eral) 3min │  │ board  │  │
│  └────┬─────┘  └────┬─────┘  └──────┬──────┘  └───┬────┘  │
│       │             │               │              │       │
│  ┌────┴─────────────┴───────────────┴──────────────┴────┐  │
│  │              MCP servers (SSE/stdio)                  │  │
│  │                                                      │  │
│  │  telegram-mcp (3848/launchd)  claude-peers (7899/launchd) │  │
│  │  Telegram bot+tools           peer discovery+messaging   │  │
│  │  saga-mcp   (3851/launchd)                                │  │
│  │  task broker: projects/epics/tasks                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              workers (ephemeral tmux)                 │   │
│  │  worker-task-001  worker-task-002  ...                │   │
│  │  strategist (Opus, every ~6h)                         │   │
│  │  one task to completion, ephemeral                    │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

Port numbers (3848, 3851, 7899, 7902) are defaults and can be overridden via env vars (e.g. `TELEGRAM_MCP_PORT`, `SAGA_MCP_PORT`, `CLAUDE_PEERS_PORT`).

## Components

### Agents (Claude Code sessions)

| Session | Role | Trigger | System prompt |
|--------|------|---------|---------------|
| `sysadmin` | System maintenance, architecture changes | Manual (terminal) | `agents/sysadmin/CLAUDE.md` |
| `operator` | Telegram interface to the user | Channel push from telegram-mcp | `agents/operator/CLAUDE.md` |
| `heartbeat` | Ephemeral dispatcher (launchd), spawns workers | launchd every 3 min → `dispatcher.sh` → `claude -p` | `agents/heartbeat/CLAUDE.md` + `dispatcher-prompt.md` |
| `saga-dashboard` | Read-only board on top of saga-mcp tasks | Manual / scheduled | `agents/saga-dashboard/CLAUDE.md` |

### How role separation works

Each agent starts from `agents/{role}/` via `tmux -c`. Claude Code auto-discovery loads:
1. `agents/{role}/CLAUDE.md` — role-specific instructions
2. `CLAUDE.md` (repo root) — shared context (project, structure, memory)

The root `CLAUDE.md` contains shared context plus a default "system architect" role (active only when no agent-specific `CLAUDE.md` exists).

`--add-dir` extends the write scope to specific directories (principle of least privilege):

```bash
# Dispatcher — ephemeral, started by launchd
cd {INSTALL_ROOT}/agents/heartbeat
claude -p "$(cat dispatcher-prompt.md)" \
  --dangerously-skip-permissions \
  --add-dir {INSTALL_ROOT}/memory \
  --add-dir {INSTALL_ROOT}/agents \
  --model "${DEFAULT_MODEL:-claude-sonnet-4-6}"

# Sysadmin — full repo access
tmux new-session -d -s sysadmin \
  -c {INSTALL_ROOT}/agents/sysadmin \
  'claude --dangerously-skip-permissions \
    --add-dir {INSTALL_ROOT}'
```

**Per-agent `--add-dir` matrix:**

| Agent | --add-dir (write scope) |
|-------|------------------------|
| sysadmin | `{INSTALL_ROOT}` (full access) |
| heartbeat (dispatcher) | `memory/`, `agents/` |
| workers | `memory/`, `agents/`, plus any project-specific dirs declared in `worker-launcher.sh` |
| operator | `memory/`, `agents/`, plus any project-specific dirs |
| saga-dashboard | `memory/` (read-mostly) |

### MCP servers

| Server | Port | Transport | Process | Location | Purpose |
|--------|------|-----------|---------|----------|---------|
| `telegram-mcp` | 3848 | SSE | launchd / systemd | `{INSTALL_ROOT}/telegram-mcp/` | Telegram bot (grammY) + MCP tools + SQLite history |
| `claude-peers` | 7899 | stdio + broker | launchd / systemd (broker) | `{INSTALL_ROOT}/claude-peers-mcp/` | Peer discovery, inter-agent messaging, channel push |
| `saga-mcp` | 3851 | SSE | launchd / systemd | `{INSTALL_ROOT}/saga-mcp/` | Task broker: Projects/Epics/Tasks/Dependencies, SQLite WAL |

All ports are defaults — override via env vars (`TELEGRAM_MCP_PORT`, `CLAUDE_PEERS_PORT`, `SAGA_MCP_PORT`).

**claude-peers MCP** is registered at the user level (`claude mcp add --scope user`), so it's available in every session including `claude -p` (dispatcher, workers). The broker and telegram-mcp run under launchd/systemd (see below) and are always online.

**claude-peers HTTP fallback for ephemeral processes.** Workers spawned by `claude -p` run for a single iteration loop and exit. Stdio MCP transports require a long-lived parent process, so ephemeral workers cannot reliably hold a peer connection. The broker therefore exposes an HTTP endpoint (`http://127.0.0.1:7899/messages`) which workers POST to directly, bypassing the stdio handshake. This allows a worker to deliver progress notifications to `operator` without keeping a persistent MCP transport alive.

**saga-mcp** is a task broker with a Projects > Epics > Tasks > Subtasks hierarchy. Defaults:
- HTTP/SSE transport (Express, default port 3851) — single process, all agents connect to it
- WAL-mode SQLite
- DB file: `agentOS.db` in the repo directory

**Registering saga-mcp** in `.mcp.json` at the repo root (visible to all agents) and in `agents/operator/.mcp.json`, `agents/heartbeat/.mcp.json`, `agents/sysadmin/.mcp.json`.

**Default Epic layout:** the template ships with five named epics — `Default`, `Research`, `Business`, `Infra`, `Scheduled`. Their numeric IDs are assigned at runtime by saga-mcp. Agents resolve names to IDs via `memory/epic-map.json`, which is regenerated by `scripts/refresh-epic-map.sh` after the first dashboard call.

### MCP `maxResultSizeChars` (Claude Code v2.1.91+)

Claude Code v2.1.91 introduced the `_meta["anthropic/maxResultSizeChars"]` annotation in MCP tool results. This lets an MCP server signal the client a larger acceptable result size (up to 500K chars instead of the default ~50K).

**Why it matters:** without this annotation, workers receive truncated responses from MCP tools — particularly large DB schemas, dashboards, and exports.

**Pattern (saga-mcp):**

```typescript
// CallToolRequestSchema handler — every tool result carries the annotation
return {
  _meta: { 'anthropic/maxResultSizeChars': 500000 },
  content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
};
```

**Pattern (third-party MCP via npx, e.g. patched at runtime):**

```javascript
// Wrapper around toolHandler in createMcpServer()
const toolResult = await toolHandler(args, client, extraArgs);
return { ...toolResult, _meta: { 'anthropic/maxResultSizeChars': 500000 } };
```

**Caveat:** patches inside `~/.npm/_npx/<hash>/` are temporary. When the upstream package is updated (`npx <pkg>@latest`), npx creates a new cache directory and the patch must be reapplied. The long-term fix is a fork or upstream PR.

### Workers (ephemeral tmux sessions)

The dispatcher pulls tasks from **saga-mcp** and launches a worker per task:

```
launchd → dispatcher.sh → claude -p (dispatcher-prompt.md)
                            ↓
              saga-mcp task_list(status: "todo")
                            ↓
                       worker-launcher.sh → tmux worker → claude -p "prompt"
                                                              ↓
                                                        logs/workers/{id}/result.md
                                                        saga-mcp task_update(done)
                                                              ↓
         dispatcher (next cycle) → worker-collector.sh → saga-mcp update
```

- Up to 5 workers in parallel (configurable)
- 20 iterations / 30 min cap per worker
- Result lives in `logs/workers/{id}/result.md` (NOT in `.claude/` — Claude treats that path as sensitive)
- Heartbeat file `logs/workers/{id}/heartbeat` is touched before/after every Claude call

#### Worker iteration loop

A worker is `claude -p` invoked in a loop until either:
1. It writes `result.md` with frontmatter `status: done` or `status: blocked`
2. The 20-iteration / 30-minute cap is hit
3. The heartbeat file goes stale (worker is killed by the dispatcher next cycle)

`result.md` frontmatter contract:

```yaml
---
status: done | blocked | failed
task_id: <saga task id>
iterations: <int>
duration_seconds: <int>
cost_usd: <float>            # parsed from stream-json
model: <model id>
---
<freeform markdown body — what the worker did, decisions, pointers>
```

#### Stream-JSON pipeline

Workers run with `--output-format stream-json` and the stream is piped through `tee` for archival and through a parser for live telemetry:

```
claude -p ...
  --output-format stream-json
  --include-partial-messages
  | tee logs/workers/{id}/stream.jsonl
  | scripts/parse-stream.py
  | tee -a logs/workers/{id}/parsed.log
```

The parser extracts cost, token counts, tool calls, and subagent spawns into `logs/workers/{id}/telemetry.json`, which is consumed by `scripts/cost-dashboard.sh` and the strategist's reflexion skill.

### Specialised workers

Workers can be launched with the identity of a specialised agent. The dispatcher picks the agent type from task tags / keywords and passes it to `worker-launcher.sh` as the 5th argument.

When an `agent_type` is supplied, `worker-launcher.sh` adds `--add-dir agents/{agent_type}` so Claude Code auto-discovery can pull in:
- `agents/{agent_type}/CLAUDE.md` — role and rules
- `agents/{agent_type}/skills/` — procedural skills available to that role

Each specialised agent evolves independently: its own skills directory, its own role file, its own update cadence, without touching the other agents.

### Strategist worker

A special worker type. Spawned by the dispatcher every N cycles (default: every ~6 hours). Model: Opus (configurable via `${STRATEGIST_MODEL:-claude-opus-4-6}`). Ephemeral.

**Purpose:** thinks on top of the data the day-to-day workers gathered. Generates proactive tasks. Surfaces signals, patterns, and blockers.

**Dispatcher / strategist boundary:**
- Dispatcher = mechanics (if/then with no content analysis): stale workers, blocked-task aging, schedule compliance.
- Strategist = intelligence (requires reading and analysis): signals, patterns, business insights, blocker resolution.

**Strategist skills** (`agents/heartbeat/skills/strategist/`):

| Skill | Purpose |
|-------|---------|
| `signal-analysis.md` | Group signals, score them, convert into opportunities |
| `blocker-resolution.md` | Self-unblock protocol: route around → decompose → escalate to user |
| `self-improvement.md` | Confidence decay, promote patterns into CLAUDE.md, meta-review |
| `worker-results-analysis.md` | Reflexion: scan `logs/workers/*/result.md` for patterns of success/failure |

## File layout

### Template repo (`{INSTALL_ROOT}`)

```
CLAUDE.md                      # Root instructions (shared context + default role)
ARCHITECTURE.md                # This file
CHANGELOG.md                   # Change log
README.md
LICENSE
.mcp.json                      # saga-mcp (all agents via project root)
agents/operator/.mcp.json      # Telegram + saga-mcp (operator only)
.env                           # Secrets (gitignored)

agents/
  heartbeat/
    CLAUDE.md                  # Dispatcher context (auto-discovery)
    dispatcher.sh              # Entry point for launchd (atomic lock + claude -p)
    dispatcher-prompt.md       # Dispatcher algorithm (incl. agent routing table)
    strategist-prompt.md       # Strategist worker prompt
    worker-launcher.sh         # Spawns a worker in tmux (arg 5: agent-type)
    worker-collector.sh        # Collects worker results
    worker-prompt-template.md  # Prompt template for workers
    skills/                    # Procedural skills available to workers (shared)
      strategist/              # Analytical skills for the strategist worker
        signal-analysis.md
        blocker-resolution.md
        self-improvement.md
        worker-results-analysis.md
    hooks/                     # Hook scripts (see Hooks section below)
      boot.sh
      enrich-prompt.sh
      guard-bash.sh
      log-action.sh
      log-subagent.sh
      session-end.sh
      compress-tool-output.sh
  operator/
    CLAUDE.md                  # Operator instructions (telegram MCP tools)
    .mcp.json                  # Telegram SSE (operator only)
    start.sh                   # Idempotent start/restart for operator
  sysadmin/
    CLAUDE.md                  # Sysadmin instructions (terminal)
  saga-dashboard/
    CLAUDE.md                  # Read-only dashboard role

memory/
  queue.md                     # Task queue for dispatcher/workers
  context.md                   # Current situation, heartbeat_count
  decisions.md                 # Architectural decisions with reasons
  learnings.md                 # Insights and patterns
  signals.md                   # Signals from scanners
  opportunities.md             # Opportunities with scoring
  schedule.md                  # Recurring-check schedule
  check-log.md                 # Log of recent checks
  patterns.md                  # Patterns with confidence decay
  performance.md               # Task trajectory log
  epic-map.json                # Name → ID lookup for saga-mcp epics
  postmortems/                 # One file per incident
  proposals/                   # Self-improvement proposals awaiting review

scripts/
  cost-dashboard.sh            # Cost telemetry summary
  token-report.py              # Token usage report from stream-json logs
  worker-analytics.sh          # Per-worker stats
  refresh-epic-map.sh          # Rebuild memory/epic-map.json from saga-mcp

examples/                      # Example skills and configurations
plugins/                       # Plugin slots (Claude Code plugins)
launchd/                       # macOS launchd plist templates
systemd/                       # Linux systemd unit templates
logs/                          # Dispatcher and worker logs (gitignored)

.claude/
  workers/                     # Active workers
  workers-done/                # Completed worker artefacts
  skills/                      # Claude Code skills (project-level)
  settings.json                # Hooks + permissions
```

### AgentOS workspace (`{INSTALL_ROOT}`)

```
telegram-mcp/                  # Telegram bot + MCP (SSE, default port 3848, launchd)
  src/
    index.ts                   # Express SSE server + grammY bot
    bot.ts                     # grammY message handler
    db.ts                      # SQLite + FTS5 full-text search
    access.ts                  # Allowlist/pending/deny policy
    tools.ts                   # MCP tool definitions
  access.json                  # Access policy (user allowlist)
  messages.db                  # Message history (gitignored)

claude-peers-mcp/              # Peer discovery + messaging
  broker.ts                    # Shared broker daemon (Bun HTTP, launchd)
  server.ts                    # stdio MCP server (per session)
  cli.ts                       # CLI utility

saga-mcp/                      # Task broker (SSE, default port 3851)
  src/
    index.ts                   # SSE server, MCP tool surface
  agentOS.db                   # Tasks DB (WAL mode)
```

## Bringing the system up

### Boot order (it matters)

1. `claude-peers broker` and `telegram-mcp` — **launchd / systemd** (autostart at login, KeepAlive)
2. `saga-mcp` — **launchd / systemd**
3. `caffeinate` (or distro equivalent) — anti-sleep (tmux)
4. Cleanup of stale workers
5. `heartbeat-dispatcher` — **launchd / systemd** (StartInterval 180s by default)
6. `operator` — Telegram interface (channel push from telegram-mcp and claude-peers)

The full reset command lives in `{INSTALL_ROOT}/README.md`, section "Full system boot".

### Heartbeat dispatcher (launchd)

```bash
# Plist: ~/Library/LaunchAgents/com.{PROJECT_SLUG}.heartbeat-dispatcher.plist (symlink into the repo)
# StartInterval: configurable, default 180s
# stdout → logs/dispatcher.log, stderr → logs/dispatcher-errors.log

# First-time install (symlink, NOT cp — otherwise repo edits don't take effect)
ln -sf {INSTALL_ROOT}/launchd/com.{PROJECT_SLUG}.heartbeat-dispatcher.plist ~/Library/LaunchAgents/
ln -sf {INSTALL_ROOT}/launchd/com.{PROJECT_SLUG}.strategist.plist ~/Library/LaunchAgents/

# Manage
launchctl load ~/Library/LaunchAgents/com.{PROJECT_SLUG}.heartbeat-dispatcher.plist
launchctl unload ~/Library/LaunchAgents/com.{PROJECT_SLUG}.heartbeat-dispatcher.plist
launchctl kickstart -k gui/$(id -u)/com.{PROJECT_SLUG}.heartbeat-dispatcher
```

**Why launchd, not cron:** Claude CLI authenticates through the macOS Keychain (OAuth). Cron's environment has no Keychain access. launchd user agents run in the user session and have full Keychain access. On Linux the systemd equivalent is a `--user` service unit.

`dispatcher.sh` uses an `mkdir`-based atomic lock to prevent overlapping runs (`flock` is unavailable on macOS). A stale lock older than 5 min is auto-removed.

### Key flags

| Flag | Why |
|------|-----|
| `--dangerously-skip-permissions` | Autonomous mode, no prompts |
| `-p "prompt"` | Ephemeral mode (dispatcher, workers) — non-interactive |
| `--dangerously-load-development-channels server:claude-peers` | Channel push from peers |
| `--dangerously-load-development-channels server:telegram` | Channel push from Telegram |
| `--add-dir <path>` | Extend write scope (directories only) |
| `--mcp-config <file>` | Additional MCP servers |
| `--model "${DEFAULT_MODEL:-claude-sonnet-4-6}"` | Heartbeat / workers on Sonnet (cheap) |
| `--model "${STRATEGIST_MODEL:-claude-opus-4-6}"` | Strategist on Opus |

## Data flows

### Inbound Telegram message

```
Telegram API → grammY (telegram-mcp) → SQLite
                                     → channel notification
                                     → operator session
                                     → Claude processes it
                                     → telegram_reply MCP tool
                                     → grammY → Telegram API
```

### Task from queue

```
sysadmin/operator → memory/queue.md (new) → saga-mcp task_create
                        ↓
launchd → dispatcher.sh → claude -p (dispatcher-prompt.md)
                            ↓
                       worker-launcher.sh → tmux worker
                                               ↓
                                          claude -p "prompt"
                                               ↓
                                          result.md (done/blocked)
                                               ↓
launchd → dispatcher.sh → worker-collector.sh → saga-mcp task_update (done)
                                           → operator → Telegram
```

### Scheduled check

```
launchd → dispatcher.sh → schedule.md + check-log.md
                     → overdue? → create task in saga-mcp
                     → worker runs it → result → check-log.md updated
```

### Strategist cycle

```
launchd → dispatcher.sh → heartbeat_count % N == 0?
                            ↓ yes
                       worker-launcher.sh → strategist worker (Opus)
                            ↓
                       analyse signals, patterns, opportunities
                            ↓
                       proactive tasks → saga-mcp / memory/queue.md
                       updates → memory/opportunities.md, patterns.md
                       git commit + push
```

## Hooks

Hooks live in `agents/heartbeat/hooks/` and are wired up via `.claude/settings.json`. They form the substrate that turns Claude Code from a chat client into an OS:

| Hook | Event | Purpose |
|------|-------|---------|
| `boot.sh` | SessionStart | Print agent identity, load env, refresh epic-map if stale |
| `enrich-prompt.sh` | UserPromptSubmit | Inject heartbeat counter, queue summary, recent learnings into the system prompt |
| `guard-bash.sh` | PreToolUse(Bash) | Block destructive commands (`rm -rf`, `sudo`, etc.) outside `{INSTALL_ROOT}` |
| `log-action.sh` | PostToolUse(*) | Append a structured line to `logs/actions.jsonl` for telemetry |
| `log-subagent.sh` | SubagentStop | Record subagent results, cost, and duration |
| `session-end.sh` | SessionEnd | Flush memory updates, ensure `memory/context.md` heartbeat_count incremented |
| `compress-tool-output.sh` | PostToolUse(Bash, saga-mcp tools) | Compress noisy tool outputs to save context window (worker mode only) |

### Output compression (`compress-tool-output.sh`)

Workers run inside a 30-min, fixed-context budget. Heavy tool outputs (git log, saga dashboards, ANSI-laden Bash) consume 20–40% of context on formatting noise.

**Trigger:** only when `AGENTOS_WORKER_MODE=1` (set by `worker-launcher.sh`). Interactive sessions (sysadmin, operator) are unaffected.

**Mechanism (Claude Code v2.1.121+):** the PostToolUse hook returns JSON with `hookSpecificOutput.toolOutputOverride` — Claude sees the compressed output instead of the raw one.

**Wiring** in `.claude/settings.json`:

```json
{
  "matcher": "Bash|mcp__saga-mcp__task_list|mcp__saga-mcp__tracker_dashboard",
  "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/agents/heartbeat/hooks/compress-tool-output.sh" }]
}
```

**What gets compressed:**

| Tool | Transformation | Effect |
|------|----------------|--------|
| `Bash` | Strip ANSI escapes, truncate `git log` to 20 lines, collapse blank lines | ~30–60% reduction on git output |
| `mcp__saga-mcp__task_list` | Keep only id/title/status/priority | ~70% reduction (descriptions dropped) |
| `mcp__saga-mcp__tracker_dashboard` | Keep stats/summary/epics/counts | ~50% reduction |
| Everything else | Pass through (exit 0) | No effect |

## Subagent spawning from workers

**Claude Code v2.1.121+:** `CLAUDE_CODE_FORK_SUBAGENT=1` works in non-interactive mode (`claude -p`). It is set in `worker-launcher.sh` next to `AGENTOS_WORKER_MODE=1`.

### Pattern: parallel subtasks inside a worker

A worker can use the Agent tool to fork subagents within its own session:

```python
# Example: a research worker with parallel web searches
Agent(description="Search 1", prompt="Find X on source A", run_in_background=True)
Agent(description="Search 2", prompt="Find X on source B", run_in_background=True)
Agent(description="Search 3", prompt="Find X on source C", run_in_background=True)
# Results are gathered and synthesised
```

**When to use:**
- Research workers: 3+ parallel web searches = 3× wall-clock speedup at the same cost ceiling
- Scan workers: parallel parsing of several sources
- Enrichment workers: many independent records at once

**Constraints:**
- Subagents do NOT inherit parent-session MCP tools
- Subagents inherit `--dangerously-skip-permissions` from the parent
- The context budget is shared between parent and subagents

## Self-improvement protocol

The strategist runs every ~6 hours and is the only agent allowed to mutate the role files of other agents. Its protocol is deliberately conservative:

1. **Observe.** Read `logs/workers/*/result.md`, `memory/performance.md`, `memory/patterns.md`.
2. **Hypothesise.** For each repeated failure pattern, draft a one-line rule update.
3. **Stage.** Write a markdown proposal into `memory/proposals/<date>-<slug>.md` instead of editing live files.
4. **Confidence decay.** Each existing pattern in `memory/patterns.md` carries a confidence score that decays unless re-observed; expired patterns are pruned.
5. **Promote on threshold.** A proposal that is observed to fix the failure across N≥3 subsequent worker runs is auto-promoted into the relevant `agents/{role}/CLAUDE.md`.
6. **Audit trail.** Every promotion is recorded in `memory/decisions.md` with a link back to the proposal and the runs that justified it.

## Self-healing (3-tier)

When something breaks, the system follows DETECT → DIAGNOSE → FIX:

**Tier 1 — DETECT (dispatcher, every cycle):**
- Stale worker (heartbeat older than 2× expected interval) → kill tmux session, re-queue task
- Crashed MCP server (health endpoint unreachable) → `launchctl kickstart` / `systemctl --user restart`
- Lock file older than 5 min → remove
- saga-mcp DB locked → wait one cycle, then `pragma wal_checkpoint(TRUNCATE)`

**Tier 2 — DIAGNOSE (strategist, every cycle):**
- Cluster recent failures by error class (`logs/workers/*/result.md` with `status: failed`)
- Cross-reference against `memory/patterns.md` known issues
- If pattern is novel, write a postmortem stub into `memory/postmortems/<date>-<slug>.md`

**Tier 3 — FIX (sysadmin / human-in-the-loop):**
- Postmortems with a proposed fix become tasks in `saga-mcp` under the `Infra` epic
- Sysadmin (interactive) reviews, applies, and closes the postmortem with a link to the commit

The runbook for each tier lives in `memory/self-heal-runbook.md`.

## Cost telemetry

Every worker emits a stream-json log. `scripts/cost-dashboard.sh` aggregates them:

```
logs/workers/*/stream.jsonl
   → scripts/parse-stream.py
   → logs/workers/*/telemetry.json (cost_usd, tokens_in, tokens_out, model)
   → scripts/cost-dashboard.sh
   → memory/cost-rollup.md (per-day, per-model, per-agent rollups)
```

The strategist's `worker-results-analysis.md` skill consumes the rollup to flag runaway-cost patterns (e.g. "researcher worker spent >$5 on a single signal — investigate").

## Monitoring

| What | Where |
|------|-------|
| Dispatcher stdout | `logs/dispatcher.log` |
| Dispatcher stderr | `logs/dispatcher-errors.log` |
| Check log | `memory/check-log.md` |
| Heartbeat alive | `memory/context.md` → heartbeat_count growing |
| Worker statuses | `tmux ls \| grep worker-` |

`logs/` is in `.gitignore` — not committed, available locally for debugging.

### launchd / systemd services

All MCP backends run under macOS launchd (or Linux systemd `--user` units) — always online, autostart at login, restart on crash.

| Service | Plist / Unit | Binary | Default port | Logs |
|---------|--------------|--------|--------------|------|
| claude-peers broker | `com.{PROJECT_SLUG}.claude-peers-broker.plist` | `bun broker.ts` | 7899 | `~/Library/Logs/claude-peers-broker.log` |
| telegram-mcp | `com.{PROJECT_SLUG}.telegram-mcp.plist` | `node dist/index.js` | 3848 | `~/Library/Logs/telegram-mcp.log` |
| saga-mcp | `com.{PROJECT_SLUG}.saga-mcp.plist` | `node dist/index.js` | 3851 | `~/Library/Logs/saga-mcp.log` |
| heartbeat-dispatcher | `com.{PROJECT_SLUG}.heartbeat-dispatcher.plist` | `dispatcher.sh` | — | `logs/dispatcher.log` |

Management:

```bash
# Status
launchctl list | grep {PROJECT_SLUG}
curl -s http://127.0.0.1:7899/health   # claude-peers
curl -s http://127.0.0.1:3848/health   # telegram-mcp
curl -s http://127.0.0.1:3851/health   # saga-mcp

# Restart
launchctl kickstart -k gui/$(id -u)/com.{PROJECT_SLUG}.claude-peers-broker
launchctl kickstart -k gui/$(id -u)/com.{PROJECT_SLUG}.telegram-mcp
launchctl kickstart -k gui/$(id -u)/com.{PROJECT_SLUG}.saga-mcp

# Stop / start
launchctl unload ~/Library/LaunchAgents/com.{PROJECT_SLUG}.<service>.plist
launchctl load   ~/Library/LaunchAgents/com.{PROJECT_SLUG}.<service>.plist
```

Linux equivalent:

```bash
systemctl --user status {PROJECT_SLUG}-claude-peers-broker.service
systemctl --user restart {PROJECT_SLUG}-saga-mcp.service
journalctl --user -u {PROJECT_SLUG}-telegram-mcp.service -f
```

## Configuration via env

The template reads runtime configuration from `.env` (sourced by `dispatcher.sh`, `worker-launcher.sh`, and the launchd / systemd unit templates). Common variables:

| Var | Default | Meaning |
|-----|---------|---------|
| `DEFAULT_MODEL` | `claude-sonnet-4-6` | Model for dispatcher and ordinary workers |
| `STRATEGIST_MODEL` | `claude-opus-4-6` | Model for the strategist worker |
| `TIMEZONE` | `{TIMEZONE}` | Used by scheduled checks and reminders |
| `TELEGRAM_MCP_PORT` | `3848` | telegram-mcp SSE port |
| `SAGA_MCP_PORT` | `3851` | saga-mcp SSE port |
| `CLAUDE_PEERS_PORT` | `7899` | claude-peers broker HTTP port |
| `MAX_WORKERS` | `5` | Max concurrent tmux workers |
| `WORKER_ITERATION_CAP` | `20` | Max iterations per worker |
| `WORKER_TIME_CAP_SECONDS` | `1800` | Wall-clock cap per worker |
| `STRATEGIST_EVERY_N_CYCLES` | `120` | Run strategist every Nth dispatcher cycle |

Anything user-facing that depends on the local clock (scheduled checks, evening reminders, etc.) must read `TIMEZONE` rather than hard-coding a region.
