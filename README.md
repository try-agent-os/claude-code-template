<div align="center">

# AgentOS — Claude Code as a long-running service

**Deploy a Telegram-native Claude Code agent to your own VPS in 5 minutes.**

The agent listens, replies, runs tools on your behalf, and survives reboots. Bring your Anthropic OAuth token, click a button, send your bot a message.

[![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/droplets/new?image=ubuntu-24-04-x64&size=s-2vcpu-4gb&region=fra1&refcode=6f9a0892dd0a&user_data=https%3A%2F%2Fraw.githubusercontent.com%2Ftry-agent-os%2Fclaude-code-template%2Fmain%2Fcloud-init.yaml)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/try-agent-os/claude-code-template?label=release)](https://github.com/try-agent-os/claude-code-template/releases)
[![CI](https://github.com/try-agent-os/claude-code-template/actions/workflows/ci.yml/badge.svg)](https://github.com/try-agent-os/claude-code-template/actions/workflows/ci.yml)
[![GitHub Stars](https://img.shields.io/github/stars/try-agent-os/claude-code-template?style=social)](https://github.com/try-agent-os/claude-code-template)

[Quickstart](./QUICKSTART.md) · [Architecture](./ARCHITECTURE.md) · [Troubleshooting](./TROUBLESHOOTING.md) · [Changelog](./CHANGELOG.md) · [Upgrading](./UPGRADING.md)

</div>

---

> **Client requires macOS.** The install wizard runs on a Mac (uses `brew`, `gh`, `osxkeychain`). The droplet itself runs Ubuntu/Debian. Linux/Windows clients are planned (saga #815) — for now please run the wizard from a Mac.

## What this is

AgentOS turns Claude Code from a CLI you run locally into a **persistent agent that lives on your server**, listens to a Telegram bot, executes tools, and remembers context across sessions. It's Claude Code with the supervision layer, the channel routing, the plugin allowlist plumbing, and the deploy ergonomics already wired up.

It also creates a **private GitHub fork of the template under your account**, clones it to a local Mac path you choose, and installs an auto-sync cron job on the droplet — so editing `memory/owner.md` in your editor on the Mac, committing, pushing, has the operator picking up the change within 5 min. (Saga #814.)

You bring:
- An Anthropic account (Pro / Max / Team — channel push works on personal plans, no enterprise required)
- A Telegram bot from `@BotFather` (60 seconds to create)
- A Linux VPS (or click the deploy button to provision one on DigitalOcean)

You get:
- An **operator agent** running 24/7 in a tmux session, listening for incoming Telegram messages and replying
- A **task tracker** (saga-mcp) Claude can use to plan and persist work across sessions
- A **heartbeat dispatcher** that fires every 45 minutes for scheduled / proactive work
- A **plugin marketplace** with claude-peers (inter-agent messaging) + telegram (bot bridge) + four vendored Anthropic plugins (commit-commands, code-review, security-guidance, agent-sdk-dev)
- A **deploy pipeline** that's been beaten on, debugged, and shipped (15+ hard-won schema / config / unit fixes documented in [CHANGELOG.md](./CHANGELOG.md))

---

## 5-minute deploy

```bash
# On your Mac (requires brew, gh CLI auto-installed by wizard):
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | bash

# Wizard handles:
#   • brew + gh + doctl auto-install
#   • create private fork on your GitHub
#   • clone to ~/Workspaces/agentos (path is a prompt)
#   • provision DigitalOcean droplet
#   • SSH in, run 18-step install
#   • prompt for Telegram bot token + Anthropic OAuth
#   • configure auto-sync cron between your fork and the droplet
# Total time ~10-12 min. Send a message to your bot. It replies.
```

Full step-by-step: [QUICKSTART.md](./QUICKSTART.md)

Already have a droplet, or prefer manual control? See [Manual install](#manual-install) below.

---

## What you can build with it

The operator's behaviour is fully driven by `agents/operator/CLAUDE.md` — change that file, restart the unit, you have a different agent. Some examples:

- **A solo-founder assistant** that reads your inbox, summarises overnight news, drafts replies, books calendar slots — all from Telegram chat.
- **A consulting workspace** for a specific domain (restaurant ops, SaaS growth, real-estate research) where the operator has pre-loaded skills, contact lists, and SOPs.
- **A team coordination layer** where multiple humans share one operator over Telegram and saga-mcp tracks work-in-flight.
- **A research agent** that runs scheduled scans, persists findings to memory, and pings you when something's worth your attention.

Pre-built example configurations live in [`examples/`](./examples/) (more landing in v0.2).

---

## Architecture in 30 seconds

Three tiers:

1. **systemd / launchd** — long-lived supervision. `agent-os-operator.service` (claude in tmux), `agent-os-saga.service` (task tracker, SSE :3851), `agent-os-telegram-mcp.service` (bot bridge, SSE :3848), `agent-os-dispatcher.timer` (every 45 min).
2. **Claude Code processes** — operator session runs `claude --dangerously-load-development-channels server:telegram server:claude-peers`, isolated by per-agent `CLAUDE_CONFIG_DIR`.
3. **MCP layer** — telegram-mcp + saga-mcp speak HTTP/SSE; claude-peers + Anthropic plugins are stdio MCP plugins spawned per session.

Channel push: incoming Telegram message → telegram-mcp's `getUpdates` long-poll → notification routed via SSE to operator session → claude generates response → calls `mcp__telegram__send_message` tool → reply lands in Telegram. Round-trip is typically 2-4 seconds.

Full diagrams + rationale: [ARCHITECTURE.md](./ARCHITECTURE.md)

---

## Why we built this

Running Claude Code as `claude --dangerously-skip-permissions` in a tmux session works for ~30 minutes until something interrupts it. We wanted:

- **Bot-as-frontend** — Telegram is where you already are; the agent should reach you there.
- **Survives reboots** — systemd unit, idempotent install, restart-on-failure.
- **Multi-channel** — claude-peers lets multiple agents on one host coordinate over a shared broker; telegram lets humans message in.
- **No enterprise plan required** — channel push for plugins is gated on personal Anthropic plans behind the `tengu_harbor_ledger` feature flag, but `--dangerously-load-development-channels server:<name>` syntax sidesteps the gate (verified end-to-end on Pro / Max).
- **Deploy in 5 minutes, not a day** — every schema, every flag, every dialog acknowledgement is automated. The two-day debugging that distilled into this template is documented in [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).

---

## Manual install

`install.sh` detects the OS and picks the right path:

- **macOS** → guided remote-setup wizard. Provisions or picks an existing VPS, configures Telegram + Claude Code OAuth, runs `install.sh` non-interactively on the remote.
- **Linux as root** → 18-step local install in place (the canonical AgentOS host).

### Method A — clone & run (recommended)

```bash
git clone https://github.com/try-agent-os/claude-code-template ~/agentos
cd ~/agentos
bash install.sh        # macOS — wizard
sudo bash install.sh   # Linux — local install
```

### Method B — one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | bash
```

The installer is **idempotent and resumable** — re-run any time. Linux state lives in `/etc/agent-os/install.state.json`, macOS state in `~/.agent-os-deploy/`. Linux flags: `--reset` to re-prompt the wizard, `--force-reinstall` to re-run every step.

If you want to inspect the script before running:

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh -o install.sh
less install.sh
bash install.sh        # or sudo bash install.sh on Linux
```

### What gets installed (Linux side, 18 steps)

`apt prereqs · Node 20 LTS · claude-code (apt) · agent-os user · bun · saga-mcp clone · plugin builds · whisper.cpp · /etc/agent-os/agent-os.env · per-agent CLAUDE_CONFIG_DIR · managed-settings.json · template hooks · systemd units · marketplace registration · plugin install · service start · health verify`

See [`install.sh`](./install.sh) for the full sequence. Each step is independently re-runnable.

---

## Hardware / cost

| Provider | Size | Region | $/month | Notes |
|----------|------|--------|---------|-------|
| DigitalOcean | s-2vcpu-4gb | any | ~$24 | Minimum recommended (whisper builds slowly) |
| DigitalOcean | s-4vcpu-8gb | any | ~$48 | Recommended for heavy workloads |
| Hetzner Cloud | CAX21 | EU | ~€8 | Budget option, ARM (build times longer) |
| Linode | g6-standard-2 | any | ~$24 | Mid-tier alternative |

Telegram is free. Claude Code is free; the runtime needs an Anthropic subscription or API spend. Whisper transcription runs locally (no API cost, ~1.5 GB disk).

---

## What's in the box

```
.
├── install.sh                       # 18-step idempotent installer
├── uninstall.sh                     # clean tear-down
├── cloud-init.yaml                  # one-click VPS bootstrap
├── agents/
│   ├── operator/                    # Telegram-listening claude session
│   ├── heartbeat/                   # dispatcher.sh — fires workers
│   └── strategist/                  # planning role
├── plugins/
│   ├── claude-peers/                # stdio MCP — inter-agent messaging
│   ├── telegram/                    # MCP — bot bridge + tools
│   ├── agent-sdk-dev/               # vendored Anthropic
│   ├── code-review/                 # vendored Anthropic
│   ├── commit-commands/             # vendored Anthropic
│   └── security-guidance/           # vendored Anthropic
├── systemd/                         # unit templates
├── scripts/verify.sh                # 50+ healthchecks
├── examples/                        # pre-loaded configs (more in v0.2)
├── memory/                          # template memory layout
└── .claude-plugin/marketplace.json  # plugin marketplace
```

---

## Status

**v0.1.0** — first publishable release ([release notes](https://github.com/try-agent-os/claude-code-template/releases/tag/v0.1.0)). Verified end-to-end on a personal Anthropic plan (DigitalOcean droplet, Ubuntu 24.04). All four critical MCP servers ✔ connected. @axionagentbot replying to messages.

What's next ([saga #812](https://github.com/try-agent-os/claude-code-template/issues)):
- More example configurations in `examples/`
- Security hardening (fail2ban + UFW in install.sh for DO droplets)
- Multi-platform validation (Debian 12, Fedora)
- DigitalOcean Marketplace listing
- Operator first-run onboarding UX

---

## Contributing

Bugs, schema mismatches, alternate-cloud cloud-init, missing TROUBLESHOOTING entries — open an issue or PR. CI runs shellcheck + JSON/YAML validation + smoke install on every push.

---

## License

MIT — see [LICENSE](./LICENSE).
