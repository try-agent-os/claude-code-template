# Remote Claude Code Setup

Runbook for running Claude Code on a remote machine (VPS / DigitalOcean droplet / Hetzner / etc.).

> **Note.** This runbook covers a *bare-VPS* setup. For the full one-command AgentOS install, see [`install.sh`](../../../install.sh) — it wraps everything below plus systemd units, MCP brokers, and verification.

## SSH alias setup

Configure `~/.ssh/config` on your local machine:

```
Host <ALIAS>
  HostName <IP>
  User root
  IdentityFile ~/.ssh/<KEY_NAME>_ed25519
  IdentitiesOnly yes
```

After this — `ssh <ALIAS>` without flags. `IdentitiesOnly yes` is important: without it the client tries every key in the agent and trips on `MaxAuthTries`.

## Provisioning a new machine

Prerequisites: clean Ubuntu 22.04+ or Debian 12+, root SSH access.

### 1. Connect

```bash
# First time — add your key in the cloud provider UI when creating the droplet
# Then:
ssh -i ~/.ssh/<KEY_NAME>_ed25519 root@<IP>
# Or after configuring ~/.ssh/config:
ssh <ALIAS>
```

### 2. Install the stack

On the server:

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
apt-get install -y nodejs tmux git && \
npm install -g @anthropic-ai/claude-code && \
node --version && claude --version
```

What gets installed:
- **Node.js 20 LTS** via the NodeSource repo
- **tmux** — for persistent sessions (an SSH disconnect won't kill Claude)
- **git** — required for most tasks
- **@anthropic-ai/claude-code** globally

### 3. First launch + authentication

```bash
tmux new -s claude
claude
```

Claude Code prints a URL. Open it on your local machine in a browser, sign in via Anthropic Console / Claude.ai → the token is captured into the SSH session. Credentials live in `~/.claude/` on the server.

Detach: `Ctrl+b` → `d`. Reattach: `tmux attach -t claude`.

## Best practices

- **Always tmux** — SSH connections are unstable; losing an active session = losing context.
- **Credentials are local to the server** — every remote machine goes through OAuth separately. Don't try to copy `~/.claude/` from your local machine.
- **SSH config alias** — set it up at provisioning time so you don't drag `-i ~/.ssh/...` around manually.
- **Use `IdentitiesOnly yes`** in SSH config — otherwise the client tries every key in the agent and hits `MaxAuthTries`.
- **Don't `apt upgrade` immediately** — 100+ MB of kernel/security patches will slow down your first launch. Do it as a separate step when you actually need it.

## What's next (optional)

If a long-running agent will live on the remote machine (heartbeat / operator pattern), you'll want:

1. **systemd service** instead of tmux (analog to launchd on mac)
2. **Logging** to `/var/log/` or journald
3. **Restart-on-failure** in the unit file
4. **Firewall** (`ufw`) if the agent listens on ports

The full AgentOS systemd unit set is provided in `systemd/` — see [`install.sh`](../../../install.sh) for one-command bring-up.
