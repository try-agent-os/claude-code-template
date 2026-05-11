# Troubleshooting

Top issues encountered during real-world deploys, with verified fixes. If your symptom isn't here, check `journalctl -u agent-os-operator.service -n 50` and `/var/log/agent-os/operator-errors.log` for clues.

## Service map (the units that actually exist)

Systemd units installed by `install.sh`:

| Unit | Role | Port |
|------|------|------|
| `agent-os-operator.service` | Long-lived `claude` session in tmux, listens for Telegram via channel push | n/a (stdio + SSE clients to MCPs) |
| `agent-os-saga.service` | Task tracker MCP (HTTP/SSE) | 3851 |
| `agent-os-telegram-mcp.service` | Bot bridge MCP (HTTP/SSE), single Telegram getUpdates poller | 3848 |
| `agent-os-dispatcher.timer` | Heartbeat — fires `dispatcher.sh` every 45 min for scheduled work | n/a |

**There is NO `agent-os-claude-peers.service`.** claude-peers is a stdio-MCP plugin spawned per claude session via `.claude.json mcpServers`. If you're hunting peers logs, look at the operator's claude session output (`tmux attach -t operator`), not systemd. Peer messages are delivered via the operator's MCP `notifications/claude/channel` push, not via a separate broker process.

## Bot doesn't reply to Telegram messages

### Symptom
You send a message to your bot in Telegram. It either does nothing, or replies "Access request submitted. Please wait for approval."

### Diagnosis
Run on the droplet:

```bash
ssh claude
TOKEN=$(grep ^TELEGRAM_BOT_TOKEN= /etc/agent-os/agent-os.env | cut -d= -f2-)
curl -fsS "https://api.telegram.org/bot${TOKEN}/getMe" | jq
sqlite3 /opt/agent-os/claude/plugins/telegram/messages.db "SELECT user_id, username, status FROM users"
```

If `getMe` returns `{"ok":false,"error_code":401}` → your bot token is wrong/revoked. Re-run `claude setup-token` on Mac and update `/etc/agent-os/agent-os.env`.

If users table shows `status='pending'` for your chat ID → admin approval missed. Update:

```bash
sqlite3 /opt/agent-os/claude/plugins/telegram/messages.db \
  "UPDATE users SET status='allowed' WHERE user_id=<YOUR_CHAT_ID>"
```

### Root cause
`TELEGRAM_ADMIN_USER_IDS` was empty in `/etc/agent-os/agent-os.env` when telegram-mcp first started — it had no admins to seed. Three fixes layered: install.sh validates token format + live `getMe` check at the prompt; the Mac wizard's `/start`-polling step seeds `TELEGRAM_ADMIN_USER_IDS` from each admin's reply; and as of v0.1.1 install.sh's Step 2 preflight aborts if both `TG_ADMIN_USER_IDS` and `TG_USER_ID` are empty (unless `--minimal` is passed).

## Operator service stuck "activating", restart loop with `status=1/FAILURE`

### Symptom
`systemctl is-active agent-os-operator.service` returns `activating` for >30s, then `failed`. Repeats every ~30s.

### Diagnosis
```bash
journalctl -u agent-os-operator.service -n 30 --no-pager
```

Look for one of:
- `pututline: Permission denied` → tmux's setuid utempter blocked. Fix in `f4c7d73`: unit has `NoNewPrivileges=no`.
- `Failed to set up mount namespacing: /home/agent-os/.config: No such file or directory` → install bug, fix in `8899443`.
- `Read-only file system` on `/var/run/utmp` → ProtectSystem=strict edge case, mostly resolved.

If on a brand new install, just `git pull` the template and re-run install — fixes are cumulative.

## Operator pane shows blocking dialog (theme picker, workspace trust, bypass-permissions warning)

### Symptom
`tmux attach -t operator` shows claude in a TUI dialog instead of the main UI. Service active but unresponsive.

### Root cause + fix
claude-code 2.1.x shows three first-run dialogs that don't auto-accept under systemd. Fix in `91377ca` (`.claude-config.template.json`):

```json
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "hasInitialThemeSetup": true,
  "hasCompletedAuthSetup": true,
  "theme": "dark-daltonized",
  "projects": {
    "/opt/agent-os/claude/agents/operator": {"hasTrustDialogAccepted": true}
  }
}
```

The "Loading development channels" warning has no persistence flag — auto-dismissed via systemd `ExecStartPost` that fires Enter into the tmux session 7s after start (commit `85f1cd4`).

## "plugin:claude-peers@agentos · not on the approved channels allowlist"

### Symptom
Operator pane shows `Listening for channel messages from: plugin:...` followed by `· not on the approved channels allowlist` for each plugin. Bot connection appears up but no messages get pushed to the operator session.

### Root cause
claude-code 2.1.x gates `--channels plugin:<name>@<marketplace>` behind a server-side allowlist (the `tengu_harbor_ledger` GrowthBook flag, enterprise-only on personal/Pro/Max plans).

### Fix
Use `server:` prefix instead of `plugin:` in the `--dangerously-load-development-channels` flag (commit `58827f2`). The `server:` path matches MCP server names in `.mcp.json` / mcpServers, not plugin marketplace IDs, and is dev-mode-tagged automatically:

```bash
claude --dangerously-skip-permissions \
  --dangerously-load-development-channels server:telegram \
  --dangerously-load-development-channels server:claude-peers
```

This requires telegram-mcp + claude-peers to be registered as MCP servers (not just plugins). Template does this via project `.mcp.json` (telegram + saga as SSE) and user `.claude.json mcpServers` (claude-peers as stdio).

## telegram-mcp `SqliteError: unable to open database file`

### Symptom
`/mcp` shows `telegram · ✘ failed`. journalctl shows `SqliteError: unable to open database file`.

### Root cause
telegram-mcp opens `messages.db` via relative path. When claude-code spawns it as stdio MCP, cwd is the operator dir, not the plugin dir.

### Fix
Run telegram-mcp as a standalone systemd service with `WorkingDirectory=/opt/agent-os/claude/plugins/telegram` (commit `58827f2`, `agent-os-telegram-mcp.service`). Operator connects via SSE per project `.mcp.json`.

## Re-running install.sh keeps the old token in `/etc/agent-os/agent-os.env`

### Symptom
You re-ran install.sh with a corrected `TELEGRAM_BOT_TOKEN` (or `CLAUDE_CODE_OAUTH_TOKEN`), but the env file still has the old wrong value.

### Root cause
install.sh's Step 2 wizard sourced the existing env file via `set -a; . "$ENV_FILE"; set +a`, which clobbered the freshly-passed env vars from SSH. So Step 11 re-wrote the OLD value.

### Fix
Commit `91377ca` saves originals before sourcing and restores them after — file values now only fill in MISSING vars, never override incoming ones. If you're on an older install, manually edit `/etc/agent-os/agent-os.env` and `systemctl restart agent-os-operator.service` (env is read at start, not live).

## `claude setup-token` opens browser but doesn't show the token

### Symptom
`claude setup-token` opens login URL, you authenticate, browser redirects somewhere, terminal goes silent. No `sk-ant-oat01-...` printed.

### Workaround
Use `ANTHROPIC_API_KEY` instead. Get one at <https://console.anthropic.com/settings/keys>. Format `sk-ant-api03-...`. Set in `/etc/agent-os/agent-os.env`:

```ini
ANTHROPIC_API_KEY=sk-ant-api03-...
```

install.sh accepts both `sk-ant-oat01-` and `sk-ant-api03-` formats (commit `1ad1cf4`).

## install.sh aborts at Step 5 with `claude-code (signed apt repo)` 404

### Symptom
Step 5/18 fails with `Reading package lists... failed: 404 Not Found` on `downloads.claude.ai/claude-code/apt/...`.

### Root cause
Wrong apt URL. Anthropic's canonical path is now `…/apt/stable stable main` (with `/stable` channel suffix), not `…/apt stable main`.

### Fix
Already fixed in `25dc362` + `fd1236e`. If you're on an older install.sh, `git pull` the template and re-run.

## I don't have an Anthropic Pro/Max plan — does this work on personal account?

Yes. The channel-push gate that blocks `plugin:` channels is enterprise-only — but our template uses `server:` syntax via `--dangerously-load-development-channels` which works on every plan. Verified end-to-end on a personal Anthropic account with `@axionagentbot`.

## Where do logs live?

```
/var/log/agent-os/operator.log              # operator stdout (mostly empty — claude has its own)
/var/log/agent-os/operator-errors.log       # operator stderr
/var/log/agent-os/telegram-mcp.log          # bot polling, incoming msgs
/var/log/agent-os/saga-mcp.log              # task tracker
/var/log/agent-os/dispatcher.log            # heartbeat dispatcher
journalctl -u agent-os-operator.service     # systemd unit log
```

Inside operator's tmux session: `sudo nsenter -t "$(systemctl show -p MainPID --value agent-os-operator.service)" -m -- sudo -u agent-os tmux attach -t operator` (use `Ctrl+B D` to detach without killing). The plain `sudo -u agent-os tmux attach -t operator` does not work — see "tmux attach says 'no sessions'" below.

## `tmux attach -t operator` says "no sessions" but service is active

### Symptom
`systemctl is-active agent-os-operator.service` prints `active`, the unit's tmux server PID is alive (`systemctl show -p MainPID --value agent-os-operator.service`), but `sudo -u agent-os tmux attach -t operator` reports `no sessions` or `error connecting to /tmp/tmux-997/default (No such file or directory)`.

### Root cause
The operator unit runs with `PrivateTmp=yes`, which gives it an isolated `/tmp` mount namespace for hardening. tmux puts its socket at `/tmp/tmux-$UID/default` — but inside the unit's namespace, not the one your shell sees.

### Fix
Enter the operator unit's mount namespace before invoking tmux:

```bash
sudo nsenter -t "$(systemctl show -p MainPID --value agent-os-operator.service)" -m -- \
  sudo -u agent-os tmux attach -t operator
```

`Ctrl+B D` to detach. To peek without attaching, swap `attach -t operator` for `capture-pane -t operator -p`.

## claude TUI renders monochrome inside zellij (status-bar still colored)

### Symptom
You're hosting an interactive `claude` session inside a zellij pane (some deployments run sysadmin this way instead of tmux). Zellij's own UI — status bar, pane frames — is colored. `ls --color=always` inside any zellij pane prints with colors. But the claude TUI itself renders in a single foreground color: borders, syntax, diff highlights are all the same shade. Switching `theme` in `~/.claude/settings.json` (`dark` ↔ `light` ↔ `*-daltonized`) changes nothing.

### Diagnosis
Run from inside the claude pane:
```bash
ZPID=$(pgrep -f "/.local/bin/claude --dangerously"); cat /proc/$ZPID/environ | tr '\0' '\n' | grep -iE "^TERM|^COLOR"
```
If you see `TERM=xterm-256color` and `COLORTERM=truecolor`, env is "correct" — and that's the trap.

### Root cause
chalk (under Ink, under claude's TUI) reads `COLORTERM=truecolor` and emits 24-bit escape sequences (`ESC[38;2;R;G;Bm`). Zellij's outbound passthrough or the SSH client (e.g. Termius) drops 24-bit sequences but happily forwards 256-color ones (`ESC[38;5;Nm`). Result: every color claude emits gets zeroed, the UI degenerates to a single shade. Zellij's own widgets stay colored because they use the ANSI-16 base palette.

The same env on `tmux-256color` (operator) does **not** trigger this, because tmux doesn't have `COLORTERM=truecolor` set by default — chalk falls back to 256-color emission, which passes through unchanged.

### Fix
Pin chalk to 256-color emission inside the zellij pane by unsetting `COLORTERM` and forcing `FORCE_COLOR=2`. In your zellij layout (e.g. `~/.config/zellij/layouts/sysadmin.kdl`):

```kdl
layout {
    pane command="/bin/zsh" {
        args "-lc" "export TERM=xterm-256color; unset COLORTERM; export FORCE_COLOR=2; exec /home/agent-os/.local/bin/claude --dangerously-skip-permissions --dangerously-load-development-channels server:claude-peers"
        cwd "/opt/agent-os/claude/agents/sysadmin"
    }
    pane size=1 borderless=true {
        plugin location="zellij:status-bar"
    }
}
```

After editing the layout, `zellij delete-session <name> --force` and start fresh — pane env is captured at server start and detach/attach won't pick up changes.

Why this specific combo: the `export TERM=xterm-256color` survives `exec` so claude detects a 256-capable terminal; `unset COLORTERM` removes the truecolor advertisement; `FORCE_COLOR=2` tells chalk explicitly to emit at level 2 (256 colors) instead of probing and re-discovering truecolor through other heuristics.

Fewer total hues than truecolor, but they actually render — and at TUI distances the difference is invisible. If your outer terminal genuinely supports 24-bit (e.g. WezTerm, Alacritty, iTerm2 in truecolor mode) and you've verified passthrough end-to-end, you can skip this fix; the problem is specific to chains where 24-bit silently drops.

## Still broken?

Open an issue with:
- `sudo -u agent-os bash /opt/agent-os/claude/scripts/verify.sh` output (the script refuses to run as root)
- `journalctl -u agent-os-operator.service -n 50 --no-pager`
- `tmux capture-pane -t operator -p` while attached
- The exact step number install.sh aborted at

<https://github.com/try-agent-os/claude-code-template/issues>
