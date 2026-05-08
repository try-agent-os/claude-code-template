# Quickstart — Telegram bot in 5 minutes

This is the fastest path from "I want to try this" to "my bot just replied to me." For background and architecture, see [README.md](./README.md) and [ARCHITECTURE.md](./ARCHITECTURE.md).

## What you'll have at the end

- A long-running Claude Code agent (the **operator**) on a Linux VPS, listening for incoming Telegram messages and replying via the Anthropic API.
- A persistent task tracker (saga-mcp) you can use from within the agent.
- A heartbeat dispatcher that fires every 45 minutes for scheduled / proactive work.
- All four critical MCP servers ✔ connected (claude-peers, saga-mcp, telegram, plugin:claude-peers).

## Prerequisites (5 minutes to gather)

1. **A DigitalOcean account** (or any provider that accepts cloud-init `user_data`). Sign up if you don't have one.
2. **A Telegram bot token.** Open Telegram, search `@BotFather`, send `/newbot`, pick a display name and a username (must end in `_bot`). Copy the API token (format: `123456789:ABC...DEF`).
3. **An Anthropic OAuth token or API key.**
   - OAuth: on a Mac with Claude Code installed, run `claude setup-token`. Browser opens, log in, terminal prints `sk-ant-oat01-...` — copy it.
   - API key (alternative if OAuth flow isn't showing the token): create one at <https://console.anthropic.com/settings/keys> in format `sk-ant-api03-...`.
4. **An SSH key uploaded to your DO account** (Settings → Security → Add SSH Key). You'll need this to log into the droplet.

## Step 1 — Click the deploy button

[![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/droplets/new?image=ubuntu-24-04-x64&size=s-2vcpu-4gb&region=fra1&refcode=6f9a0892dd0a&user_data=https%3A%2F%2Fraw.githubusercontent.com%2Ftry-agent-os%2Fclaude-code-template%2Fmain%2Fcloud-init.yaml)

DigitalOcean's droplet creation page opens with cloud-init pre-loaded. Pick:
- **Image**: Ubuntu 24.04 (LTS) x64 (already selected)
- **Size**: at least `s-2vcpu-4gb` (~$24/month) — smaller works but builds slower. The recommendation is `s-4vcpu-8gb` (~$48/month) if you'll run heavy plugins.
- **Region**: closest to you for SSH latency.
- **Authentication**: pick the SSH key you uploaded.

Click **Create Droplet**. Note the public IPv4 address shown after provisioning (~30 seconds).

## Step 2 — SSH in and run the install wizard

```bash
ssh root@<your-droplet-ip>
sudo bash /opt/agent-os-bootstrap/install.sh
```

Cloud-init has already cloned the template to `/opt/agent-os-bootstrap` and run `apt-get update`. The wizard takes you through:

- **Project slug**: arbitrary, e.g. `claude` (used for systemd unit naming and SQLite paths)
- **Telegram bot token**: paste the BotFather token. Wizard live-validates it against `/getMe` and shows the bot's username on success.
- **Anthropic OAuth/API token**: paste `sk-ant-oat01-...` or `sk-ant-api03-...`.
- **Bot admins**: send `/start` to your bot from each Telegram account that should have access. Wizard polls the API and offers to add detected admins.
- **Optional**: timezone (default Europe/Lisbon), whisper model (default `tiny` for fast install; `medium` if you want full-quality voice transcription, costs ~3 min extra), git remote.

The wizard runs all 18 install steps non-interactively after collecting answers. Total time: **~7-8 minutes** on a `s-2vcpu-4gb` droplet (apt installs ~2 min, MCP plugin builds ~3 min, whisper model download + cmake build ~2 min, claude session warm-up ~1 min). Faster on `s-4vcpu-8gb`.

## Step 3 — Send your bot a message

Once the wizard prints `═══ ✓ AgentOS deployed ═══`, switch to Telegram and message your bot. It should reply within a few seconds.

If it doesn't, see [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — the top sections cover the most common issues (token typos, admin not seeded, MCP connection failures).

## What's running on the droplet now

```bash
systemctl status 'agent-os-*' --no-pager
```

You should see:
- `agent-os-saga.service` — task tracker (HTTP/SSE on :3851)
- `agent-os-telegram-mcp.service` — Telegram bot bridge (HTTP/SSE on :3848)
- `agent-os-operator.service` — the operator (Claude Code in a tmux session)
- `agent-os-dispatcher.timer` — fires every 45 minutes
- `agent-os-dispatcher.service` — oneshot dispatcher run (only active during a fire)

To peek at what the operator is doing:

```bash
# The operator service runs with PrivateTmp=yes for hardening, so its tmux
# socket lives inside a private /tmp namespace — `sudo -u agent-os tmux
# attach` from your shell will report "no sessions" even though the operator
# is healthy. Enter the unit's mount namespace first:
sudo nsenter -t "$(systemctl show -p MainPID --value agent-os-operator.service)" -m -- \
  sudo -u agent-os tmux attach -t operator
# Ctrl+B then D to detach without killing.
```

## Next steps

- **Customise the operator's behaviour** — edit `/opt/agent-os/claude/agents/operator/CLAUDE.md` on the droplet (or fork the template and edit there) to give the operator a project-specific persona.
- **Add admins** — `sqlite3 /opt/agent-os/claude/plugins/telegram/messages.db "UPDATE users SET status='allowed' WHERE user_id=<chat_id>"` after they `/start` the bot.
- **Schedule recurring tasks** — heartbeat dispatcher reads from saga-mcp's task list and runs todos in priority order. Create a task with `mcp__saga-mcp__task_create` from the operator session.
- **Read the architecture** — [ARCHITECTURE.md](./ARCHITECTURE.md) explains the 3-tier process model, channel push design, and why we ended up with the architecture we did.

## Help / something broke

- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — top symptoms with diagnoses.
- `sudo bash /opt/agent-os/claude/scripts/verify.sh` — health check across 50+ checkpoints.
- File an issue with the verify output: <https://github.com/try-agent-os/claude-code-template/issues>
