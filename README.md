# AgentOS Template

> Production-ready AgentOS starter for Claude Code. Three-tier agent topology (sysadmin / operator / heartbeat) on top of saga-mcp + claude-peers + telegram-mcp. Deployable in one command — installer auto-detects macOS (provisions VPS) vs. Linux root (installs locally).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | bash
```

Works on:

- **macOS** — walks you through picking an existing SSH alias or provisioning a fresh VPS (DigitalOcean / Hetzner / Linode), then installs AgentOS remotely.
- **Ubuntu 22.04+ / Debian 12+ as root** — installs everything locally (saga-mcp + dispatcher + operator + 4 vendored plugins).

State for re-runs:
- Mac wizard: `~/.agent-os-deploy/state.json`
- Linux install: `/etc/agent-os/install.state.json`

Or clone first, inspect, then run:

```bash
git clone https://github.com/try-agent-os/claude-code-template.git
cd claude-code-template
bash install.sh
```

The installer wizard prompts for 6 inputs:
- `PROJECT_NAME` — display name
- `PROJECT_SLUG` — short slug for service labels (lowercase, no spaces)
- `TG_BOT_TOKEN` — Telegram bot token (optional; skip with `--minimal`)
- `TG_USER_ID` — your Telegram chat_id
- `TIMEZONE` — IANA timezone (e.g. `Europe/Lisbon`, `UTC`)
- `CLAUDE_CODE_OAUTH_TOKEN` — generated locally via `claude setup-token`

After install, `scripts/verify.sh` runs and prints a green/red dashboard. Five services should be active (launchd on mac / systemd on linux); `tmux ls` should show the operator session; `curl localhost:7899/list-peers` should include the operator peer.

## Flags

- `--minimal` — skip telegram-mcp, ffmpeg, whisper. Operator runs in claude-peers-only mode.
- `--with=feature-dev,frontend-design,plugin-dev` — bundle additional Claude Code plugins.
- `--non-interactive` — read all wizard inputs from environment variables.
- `--bootstrap-personal-repo <git-url>` — after install, rename `origin` to `template`, fetch your personal repo as `origin`.

## What you get

- **Three agents** — `sysadmin` (manual terminal architect), `operator` (Telegram interface), `heartbeat` (ephemeral cron dispatcher every N min)
- **Three MCP brokers** — saga-mcp (3851), claude-peers (7899), telegram-mcp (3848)
- **Worker pattern** — tmux session per task, `claude -p` iteration loop, `result.md` with frontmatter status, auto-conflict-detect on `git pull --rebase` mid-iteration
- **Strategist** — Opus-class scheduled worker every 6h; signal analysis, blocker resolution, business-analysis (configurable lenses), self-improvement, worker-results reflection, health watchdog
- **Self-healing** — 3-tier (DETECT → DIAGNOSE → FIX) catalog in [`memory/self-heal-runbook.md`](memory/self-heal-runbook.md); 6 auto-fix patterns + 2 escalation patterns
- **saga-dashboard** — static UI + REST proxy on port 7902, optional cloudflared tunnel
- **Cost telemetry** — per-iteration `iter-N-cost.json`; `scripts/cost-dashboard.sh` aggregates + categorizes
- **Bundled plugins** — `agent-sdk-dev`, `code-review`, `commit-commands`, `security-guidance`, plus `template-dev` for syncing upstream changes
- **`init-epics.sh`** creates 5 default epics (Default / Research / Business / Infra / Scheduled) on first boot, persists IDs to `memory/epic-map.json`

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full picture: three-tier topology, --add-dir matrix, worker lifecycle, stream-JSON pipeline, hook chain, self-improvement protocol.

## Repository layout

```
agents/         sysadmin, operator, heartbeat, saga-dashboard
memory/         context, decisions, learnings, patterns, schedule, …
plugins/        vendored Claude Code plugins
scripts/        cost-dashboard, token-report, worker-analytics, verify
systemd/        Linux unit files
launchd/        macOS plists (mirror)
examples/       reference skills from a real AgentOS deployment
.claude/        settings.json + project-scope hooks
install.sh      one-command bring-up (Mac/Linux auto-detect)
```

## After install

Attach the operator tmux session and send a Telegram message to your bot:

```bash
tmux attach -t operator
```

The operator should acknowledge in Telegram. To create a task from the terminal: open `claude` in `agents/sysadmin/` and ask it to create a saga task; the heartbeat dispatcher picks it up on the next cycle.

## Upgrading & forking

The template is designed for a "fork-ahead" workflow: clone, install, then `git remote rename origin template && git remote add origin <your-repo>` to take ownership. The `template-dev` plugin provides `/sync` to pull upstream T-marked file changes without overwriting your P-marked personal files. See [`UPGRADING.md`](UPGRADING.md).

## License

MIT. See [`LICENSE`](LICENSE).
