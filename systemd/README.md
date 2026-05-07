# systemd units

Linux unit files for the AgentOS three-tier stack. `install.sh` renders these
templates (substituting the placeholders below) and copies them to
`/etc/systemd/system/`.

The macOS counterparts live in [`../launchd/`](../launchd/).

---

## Files

| Unit | Type | Purpose | Restart |
|------|------|---------|---------|
| `agent-os-saga.service` | `simple` | Long-running task tracker MCP (`node dist/index.js`) on `127.0.0.1:3851`. | `always`, `RestartSec=5` |
| `agent-os-operator.service` | `forking` | Wraps `tmux new-session -d -s operator … claude …` so Claude Code stays alive in a detached tmux session. | `on-failure`, `RestartSec=30` |
| `agent-os-dispatcher.service` | `oneshot` | Heartbeat dispatcher — runs `dispatcher.sh` to completion, then exits. Triggered by `agent-os-dispatcher.timer`. | n/a |
| `agent-os-dispatcher.timer` | timer | Fires `agent-os-dispatcher.service` periodically. `OnBootSec=2min`, `OnUnitActiveSec={DISPATCHER_INTERVAL_SEC}sec`. | n/a |

**Removed in T06-amend (plugin migration):**
- `agent-os-claude-peers.service` — claude-peers is now a stdio MCP plugin
  (`plugins/claude-peers`); broker daemon is auto-bootstrapped from
  `server.ts` on first plugin spawn.
- `agent-os-telegram.service` — telegram is now a stdio MCP plugin
  (`plugins/telegram`), spawned per session by Claude Code itself.

---

## Placeholders

`install.sh` uses `sed` to substitute the following tokens before installing
unit files into `/etc/systemd/system/`:

| Placeholder | Default | Meaning |
|-------------|---------|---------|
| `{INSTALL_ROOT}` | `/opt/agent-os` | Root of the AgentOS install (contains `claude/`, `claude-peers-mcp/`, `saga-mcp/`, `telegram-mcp/`). |
| `{STATE_DIR}` | `/var/lib/agent-os` | Persistent state — `saga.db`, `claude-peers.db`. Survives `git pull` / re-clone. |
| `{LOG_DIR}` | `/var/log/agent-os` | Append-only log files. Rotated by host's logrotate. |
| `{AGENT_USER}` | `agent-os` | Dedicated unprivileged user owning the install. |
| `{AGENT_HOME}` | `/home/agent-os` | Home dir of the agent user. Holds `~/.bun/`, `~/.claude/`, etc. |
| `{ENV_FILE}` | `/etc/agent-os/agent-os.env` | Single source of secrets. Mode `0640`, owner `root:agent-os`. |
| `{BUN_PATH}` | `/home/agent-os/.bun/bin/bun` | Absolute path to `bun` (only `claude-peers-mcp` needs it). |
| `{DISPATCHER_INTERVAL_SEC}` | `2700` | Seconds between dispatcher firings (45 min default). |

---

## Manual install (advanced users)

The recommended path is `./install.sh`, which renders + installs everything.
For custom setups:

```bash
# 1. Render placeholders into a staging dir
mkdir -p /tmp/agent-os-units
for f in systemd/agent-os-*.service systemd/agent-os-*.timer; do
  sed \
    -e 's|{INSTALL_ROOT}|/opt/agent-os|g' \
    -e 's|{STATE_DIR}|/var/lib/agent-os|g' \
    -e 's|{LOG_DIR}|/var/log/agent-os|g' \
    -e 's|{AGENT_USER}|agent-os|g' \
    -e 's|{AGENT_HOME}|/home/agent-os|g' \
    -e 's|{ENV_FILE}|/etc/agent-os/agent-os.env|g' \
    -e 's|{BUN_PATH}|/home/agent-os/.bun/bin/bun|g' \
    -e 's|{DISPATCHER_INTERVAL_SEC}|2700|g' \
    "$f" > "/tmp/agent-os-units/$(basename "$f")"
done

# 2. Install
sudo install -m 0644 /tmp/agent-os-units/*.service /etc/systemd/system/
sudo install -m 0644 /tmp/agent-os-units/*.timer  /etc/systemd/system/
sudo systemctl daemon-reload

# 3. Enable + start
sudo systemctl enable --now \
  agent-os-saga.service \
  agent-os-operator.service \
  agent-os-dispatcher.timer
```

To inspect or tail logs:

```bash
sudo systemctl status agent-os-* --no-pager
sudo journalctl -u agent-os-operator -f
tail -f /var/log/agent-os/dispatcher.log
```

To attach to the operator tmux session for interactive debugging:

```bash
sudo -u agent-os tmux attach -t operator
```

---

## Hardening rationale

Every long-running and one-shot unit applies a baseline of systemd sandboxing.
Per-directive notes:

- **`User=agent-os` / `Group=agent-os`** — never run any AgentOS component as
  root. The dedicated user owns `/opt/agent-os/*`, `/var/lib/agent-os/*`, and
  `/home/agent-os/`. A compromised Claude session cannot escalate.
- **`NoNewPrivileges=yes`** — child processes cannot gain new privileges via
  setuid binaries. Defense-in-depth in case `claude` or an MCP shells out to a
  setuid helper.
- **`ProtectSystem=strict`** — the entire filesystem is read-only to the unit
  except for `/dev`, `/proc`, `/sys`, and explicit `ReadWritePaths`. Any write
  outside the allowlist (e.g. accidental `/etc` modification) fails.
- **`ProtectHome=read-only`** — `/home`, `/root`, `/run/user` are read-only.
  This blocks tampering with other users' homes. Operator and dispatcher need
  write access to `/home/agent-os/.claude` (Claude session state) and
  `/home/agent-os/.config` (mcp/tmux state) — those are explicitly re-added
  via `ReadWritePaths`.
- **`PrivateTmp=yes`** — the unit gets a private `/tmp` and `/var/tmp`
  namespace. Stops cross-process tmpfile leakage and races.
- **`ReadWritePaths=…`** — minimum write surface per role:
  - Long-running MCPs (claude-peers, saga, telegram): `{STATE_DIR}`,
    `{LOG_DIR}`. They only need to write databases and logs.
  - Operator + dispatcher: additionally need `{INSTALL_ROOT}/claude` (memory
    writes from Claude sessions), `{AGENT_HOME}/.claude` (session state /
    credentials), `{AGENT_HOME}/.config` (MCP per-server state, tmux). These
    are workers — they need broader write access.
- **`StandardOutput=append:…` / `StandardError=append:…`** — redirect to flat
  files in `{LOG_DIR}` so `tail -f` works without journalctl. journald still
  captures the same stream for `journalctl -u <unit>`.
- **`After=network-online.target` / `Wants=network-online.target`** —
  long-running units that need outbound HTTPS (Claude API, Telegram API) wait
  for the network to be fully online, not just the link.
- **`After=agent-os-saga.service`** on the dispatcher — workers need
  saga-mcp alive before firing, otherwise `mcp__saga-mcp__*` calls fail.
  claude-peers needs no `After=` since it is a stdio MCP plugin spawned
  in-process by Claude Code itself.

### Why `ProtectHome=read-only` instead of `tmpfs`

Workers + operator must read `~/.claude/.credentials.json` (OAuth token
cache) and write `~/.claude/projects/*/conversations.jsonl`. `read-only` lets
them read by default and we explicitly grant write to the subdirs we need via
`ReadWritePaths`. `tmpfs` would isolate the home entirely — too aggressive.

### Why `Type=forking` for the operator

`tmux new-session -d` daemonises immediately (forks the tmux server, parent
exits 0). `Type=forking` tells systemd that the child of the started process
is the long-lived one — it tracks the tmux server PID, restarts the unit if
that PID dies, and `ExecStop=tmux kill-session -t operator` cleanly stops it.

`Type=simple` would not work — systemd would consider the unit "active" only
while the initial `tmux` invocation runs (~milliseconds), then mark it as
exited and not restart.

### Why `Type=oneshot` for the dispatcher

The dispatcher script runs Claude Code workers, completes work, and exits.
`Type=oneshot` makes systemd consider the unit "active (exited)" after a
successful run — exactly what `agent-os-dispatcher.timer` needs to schedule
the next firing. `OnUnitActiveSec=` measures from the previous *activation*,
matching the macOS `StartInterval` semantics (interval since previous start,
not since previous end).

---

## Verification

After install, `scripts/verify.sh` (T07) runs the full health-check matrix.
For ad-hoc inspection:

```bash
# All units active?
systemctl is-active agent-os-saga agent-os-operator agent-os-dispatcher.timer

# Next dispatcher run?
systemctl list-timers agent-os-dispatcher.timer --no-pager

# HTTP endpoints up?
curl -sf http://127.0.0.1:3851/health   # saga-mcp
# (claude-peers broker comes up only when first plugin session spawns —
#  it has no dedicated unit; check via `curl http://127.0.0.1:7899/health`
#  after operator starts.)
```
