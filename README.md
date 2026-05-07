# claude-code-template

> One-command bootstrap for [AgentOS](https://github.com/try-agent-os): a long-running Claude Code agent stack on a Linux VPS — operator + heartbeat dispatcher + saga task tracker + bundled plugin marketplace + project hooks + managed policy.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

---

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | sudo bash
```

Prefer to read the script before running as root? Same result, two steps:

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh -o install.sh
less install.sh        # inspect
sudo bash install.sh   # run when satisfied
```

The installer is **idempotent and resumable** — re-run it any time. State lives in `/etc/agent-os/install.state.json`. Use `--reset` to re-prompt the wizard, `--force-reinstall` to re-execute every step.

> **Currently Linux only.** The installer requires Ubuntu 22.04+ or Debian 12+. macOS launchd plists exist under [`launchd/`](./launchd/) but are not yet wired into `install.sh` — Mac users must lay them down manually. See [Requirements](#requirements).

---

## What you get

After a default install:

**System layout**

- `/opt/agent-os/claude/` — this template repo (cloned)
- `/opt/agent-os/saga-mcp/` — task tracker MCP (separate broker)
- `/var/lib/agent-os/` — persistent state (`saga.db`, `claude-peers.db`, per-agent `claude-config/`)
- `/var/log/agent-os/` — append-only logs
- `/etc/agent-os/agent-os.env` — single source of secrets (mode `0640`, `root:agent-os`)
- `/etc/claude-code/managed-settings.json` — org-wide policy (sandbox, allowed plugins, deny rules)
- A dedicated unprivileged `agent-os` user owns everything

**Long-lived services (systemd)**

| Unit | Type | Purpose |
|------|------|---------|
| `agent-os-saga.service` | `simple` | saga-mcp task tracker on `127.0.0.1:3851` |
| `agent-os-operator.service` | `forking` | Claude Code in detached tmux session named `operator`, channel-pushed by Telegram + peers |
| `agent-os-dispatcher.timer` | timer | Fires the dispatcher every 45 minutes (configurable) |
| `agent-os-dispatcher.service` | `oneshot` | Heartbeat dispatcher — runs one cycle, exits |

claude-peers and telegram are **stdio MCP plugins** (not separate services). Claude Code spawns them per session. The claude-peers broker daemon is auto-bootstrapped from `server.ts` on first plugin spawn. See [`systemd/README.md`](./systemd/README.md) for unit details.

**Bundled plugins** (private marketplace `agentos`, declared in [`.claude-plugin/marketplace.json`](./.claude-plugin/marketplace.json))

| Plugin | Source | Role |
|--------|--------|------|
| `claude-peers@agentos` | [novostudiotech/claude-peers-mcp](https://github.com/novostudiotech/claude-peers-mcp) | Inter-agent messaging + channel push |
| `telegram@agentos` | [novostudiotech/telegram-mcp](https://github.com/novostudiotech/telegram-mcp) | Telegram bot bridge + channel push (whisper voice + URL transcription, multi-admin allowlist) |
| `agent-sdk-dev@anthropic` | [anthropics/claude-code](https://github.com/anthropics/claude-code) | Scaffolding for Agent SDK projects |
| `code-review@anthropic` | [anthropics/claude-code](https://github.com/anthropics/claude-code) | Multi-agent PR review with confidence scoring |
| `commit-commands@anthropic` | [anthropics/claude-code](https://github.com/anthropics/claude-code) | `/commit`, `/commit-push-pr`, `/clean_gone` |
| `security-guidance@anthropic` | [anthropics/claude-code](https://github.com/anthropics/claude-code) | PreToolUse hook flagging insecure code patterns |

Two more plugins are listed as placeholders for future tasks: `template-dev@agentos` (sync skill) and `agentos-core@agentos` (slash commands `/agentos-status`, `/agentos-restart`, `/agentos-verify`).

**Project hooks** ([`.claude/`](./.claude/))

- `settings.json` — project-scope permissions (deny/ask/allow), additionalDirectories, hook wiring, attribution
- 8 lifecycle hooks under `.claude/hooks/` (see [hooks README](./.claude/hooks/README.md)):
  - `boot.sh` (SessionStart)
  - `enrich-prompt.sh` (UserPromptSubmit)
  - `guard-bash.sh` (PreToolUse: Bash) — security gate
  - `guard-edit.sh` (PreToolUse: Edit/Write/MultiEdit) — file protection
  - `log-action.sh` (PostToolUse) — formatter + audit log
  - `log-subagent.sh` (SubagentStop) — audit
  - `notify-stop.sh` (Stop) — peer notification when `OPERATOR_PEER_ID` set
  - `session-end.sh` (SessionEnd) — wrap-up notify
- `_common.sh` — shared bash helpers (sourced by every hook, not itself a hook)

**Memory layout**

The template ships an empty `agents/{operator,dispatcher}/CLAUDE.md` skeleton. As you work, write to `memory/context.md`, `memory/people.md`, `memory/decisions.md`, etc. — these are not pre-seeded.

---

## Requirements

| Item | Required |
|------|----------|
| OS | Ubuntu 22.04 / 24.04, Debian 12+. amd64 or arm64. |
| Privilege | `sudo` / root for the install (creates the `agent-os` user, writes systemd units, installs apt packages). |
| RAM | 2 GB minimum. Recommended 4 GB if you keep the medium Whisper model + active operator session. |
| Disk | ~3 GB for default install (Whisper medium model is 1.5 GB on its own; pick `--whisper=tiny` to drop it to ~1 GB total). |
| Network | Outbound HTTPS to `api.anthropic.com`, `downloads.claude.ai`, `github.com`, NPM/Bun registries, Telegram Bot API. |
| Anthropic auth | A valid `CLAUDE_CODE_OAUTH_TOKEN` (recommended — Pro/Max/Team/Enterprise plan, generated on your workstation with `claude setup-token`) **or** `ANTHROPIC_API_KEY` (Console-billed pay-per-token). |
| Telegram (optional) | A bot token from `@BotFather` and your numeric user ID from `@userinfobot`. Skip with `--minimal`. |

macOS path: launchd plists exist under [`launchd/`](./launchd/) but `install.sh` does not currently render them. Manual setup is possible — see the unit files for the exact `ProgramArguments` and `EnvironmentVariables` shape.

---

## Quickstart

From zero to first message in roughly five minutes.

### 1. Generate an OAuth token on your local machine

On your Mac/Linux workstation (where you already have Claude Code authenticated):

```bash
claude setup-token
```

A browser window opens, you approve, the CLI prints a token like `sk-ant-oat01-...` valid for one year. Copy it.

### 2. Run the installer on the VPS

```bash
ssh you@your-vps
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | sudo bash
```

The wizard prompts for:

- **Project slug** — used for log prefixes, default `agentos`
- **Telegram bot token + your user ID** — empty values disable the operator
- **Git remote** — optional; useful if you've forked the template
- **Timezone** — IANA, e.g. `Europe/Lisbon`
- **Whisper model size** — `tiny` (75 MB) / `base` (150 MB) / `medium` (1.5 GB, default)
- **OAuth token** — paste from step 1, or skip if `CLAUDE_CODE_OAUTH_TOKEN` is already in env

Non-interactive runs: `export` all of these and pass `--non-interactive`. See [`.env.example`](./.env.example) for the full variable list.

### 3. Verify the services came up

```bash
sudo systemctl status 'agent-os-*' --no-pager
curl -sf http://127.0.0.1:3851/health   # saga-mcp
journalctl -u agent-os-operator -n 50 --no-pager
```

The claude-peers broker comes up only after the operator session has spawned its first plugin instance. After that:

```bash
curl -sf http://127.0.0.1:7899/health
```

### 4. Send a Telegram message

Open your bot in Telegram and type anything. The operator, running inside a detached tmux session, receives the message via `telegram@agentos`'s channel push, acknowledges it, and replies.

### 5. Attach to the operator tmux for live debugging

```bash
sudo -u agent-os tmux attach -t operator
```

Detach with `Ctrl-b d`. The session keeps running. Logs:

```bash
tail -f /var/log/agent-os/operator.log
tail -f /var/log/agent-os/dispatcher.log
```

---

## `--minimal` vs default

The installer ships a `--minimal` profile for cases where you want the project hooks + managed policy without the long-running agent stack.

| | Default | `--minimal` |
|---|---|---|
| Bundled plugins (`enabledPlugins`) | All 6 (peers, telegram, agent-sdk-dev, code-review, commit-commands, security-guidance) | None — managed-settings.json overridden by installer |
| systemd units | saga + operator + dispatcher.timer | saga + dispatcher.timer (no operator) |
| Telegram | Required (bot token prompt) | Skipped |
| Channel plugins active | `--channels plugin:claude-peers@agentos plugin:telegram@agentos` | None |
| Project hooks shipped | All 8 + `_common.sh` | `_common.sh`, `guard-bash.sh`, `guard-edit.sh` only |
| settings.json hook events | All 7 events | PreToolUse only |
| Whisper model | medium (1.5 GB) | not built |
| Disk footprint | ~3 GB | ~600 MB |

Run with `sudo bash install.sh --minimal`. Switching back to default later: re-run without `--minimal`.

> **Caveat:** the `--minimal` hook subsetting is documented in [`.claude/README.md`](./.claude/README.md) and [`.claude/hooks/README.md`](./.claude/hooks/README.md), but the current `install.sh` does not yet selectively prune `.claude/hooks/` — it always copies the full template. The hook subset is currently advisory; the `--minimal` switch only affects systemd units and operator activation.

---

## Architecture overview

Three tiers, each with its own lifetime:

```
                    ┌──────────────────────────────────────────────┐
                    │  Tier 3 — long-lived services (systemd)      │
                    │                                              │
                    │  agent-os-saga.service       (always)        │
                    │  agent-os-operator.service   (always)        │
                    │  agent-os-dispatcher.timer   (every 45 min)  │
                    └──────────────────────────────────────────────┘
                                       ▲
                                       │ spawns
                                       │
                    ┌──────────────────────────────────────────────┐
                    │  Tier 2 — Claude Code processes              │
                    │                                              │
                    │  operator session (tmux, channel-pushed)     │
                    │  dispatcher session (oneshot, headless)      │
                    │                                              │
                    │  per-agent CLAUDE_CONFIG_DIR for isolation:  │
                    │    /var/lib/agent-os/claude-config/operator/ │
                    │    /var/lib/agent-os/claude-config/dispatcher/│
                    │    /var/lib/agent-os/claude-config/heartbeat/│
                    └──────────────────────────────────────────────┘
                                       ▲
                                       │ stdio spawn / SSE
                                       │
       ┌──────────────────────────┬────┴──────────────────────────┐
       ▼                          ▼                                ▼
┌─────────────────┐  ┌────────────────────────┐  ┌──────────────────────┐
│ Tier 1 — MCP    │  │ Tier 1 — stdio plugins │  │ Tier 1 — broker      │
│  brokers (HTTP) │  │                        │  │  (auto-bootstrap)    │
│                 │  │  claude-peers@agentos  │  │                      │
│ saga-mcp :3851  │  │  telegram@agentos      │  │  claude-peers broker │
│ (SSE)           │  │  + 4 Anthropic plugins │  │  on :7899 (HTTP)     │
└─────────────────┘  └────────────────────────┘  └──────────────────────┘
```

For full details, design rationale, and the .claude/ settings cascade: [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## Configuration

### Environment file

`/etc/agent-os/agent-os.env` is the single source of secrets. Mode `0640`, owner `root:agent-os`. systemd units load it via `EnvironmentFile=`. The wizard writes it; you can also pre-create it from [`.env.example`](./.env.example) and run `--non-interactive`.

Key variables:

```ini
# Authentication — pick one
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
ANTHROPIC_API_KEY=sk-ant-api03-...

# Telegram
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_ADMIN_USER_IDS=123456789,987654321   # comma-separated admin allowlist (multi-admin)
TELEGRAM_ADMIN_USERNAMES=alice,bob            # parallel display names (optional)
TELEGRAM_USER_ID=123456789                    # legacy single-admin (= first ID); still honoured

# State paths (defaults are fine)
DB_PATH=/var/lib/agent-os/saga.db
CLAUDE_PEERS_DB=/var/lib/agent-os/claude-peers.db

# Timezone, project slug
TZ=Europe/Lisbon
PROJECT_NAME=agentos
```

### Settings hierarchy

Three scopes, highest precedence first. Arrays merge across scopes, scalars take the most-specific value.

1. **Managed** — `/etc/claude-code/managed-settings.json` (root-owned). Hard org policy: `sandbox.enabled`, `channelsEnabled`, `allowedChannelPlugins`, `enabledPlugins`, `minimumVersion`, catastrophic deny rules. Cannot be overridden. Source: [`managed-settings.template.json`](./managed-settings.template.json).
2. **Project** — `.claude/settings.json` in this repo. Team-shared rules: project-specific deny/ask/allow patterns, hook wiring, additionalDirectories, attribution. See [`.claude/README.md`](./.claude/README.md).
3. **User** — `~/.claude/settings.json` per agent user. Personal defaults (model preference, env injections, `cleanupPeriodDays`).

The installer also lays down a per-agent `~/.claude.json` from [`.claude-config.template.json`](./.claude-config.template.json) — currently registers only `saga-mcp` as an SSE MCP server. The peers + telegram plugins come in via `enabledPlugins` in managed-settings.

### Hook env vars

Project hooks read several env vars (set in `/etc/agent-os/agent-os.env`):

| Var | Default | Purpose |
|-----|---------|---------|
| `OPERATOR_PEER_ID` | (unset) | Target peer for `notify-stop` / `session-end` |
| `CLAUDE_PEERS_API_URL` | `http://127.0.0.1:7899/send-message` | Broker REST API |
| `SAGA_MCP_HEALTH_URL` | `http://localhost:3851/health` | Boot health-check target |
| `AGENTOS_HOOKS_LOG_DIR` | `/tmp/agentos-hooks` | Per-hook log directory |

Full list in [`.claude/hooks/README.md`](./.claude/hooks/README.md).

---

## Updating

The recommended pattern is fork-then-update:

1. Fork [`try-agent-os/claude-code-template`](https://github.com/try-agent-os/claude-code-template).
2. Pass `--bootstrap-personal-repo=git@github.com:you/your-fork.git` on first install — `install.sh` swaps the upstream remote for yours.
3. Periodically `git fetch upstream && git merge upstream/main` (or use the planned `template-dev@agentos` sync skill once it lands).

The template uses a **T (template-owned) / P (project-owned)** file convention so you can tell at a glance which files upstream merges should overwrite vs. preserve. See [UPGRADING.md](./UPGRADING.md) for the full workflow, conflict resolution, version pinning, and rollback.

To pull a newer install.sh into an existing install: re-run the same `curl | bash` command. State persists; the wizard skips already-completed steps.

---

## Uninstall

```bash
sudo /opt/agent-os/claude/uninstall.sh
```

Default behaviour: stops + disables units, removes unit files, **keeps** `/var/lib/agent-os` (state), `/var/log/agent-os` (logs), `/etc/agent-os` (env), `/opt/agent-os` (repo), and the `agent-os` user. Re-running `install.sh` resumes cleanly.

Total wipe:

```bash
sudo /opt/agent-os/claude/uninstall.sh --purge
```

This removes the data dirs, `/etc/claude-code/managed-settings.json`, the apt source + GPG key, and the `agent-os` user. Set `PURGE_CLAUDE_CODE=1` to also `apt purge claude-code`.

Reset only the wizard state (e.g. to re-prompt):

```bash
sudo /opt/agent-os/claude/uninstall.sh --reset-state
```

---

## Troubleshooting

### Install: GPG key fingerprint mismatch

`install.sh` verifies the Anthropic apt-repo key against a hard-coded fingerprint (`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`). If verification fails, the install aborts. Re-run after ensuring `downloads.claude.ai` isn't being intercepted by a corporate proxy.

### Install: token rejected

The wizard distinguishes OAuth tokens (start with `sk-ant-oat01-`) from API keys (`sk-ant-api...`). If you paste an API key into the OAuth prompt, the script auto-routes it to `ANTHROPIC_API_KEY`. Tokens that simply expired need to be re-issued via `claude setup-token` on your workstation.

### Operator: `--channels` triggers a trust prompt

If you see Claude Code prompting "trust development channel?" when the operator starts, the plugin allowlist isn't enforced. Verify:

```bash
sudo cat /etc/claude-code/managed-settings.json | jq '.allowedChannelPlugins, .channelsEnabled'
```

Both `claude-peers@agentos` and `telegram@agentos` must be in `allowedChannelPlugins` and `channelsEnabled` must be `true`. The operator is launched with `--channels plugin:NAME@agentos` (not `--dangerously-load-development-channels`) — see [`systemd/README.md`](./systemd/README.md) for the rationale.

### claude-peers broker not responding on `:7899`

The broker is auto-bootstrapped by `plugins/claude-peers/server.ts` the first time a plugin session spawns. If `curl 127.0.0.1:7899/health` 404s after the operator started:

```bash
journalctl -u agent-os-operator -n 100 --no-pager | grep -i peers
ls /var/lib/agent-os/claude-peers.db
```

Restart the operator: `sudo systemctl restart agent-os-operator`. The broker spawns again on next plugin instantiation.

### saga-mcp not responding on `:3851`

```bash
sudo systemctl status agent-os-saga
sudo journalctl -u agent-os-saga -n 100 --no-pager
ls -la /var/lib/agent-os/saga.db
```

The DB is auto-created on first connect. If the unit is failing, check `/var/log/agent-os/saga-mcp-errors.log`.

### Telegram channel push not arriving

```bash
journalctl -u agent-os-operator -n 100 --no-pager | grep -i telegram
sudo -u agent-os tmux attach -t operator
```

Confirm `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ADMIN_USER_IDS` (or the legacy `TELEGRAM_USER_ID`) are in `/etc/agent-os/agent-os.env`. The bot uses long polling — no webhook required. Admins listed in `TELEGRAM_ADMIN_USER_IDS` are seeded as `allowed` in the bot's SQLite users table on startup; everyone else hits the default policy (`pending`).

### Hooks aren't firing

```bash
ls -la /tmp/agentos-hooks/
tail /tmp/agentos-hooks/boot.log
```

Hooks log to `/tmp/agentos-hooks/<hook>.log` by default. If a hook is slow or hanging, check `timeout` in [`.claude/settings.json`](./.claude/settings.json) — every entry has one.

---

## Contributing

Issues and PRs welcome at [github.com/try-agent-os/claude-code-template](https://github.com/try-agent-os/claude-code-template). Architectural changes — please open a discussion first.

For plugin authoring, see Anthropic's [Claude Code plugin docs](https://code.claude.com/docs/en/plugins) and the existing plugins under `plugins/` for working examples (single-server stdio MCP with `claude/channel` capability, plugin manifest with `userConfig`, etc.).

---

## License

[MIT](./LICENSE). Vendored upstream Anthropic plugins are also MIT — see [`plugins/VENDORING.md`](./plugins/VENDORING.md) for source URLs and pinned commits.
