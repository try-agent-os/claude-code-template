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
| `agent-os-operator-watchdog.service` | `oneshot` | Restarts the operator on any of five independent signals (`scripts/operator-watchdog.sh`): **(A)** unanswered-Telegram gap, **(B)** dead/hung tmux pane (no session, shell prompt instead of TUI, subscription-limit banner, dev-channels dialog), **(C)** context bloat — token-% or raw transcript bytes past a threshold, since degraded tool-call emission starts well before the token gauge looks full, **(D)** transcript inactivity above a context floor, **(E)** stuck-composer nudge. Guarded by a cooldown and a cgroup sub-agent check so a proactive restart never kills in-flight work. Triggered by its `.timer`. | n/a |
| `agent-os-operator-watchdog.timer` | timer | Fires the operator watchdog. `OnBootSec=2min`, `OnUnitActiveSec=5min`, `Persistent=true`. | n/a |
| `agent-os-operator-liveness.service` | `oneshot` | Layer-B watchdog for HARD operator death — tmux session gone / `claude` process gone / unit inactive (`scripts/operator-liveness-watchdog.sh`). Complements the soft-hang `operator-watchdog`; recovers within ~60s. All behavior is env-overridable (`OPERATOR_SERVICE`, `OPERATOR_TMUX_SESSION`, …) so the same script can drive per-instance operator watchdogs. | n/a |
| `agent-os-operator-liveness.timer` | timer | Fires the liveness watchdog. `OnBootSec=1min`, `OnUnitActiveSec=1min`, `AccuracySec=5s`, `Persistent=true`. | n/a |
| `agent-os-operator-autocompact.service` | `oneshot` | Silence-restart detector (`scripts/operator-autocompact/detect-and-restart.sh`): restarts the operator after `AUTOCOMPACT_THRESHOLD_MIN` of user silence so it comes back on a fresh context window. Opt-in — not enabled by `install.sh`; set `OPERATOR_CHAT_ID` in the env file first. | n/a |
| `agent-os-operator-autocompact.timer` | timer | Fires the silence detector. `OnBootSec=3min`, `OnUnitActiveSec=2min`, `Persistent=true`. | n/a |
| `agent-os-operator-autocompact-cleanup.service` | `oneshot` | Retention for operator snapshots (`scripts/operator-autocompact/cleanup-snapshots.sh`) — deletes `memory/operator-snapshots/*.md` older than `AUTOCOMPACT_RETAIN_DAYS` (default 7). Runs as the agent user and logs to the journal, not to the root-owned detector log. | n/a |
| `agent-os-operator-autocompact-cleanup.timer` | timer | Nightly snapshot cleanup. `OnCalendar=*-*-* 03:30:00`, `Persistent=true`. | n/a |
| `agent-os-dagu.service` | `simple` | Dagu — the local routines (cron) engine. Runs `dagu start-all` (scheduler + web UI on `127.0.0.1:8080` + coordinator), firing every `routines/*.yaml` on its schedule. Installed + enabled by `install.sh` (binary in Step 9.5); runs even under `--minimal`. | `on-failure`, `RestartSec=5` |
| `agent-os-dagu-watchdog.service` | `oneshot` | Out-of-band watchdog for the Dagu scheduler (`scripts/dagu-watchdog.sh`): restarts `agent-os-dagu.service` when its proof-of-life heartbeat file (written by `routines/dagu-heartbeat.yaml`) goes stale >15 min. | n/a |
| `agent-os-dagu-watchdog.timer` | timer | Fires the Dagu watchdog. `OnBootSec=5min`, `OnUnitActiveSec=10min`, `Persistent=true`. | n/a |

**Removed in T06-amend (plugin migration):**
- `agent-os-claude-peers.service` — claude-peers is now a stdio MCP plugin
  (`plugins/claude-peers`); broker daemon is auto-bootstrapped from
  `server.ts` on first plugin spawn.
- `agent-os-telegram.service` — telegram is now a stdio MCP plugin
  (`plugins/telegram`), spawned per session by Claude Code itself.

**Removed in the worker-migration (LLM dispatcher → Dagu routines):**
- `agent-os-dispatcher.service` / `agent-os-dispatcher.timer` — the LLM
  heartbeat dispatcher is gone. Worker orchestration is now token-free and
  driven by `agent-os-dagu.service` firing three DAGs: `routines/workers.yaml`
  (launcher, every 5 min), `routines/worker-supervisor.yaml` (supervision,
  every 1 min), and `routines/strategist.yaml` (daily).

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
| `{CLAUDE_CONFIG_DIR_OPERATOR}` / `{CLAUDE_CONFIG_DIR_DISPATCHER}` / `{CLAUDE_CONFIG_DIR_HEARTBEAT}` | `/var/lib/agent-os/claude-config/<role>/` | Per-agent config dir (one per role: operator, dispatcher, heartbeat), prevents a race on shared `~/.claude.json` files. `agent-os-dagu.service` uses the `heartbeat` dir. |

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
  agent-os-dagu.service
```

To inspect or tail logs:

```bash
sudo systemctl status agent-os-* --no-pager
sudo journalctl -u agent-os-operator -f
sudo journalctl -u agent-os-dagu -f          # routines engine (worker DAGs)
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
  This blocks tampering with other users' homes. Operator and dagu/workers need
  write access to `/home/agent-os/.claude` (Claude session state) and
  `/home/agent-os/.config` (mcp/tmux state) — those are explicitly re-added
  via `ReadWritePaths`.
- **`PrivateTmp=yes`** — the unit gets a private `/tmp` and `/var/tmp`
  namespace. Stops cross-process tmpfile leakage and races.
- **`ReadWritePaths=…`** — minimum write surface per role:
  - Long-running MCPs (claude-peers, saga, telegram): `{STATE_DIR}`,
    `{LOG_DIR}`. They only need to write databases and logs.
  - Operator + dagu (which spawns workers): additionally need
    `{INSTALL_ROOT}/claude` (memory writes from Claude sessions),
    `{AGENT_HOME}/.claude` (session state / credentials), `{AGENT_HOME}/.config`
    (MCP per-server state, tmux). Workers need broader write access.
- **`StandardOutput=append:…` / `StandardError=append:…`** — redirect to flat
  files in `{LOG_DIR}` so `tail -f` works without journalctl. journald still
  captures the same stream for `journalctl -u <unit>`.
- **`After=network-online.target` / `Wants=network-online.target`** —
  long-running units that need outbound HTTPS (Claude API, Telegram API) wait
  for the network to be fully online, not just the link.
- **`agent-os-dagu.service` has no `After=` on the task backend** — the
  token-free launcher tick reaches the task backend over plain HTTPS (the
  ClickUp REST API is the reference backend), so it only needs the network
  (`After=network-online.target`), not a local MCP daemon. claude-peers likewise
  needs no `After=` since it is a stdio MCP plugin spawned in-process by Claude
  Code itself. A worker whose tick finds the backend unreachable is a no-op that
  retries next tick (see `scripts/worker-preflight.sh`).

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

### Operator channel plugins

The operator launches Claude Code with
`--channels plugin:claude-peers@agentos plugin:telegram@agentos`. This activates
the channel push capability of the two stdio MCP plugins (peers + telegram),
allowing inbound messages to interrupt the session.

We do **not** use `--dangerously-load-development-channels server:NAME` — that
flag triggers an interactive trust prompt and is only meant for local dev. The
production path is `allowedChannelPlugins` in `managed-settings.json` (written
by `install.sh`) listing the plugin specs:

```json
{
  "channelsEnabled": true,
  "allowedChannelPlugins": [
    "claude-peers@agentos",
    "telegram@agentos"
  ]
}
```

With those entries managed-settings sees the plugins as pre-approved, so
`--channels plugin:NAME@agentos` activates their channels without a prompt.
Plugins must be installed and enabled at user scope (or shipped via the
`agentos` marketplace bundled in this template).

### Why `Type=simple` for the routines engine

`agent-os-dagu.service` is a long-running scheduler (`dagu start-all`), so it is
`Type=simple` with `Restart=on-failure`. It stays up and fires the worker DAGs
on their own cron schedules (`routines/workers.yaml` every 5 min,
`routines/worker-supervisor.yaml` every 1 min, `routines/strategist.yaml`
daily) — there is no per-tick systemd unit and no LLM dispatcher to schedule.
The token-free launcher tick spawns one worker per fire; each worker runs in
its own detached tmux session and self-finalizes via `/done` / `/blocked`.

---

## Verification

After install, `scripts/verify.sh` (T07) runs the full health-check matrix.
For ad-hoc inspection:

```bash
# All units active?
systemctl is-active agent-os-saga agent-os-operator agent-os-dagu

# Next worker DAG runs? (Dagu scheduler, not systemd timers)
systemctl status agent-os-dagu --no-pager -n 5

# HTTP endpoints up?
curl -sf http://127.0.0.1:3851/health   # saga-mcp
# (claude-peers broker comes up only when first plugin session spawns —
#  it has no dedicated unit; check via `curl http://127.0.0.1:7899/health`
#  after operator starts.)
```
