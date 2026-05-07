# Claude Code Template

> Production-ready AgentOS for Claude Code. One command — auto-detects Mac (provisions VPS) vs Linux root (installs locally).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | bash
```

That's it. Works on:

- **macOS** — walks you through picking an existing SSH alias or provisioning a fresh VPS (DigitalOcean / Hetzner / Linode), then installs AgentOS remotely.
- **Ubuntu 22.04+ / Debian 12+ as root** — installs everything locally (saga-mcp + dispatcher + operator + 4 vendored plugins).

State for re-runs:
- Mac wizard: `~/.agent-os-deploy/state.json`
- Linux install: `/etc/agent-os/install.state.json`

For the full architecture and component list see [`CLAUDE.md`](./CLAUDE.md).

## Structure

```
.
├── CLAUDE.md                  # Root system prompt for the orchestrator
├── agents/
│   ├── operator/CLAUDE.md     # Long-running agent (Telegram interface)
│   └── dispatcher/CLAUDE.md   # Ephemeral cron agent (spawns workers)
└── skills/
    └── morning-brief.md        # Example reusable skill
```

## Idea

The operator holds an ongoing session and talks to the user. The dispatcher wakes up on cron, reads the task queue, spawns short-lived workers, collects their results, and exits.

The template is intentionally minimal — add your own sub-agents, skills, and infrastructure for your domain.

## License

MIT
