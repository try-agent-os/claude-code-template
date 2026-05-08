# Architecture

How `claude-code-template` is built and why. Read this if you want to modify the system, port it to another OS, or just understand what `install.sh` is doing.

For the user-facing tour, see [README.md](./README.md). For upgrade procedures, see [UPGRADING.md](./UPGRADING.md).

---

## 1. Overview — three tiers

The whole stack is three concentric layers, each with a different lifetime:

```
┌────────────────────────────────────────────────────────────────────┐
│ Tier 3 — supervision (systemd / launchd)                           │
│   Long-lived processes. Survives reboot. Restart-on-failure.       │
│   ─ agent-os-saga.service       (always-on, MCP HTTP broker)       │
│   ─ agent-os-operator.service   (always-on, Claude Code in tmux)   │
│   ─ agent-os-dispatcher.timer + .service  (oneshot, every 45 min)  │
└────────────────────────────────────────────────────────────────────┘
                            │ spawns
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│ Tier 2 — Claude Code processes                                     │
│   Started by Tier 3, owns its own session JSONL + plugin set.      │
│   Each agent has its own CLAUDE_CONFIG_DIR for isolation.          │
│   ─ operator session (interactive, --channels)                     │
│   ─ dispatcher session (oneshot, headless)                         │
│   ─ heartbeat session (forked by dispatcher.sh per cycle)          │
└────────────────────────────────────────────────────────────────────┘
                            │ stdio spawn / HTTP+SSE
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│ Tier 1 — MCP layer                                                 │
│   ─ saga-mcp           HTTP+SSE on 127.0.0.1:3851                  │
│   ─ claude-peers       stdio plugin + auto-bootstrapped broker     │
│                          on 127.0.0.1:7899                         │
│   ─ telegram           stdio plugin (long-poll Bot API)            │
│   ─ Anthropic plugins  agent-sdk-dev, code-review, commit-commands,│
│                          security-guidance (commands, hooks, agents)│
└────────────────────────────────────────────────────────────────────┘
```

The key inversion vs naive designs: **claude-peers and telegram are not separate services**. They are stdio MCP plugins that Claude Code spawns per session via plugin discovery. The only state that needs to survive between sessions — the peers broker — is a daemon auto-spawned from `plugins/claude-peers/server.ts` on first plugin instantiation, listening on `:7899`. saga-mcp remains a standalone broker because it serves multiple unrelated Claude Code sessions and benefits from HTTP reconnect with backoff (stdio MCP servers are not auto-reconnected by Claude Code — see [03-mcp-hooks-channels.md §1](https://github.com/try-agent-os/claude-code-template) for the spec details).

---

## 2. Component diagram

```
┌───────────────────────────── Linux VPS (agent-os user) ────────────────────────┐
│                                                                                │
│  /etc/claude-code/managed-settings.json   ← root-owned, hard org policy        │
│    sandbox.enabled, channelsEnabled, allowedChannelPlugins,                    │
│    enabledPlugins, minimumVersion, permissions.deny                            │
│                                                                                │
│  /etc/agent-os/agent-os.env               ← root:agent-os, mode 0640           │
│    CLAUDE_CODE_OAUTH_TOKEN, TELEGRAM_BOT_TOKEN, ...                            │
│                                                                                │
│  ┌───────────────────────────── systemd ─────────────────────────────────┐     │
│  │                                                                       │     │
│  │  agent-os-saga.service         agent-os-operator.service              │     │
│  │  ┌──────────────────┐          ┌────────────────────────────────┐     │     │
│  │  │ node dist/index  │          │ tmux new-session -d -s operator│     │     │
│  │  │ saga-mcp :3851   │◄─SSE────►│  └─ claude --channels          │     │     │
│  │  │ saga.db          │          │       plugin:claude-peers      │     │     │
│  │  └──────────────────┘          │       plugin:telegram          │     │     │
│  │           ▲                    │       (CLAUDE_CONFIG_DIR=...)  │     │     │
│  │           │                    └─────┬────────────────────┬─────┘     │     │
│  │           │                          │ stdio              │ stdio     │     │
│  │           │                          ▼                    ▼           │     │
│  │           │                  ┌────────────────┐  ┌─────────────────┐  │     │
│  │           │                  │ claude-peers   │  │ telegram (bun)  │  │     │
│  │           │                  │ MCP plugin     │  │ MCP plugin      │  │     │
│  │           │                  │  (server.ts)   │  │  (long-poll)    │  │     │
│  │           │                  └─────┬──────────┘  │  whisper.cpp    │  │     │
│  │           │                        │ HTTP        │  yt-dlp         │  │     │
│  │           │                        ▼             └────────┬────────┘  │     │
│  │           │                  ┌──────────────┐             │           │     │
│  │           │                  │ peers broker │             │           │     │
│  │           │                  │ daemon :7899 │             │           │     │
│  │           │                  │ (auto-spawn) │             │           │     │
│  │           │                  └──────────────┘             │           │     │
│  │           │                                               │           │     │
│  │           │                                               ▼           │     │
│  │           │                                      ┌──────────────────┐ │     │
│  │           │                                      │ Telegram Bot API │ │     │
│  │           │                                      │ (long-polling)   │ │     │
│  │           │                                      └──────────────────┘ │     │
│  │           │                                                           │     │
│  │  agent-os-dispatcher.timer  ──fires──►  agent-os-dispatcher.service   │     │
│  │  (OnUnitActiveSec=2700)                  Type=oneshot, runs           │     │
│  │                                          dispatcher.sh ➜ exits        │     │
│  └───────────────────────────────────────────────────────────────────────┘     │
│                                                                                │
│  /opt/agent-os/                            /var/lib/agent-os/                  │
│   ├── claude/  (this template)              ├── saga.db                        │
│   │    ├── .claude/    (project hooks)      ├── claude-peers.db                │
│   │    ├── plugins/    (vendored)           └── claude-config/                 │
│   │    └── agents/                                ├── operator/                │
│   └── saga-mcp/                                   │   ├── .claude.json         │
│                                                   │   └── .credentials.json    │
│                                                   ├── dispatcher/              │
│                                                   └── heartbeat/               │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. The `.claude/` directory

### Settings cascade

Three scopes, each merged into the next:

| Scope | Path | Owner | Purpose |
|-------|------|-------|---------|
| Managed | `/etc/claude-code/managed-settings.json` | `root:root` | Hard org policy — cannot be overridden |
| Project | `<repo>/.claude/settings.json` | committed | Team rules, hook wiring, additionalDirectories |
| User | `~/.claude/settings.json` | per agent user | Personal defaults (model, env, cleanup) |

CLI flags (`--settings`, `--permission-mode`) and `<repo>/.claude/settings.local.json` (gitignored) sit between project and managed in precedence — see Anthropic's [settings docs](https://code.claude.com/docs/en/settings) for the full ordering. Arrays merge across all scopes (so a deny from managed PLUS a deny from project both apply); scalars take the most-specific value.

### What lives where

The template ships `.claude/settings.json` with:

- `permissions.deny` — repo-specific patterns (read/edit `.env*`, lockfiles, `.git/`, dangerous sudo)
- `permissions.ask` — git push/rebase, package publish, `sudo systemctl`, `WebFetch`
- `permissions.allow` — common dev tooling (npm/yarn/pnpm/git read-only/cargo/go)
- `permissions.additionalDirectories` — `./docs`, `./scripts`, `./memory` (so subagents can reach them without prompts)
- `hooks` — wiring for the 8 lifecycle scripts (next section)
- `attribution.commit: true`, `attribution.pr: true`

Catastrophic patterns (`rm -rf /`, fork bomb, etc.) live in [`managed-settings.template.json`](./managed-settings.template.json) and are NOT duplicated in `.claude/settings.json` — that's the point of the layered model.

### Trust

When a Claude Code session starts in a directory with `.claude/settings.json`, `.mcp.json`, or hooks, the user must grant trust before any of it loads. For headless / VPS use the installer pre-trusts the project by writing the trust decision into each agent's `~/.claude.json` (per `CLAUDE_CONFIG_DIR`).

---

## 4. Plugins

This template ships its own private marketplace, `agentos`, declared in [`.claude-plugin/marketplace.json`](./.claude-plugin/marketplace.json). All plugins are vendored (`./plugins/<name>/`), pinned to specific upstream commits — see [`plugins/VENDORING.md`](./plugins/VENDORING.md) for refresh policy and exclusions (`.git/`, `node_modules/`, runtime DBs, Whisper models).

### Inventory

| Plugin | Type | Provides | Channel-capable |
|--------|------|----------|-----------------|
| [`claude-peers`](./plugins/claude-peers) | Single-server stdio MCP | `send_message`, `list_peers`, `set_summary`, `check_messages` tools + `claude/channel` push from broker | Yes |
| [`telegram`](./plugins/telegram) | Single-server stdio MCP | `telegram_send_message`, `telegram_reply`, `telegram_react`, `telegram_search_messages`, etc. + `claude/channel` push from long-poll | Yes |
| [`agent-sdk-dev`](./plugins/agent-sdk-dev) | Commands + agents | `/new-sdk-app` command, `agent-sdk-verifier-{ts,py}` agents | No |
| [`code-review`](./plugins/code-review) | Command | `/code-review` (parallel multi-agent PR review with confidence scoring) | No |
| [`commit-commands`](./plugins/commit-commands) | Commands | `/commit`, `/commit-push-pr`, `/clean_gone` | No |
| [`security-guidance`](./plugins/security-guidance) | Hook | PreToolUse hook (`security_reminder_hook.py`) flagging command injection / XSS / unsafe patterns | No |

Two more entries in the marketplace are placeholders for future tasks: `template-dev@agentos` (sync skill) and `agentos-core@agentos` (slash commands).

### Marketplace structure

```
.claude-plugin/marketplace.json     ← the index
plugins/
  claude-peers/
    .claude-plugin/plugin.json      ← name, version, description, mcpServers, userConfig
    mcp.json                        ← `${CLAUDE_PLUGIN_ROOT}/server.ts` via bun
    server.ts, broker.ts, ...
    package.json, bun.lock
  telegram/
    .claude-plugin/plugin.json      ← + userConfig: bot_token (sensitive), user_id
    mcp.json
    src/, dist/                     ← dist/ vendored (precompiled JS)
  agent-sdk-dev/, code-review/, commit-commands/, security-guidance/
    .claude-plugin/plugin.json
    commands/ | agents/ | hooks/    ← upstream Anthropic-format plugin
```

The two channel plugins (`claude-peers`, `telegram`) are **single-server** plugins — one stdio MCP server exposes both tool calls AND the `claude/channel` capability. Operator gets push (when launched with `--channels plugin:NAME@agentos`); other agents that don't pass `--channels` see the same plugin as a tools-only MCP server.

### Enablement

`enabledPlugins` lives in `managed-settings.json` (org-wide enforcement):

```json
"enabledPlugins": [
  "claude-peers@agentos",
  "telegram@agentos",
  "agent-sdk-dev@anthropic",
  "code-review@anthropic",
  "commit-commands@anthropic",
  "security-guidance@anthropic"
]
```

`strictKnownMarketplaces: ["./.claude-plugin/marketplace.json"]` ensures Claude Code only trusts the bundled marketplace — no drive-by installs from unknown sources. Note this list contains a path relative to project root; managed-settings is normally root-owned, but the path resolves at run time against the active project.

---

## 5. Channel push

### Why push, why stdio

Claude Code can be configured to listen for **push notifications** from MCP servers (the `claude/channel` capability). When an event arrives, Claude Code injects it into the active session as a `<channel>` message and the agent responds inline. This is the mechanism that lets Telegram messages and inter-agent peer-to-peer comms appear instantly inside the operator's session, instead of being polled.

The official spec supports stdio AND HTTP/SSE channel transports. We ship **stdio** plugins for two reasons:

1. **Lifecycle simplicity.** A stdio plugin is spawned and reaped by Claude Code per session. No long-lived service to start in the right order, no port conflicts, no health check before session start.
2. **No reconnect required.** stdio MCP servers cannot auto-reconnect, but for a plugin process whose lifetime is tied to the session, that's fine — when the session ends, the plugin dies with it. saga-mcp remains HTTP because its lifetime is *longer* than any single Claude Code session and it benefits from auto-reconnect.

### Why operator gets `--channels` and others don't

Channel push is opt-in per session via `--channels plugin:NAME@agentos`. Without that flag, the same plugin is a tools-only MCP server. Only the operator needs incoming pushes (it's the human-facing Telegram bridge); the dispatcher is one-shot and headless.

The operator's systemd unit launches Claude Code with:

```
--channels plugin:claude-peers@agentos plugin:telegram@agentos
```

This activates `claude/channel` for those plugins. Approval is pre-granted via `allowedChannelPlugins` in managed-settings.json — see the rationale section in [`systemd/README.md`](./systemd/README.md) for why we don't use `--dangerously-load-development-channels server:NAME` (it triggers an interactive trust prompt; `--channels plugin:` does not when the plugin is in `allowedChannelPlugins`).

### Inbound message flow (Telegram example)

```
User taps message in Telegram
   │
   ▼
Telegram Bot API
   │  (long polling)
   ▼
plugins/telegram/dist/index.js  (running inside operator session as stdio plugin)
   │  emits notifications/claude/channel notification
   ▼
Operator session (Claude Code)  ← <channel source="telegram" ...> arrives
   │  Claude sees the channel message, responds via telegram_reply tool
   ▼
plugins/telegram tool handler  ➜  Telegram Bot API  ➜  user's screen
```

---

## 6. Hooks

The template ships 8 lifecycle hook scripts under [`.claude/hooks/`](./.claude/hooks), wired into [`.claude/settings.json`](./.claude/settings.json). Each is a standalone bash script that reads stdin (Claude Code passes the hook payload as JSON), parses what it needs via `jq` from the shared `_common.sh` helper, and exits 0 (proceed) or 2 (block — `PreToolUse` only).

### Inventory

| Script | Event | Matcher | Async | Default behaviour |
|--------|-------|---------|-------|-------------------|
| `boot.sh` | `SessionStart` | `startup`, `compact` | no | Inject `additionalContext` (e.g. health-check summary) |
| `enrich-prompt.sh` | `UserPromptSubmit` | — | no | Inject context based on user prompt |
| `guard-bash.sh` | `PreToolUse` | `Bash` | no | Block destructive commands (security gate) |
| `guard-edit.sh` | `PreToolUse` | `Edit\|Write\|MultiEdit` | no | Block edits to forbidden paths |
| `log-action.sh` | `PostToolUse` | `Edit\|Write\|MultiEdit` | yes | Run formatter (if any) + append audit log |
| `log-subagent.sh` | `SubagentStop` | — | yes | Append subagent transcript summary to audit log |
| `notify-stop.sh` | `Stop` | — | yes | If `OPERATOR_PEER_ID` set: notify operator session ended |
| `session-end.sh` | `SessionEnd` | — | yes | Final wrap-up notify |

`_common.sh` is a shared library, **not a hook itself**. It exports `read_input`, `log`, `json` (jq wrapper), `tool_input_field`, `block`, `allow_with_context`, `is_stop_loop`. All hooks source it.

### Loop guards

Both `Stop` and `SubagentStop` can re-fire if a hook returned feedback. Each script calls `is_stop_loop` first and exits 0 if `stop_hook_active=true`. Without this, an infinite loop would occur. See [`.claude/hooks/README.md`](./.claude/hooks/README.md) for the full contract.

### Env vars consumed

| Var | Used by | Default | Purpose |
|-----|---------|---------|---------|
| `OPERATOR_PEER_ID` | `notify-stop`, `session-end` | (unset → silent skip) | Target peer for notification |
| `CLAUDE_PEERS_API_URL` | `notify-stop`, `session-end` | `http://127.0.0.1:7899/send-message` | Broker REST API |
| `CLAUDE_PEERS_HEALTH_URL` | `boot` | `http://127.0.0.1:7899/health` | Health-check endpoint |
| `SAGA_MCP_HEALTH_URL` | `boot` | `http://localhost:3851/health` | Health-check endpoint |
| `TELEGRAM_MCP_HEALTH_URL` | `boot` | (unset → skipped) | Optional |
| `AGENTOS_HOOKS_LOG_DIR` | all | `/tmp/agentos-hooks` | Per-hook log directory |
| `AGENTOS_AUDIT_LOG` | `log-action`, `log-subagent` | `${CLAUDE_PROJECT_DIR}/.claude/audit.log` | Audit append-log |

systemd units inherit these via `EnvironmentFile=/etc/agent-os/agent-os.env`.

### `--minimal` profile

For minimal deployments the [`.claude/hooks/README.md`](./.claude/hooks/README.md) documents shipping only `_common.sh`, `guard-bash.sh`, `guard-edit.sh` and registering only `PreToolUse` hooks. The current `install.sh` does NOT yet selectively prune the hooks directory — the documentation is forward-looking; the `--minimal` switch only affects systemd units and operator activation.

---

## 7. systemd / launchd parity

### Linux (systemd) — the canonical path

Templates live in [`systemd/`](./systemd/) and are rendered by `install.sh` (placeholders like `{INSTALL_ROOT}`, `{STATE_DIR}`, `{ENV_FILE}` substituted via `sed`) into `/etc/systemd/system/`:

| Unit | Type | Purpose | Restart |
|------|------|---------|---------|
| `agent-os-saga.service` | `simple` | Long-running task tracker MCP. | `always`, `RestartSec=5` |
| `agent-os-operator.service` | `forking` | Wraps `tmux new-session -d` so Claude Code persists. `Type=forking` is required because `tmux -d` daemonises and the parent exits — with `Type=simple` systemd would mark the unit "exited" almost instantly. | `on-failure`, `RestartSec=30` |
| `agent-os-dispatcher.service` | `oneshot` | Heartbeat dispatcher — runs `dispatcher.sh` to completion, exits. | n/a |
| `agent-os-dispatcher.timer` | timer | `OnBootSec=2min`, `OnUnitActiveSec={DISPATCHER_INTERVAL_SEC}sec`. Measures interval since previous *activation* (not previous completion) — matches macOS `StartInterval` semantics. | n/a |

Hardening defaults applied to every unit:

- `User=agent-os` / `Group=agent-os` — never root
- `NoNewPrivileges=yes`
- `ProtectSystem=strict`
- `ProtectHome=read-only` (operator + dispatcher need `~/.claude` and `~/.config` written; those are explicitly listed in `ReadWritePaths`)
- `PrivateTmp=yes`
- `ReadWritePaths={STATE_DIR} {LOG_DIR} {INSTALL_ROOT}/claude {CLAUDE_CONFIG_DIR_*} {AGENT_HOME}/.config`

See [`systemd/README.md`](./systemd/README.md) for the full hardening rationale.

### macOS (launchd) — parity templates, not the canonical path

The supported macOS workflow is **not** to run AgentOS as a long-running stack on the Mac. Instead, `install.sh` detects Darwin (via `detect_mode` — `uname == Darwin`) and dispatches to `exec_remote_setup_wizard`, which provisions/targets a Linux VPS and runs the canonical `install.sh` there over SSH. See [README.md → How it works on Mac](./README.md#how-it-works-on-mac) for the user-facing flow.

[`launchd/`](./launchd/) still contains plist templates (with `${PROJECT_SLUG}` placeholders) for the same supervised processes — kept around for parity with the systemd units and for users who want to experiment with running operator/dispatcher on a Mac directly:

| Plist | Job |
|-------|-----|
| `com.${PROJECT_SLUG}.saga-mcp.plist` | saga-mcp (`KeepAlive=true`) |
| `com.${PROJECT_SLUG}.operator.plist` | Operator (`agents/operator/start.sh`, `KeepAlive.SuccessfulExit=false`) |
| `com.${PROJECT_SLUG}.heartbeat-dispatcher.plist` | Heartbeat dispatcher (`StartInterval=2700`) |
| `com.${PROJECT_SLUG}.claude-peers-broker.plist` | **Stale** — assumes claude-peers is a separate broker, not the current stdio plugin. |
| `com.${PROJECT_SLUG}.telegram-mcp.plist` | **Stale** — same reason. |

`install.sh` does not render or `launchctl load` these plists today — that's intentional, because the supported Mac path is "wizard provisions a Linux VPS", not "stand up launchd on this Mac". If you want a local-Mac deployment you must substitute the placeholders by hand (`${PROJECT_SLUG}`, `${INSTALL_ROOT}`, `${BUN_PATH}`, etc.) and `launchctl load` the result yourself.

### Per-agent CLAUDE_CONFIG_DIR

Each agent role gets its own `~/.claude.json` and `~/.claude/.credentials.json` to prevent races on shared OAuth state when multiple Claude Code processes run on the same box:

```
/var/lib/agent-os/claude-config/operator/
/var/lib/agent-os/claude-config/dispatcher/
/var/lib/agent-os/claude-config/heartbeat/
```

systemd units export `CLAUDE_CONFIG_DIR={CLAUDE_CONFIG_DIR_*}` accordingly. The installer renders `.claude.json` from [`.claude-config.template.json`](./.claude-config.template.json) into each role's dir.

### Why non-root

The `agent-os` system user (created by step 6 of `install.sh`) owns `/opt/agent-os/`, `/var/lib/agent-os/`, `/home/agent-os/`. A compromised Claude Code session — or any subprocess Claude shells out to — runs as `agent-os` and cannot escalate to root. systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`) prevents privilege escalation via setuid binaries.

---

## 8. State directories

| Path | Owner | Mode | Survives `uninstall.sh` (default) | Survives `--purge` |
|------|-------|------|-----------------------------------|--------------------|
| `/opt/agent-os/claude/` | `agent-os:agent-os` | 0755 | Yes | No |
| `/opt/agent-os/saga-mcp/` | `agent-os:agent-os` | 0755 | Yes | No |
| `/var/lib/agent-os/saga.db` | `agent-os:agent-os` | per file | Yes | No |
| `/var/lib/agent-os/claude-peers.db` | `agent-os:agent-os` | per file | Yes | No |
| `/var/lib/agent-os/claude-config/<role>/` | `agent-os:agent-os` | 0750 | Yes | No |
| `/var/log/agent-os/` | `agent-os:agent-os` | 0755 | Yes | No |
| `/etc/agent-os/agent-os.env` | `root:agent-os` | 0640 | Yes | No |
| `/etc/agent-os/install.state.json` | `root:agent-os` | 0640 | Yes | No |
| `/etc/claude-code/managed-settings.json` | `root:root` | 0644 | Yes | No |
| `~agent-os/` (home dir) | `agent-os:agent-os` | 0755 | Yes | No |

Default `uninstall.sh` stops + disables units, deletes `/etc/systemd/system/agent-os-*` files, and that's it. Re-running `install.sh` after a default uninstall picks up state and resumes. `--purge` wipes everything in the table above plus the `agent-os` user (with `userdel -r`).

### `~/.claude/projects/`

Each Claude Code session writes a JSONL transcript to `${CLAUDE_CONFIG_DIR}/projects/<slug>/<session-id>.jsonl`. Auto-cleaned by `cleanupPeriodDays` (set in user `settings.json`, default 30). Worth setting low on a VPS to keep disk in check.

---

## 9. OAuth flow

Anthropic's Claude Code authenticates via either:

- **OAuth token** (`CLAUDE_CODE_OAUTH_TOKEN`, starts with `sk-ant-oat01-`) — bills against your Claude.ai plan. Generate locally with `claude setup-token` (browser-based OAuth, prints a 1-year token).
- **API key** (`ANTHROPIC_API_KEY`, starts with `sk-ant-api...`) — bills per token via Console. From `console.anthropic.com`.

The installer's preferred path is OAuth: tokens are tied to your plan's flat-rate allowance, no per-token surprise.

### Why we don't copy `.credentials.json`

`.credentials.json` is a Claude Code internal cache with refresh tokens, device IDs, and metadata that vary by host. Copying it from your laptop to the VPS works once, then breaks subtly on token refresh. The OAuth-token-via-env path is portable and survives across machines / containers.

The wizard sniffs the pasted token: if it starts with `sk-ant-api`, it's auto-rerouted to `ANTHROPIC_API_KEY` instead.

---

## 10. Sandbox

Claude Code's sandbox is OS-level isolation for the Bash tool — separate from permission rules. The template enforces it via managed settings:

```json
"sandbox": {
  "enabled": true,
  "failIfUnavailable": true
}
```

`failIfUnavailable: true` means Claude Code refuses to run if it can't activate the sandbox — defense-in-depth on a multi-tenant VPS.

| Platform | Sandbox backend | Pre-install requirement |
|----------|-----------------|-------------------------|
| Linux | bubblewrap (`bwrap`) | apt-installed by `install.sh` step 3 |
| macOS | Seatbelt (`sandbox-exec`) | shipped with the OS |
| Inside containers | bubblewrap may not work (no user namespaces) → set `enableWeakerNestedSandbox: true` in managed settings | Containerised installs are out-of-scope for the default template |

The installer additionally installs `socat` (used by some sandbox configurations for proxying allowed network calls).

---

## 11. The `--minimal` profile

Switches off the agent stack, keeps the safety net.

What changes when you pass `--minimal`:

| Layer | Default | `--minimal` |
|-------|---------|-------------|
| systemd units | saga + dispatcher.timer + operator | saga + dispatcher.timer (no operator) |
| Wizard prompts | Telegram bot token + user ID required | skipped |
| `enabledPlugins` (managed) | All 6 | (intent: none, but the current managed-settings template still lists all 6 — install.sh does not yet rewrite the file based on `--minimal`) |
| Channel plugins active | `--channels plugin:claude-peers@agentos plugin:telegram@agentos` | none (no operator, no `--channels` flag) |
| Whisper model | downloaded + built | not built |
| Bundled hooks | All 8 + `_common.sh` shipped to project (intent: ship 3) | All 8 currently shipped (install.sh does not subset) |
| Project `settings.json` hook events | All 7 events | (intent: PreToolUse only — needs install.sh to emit a different settings.json) |

The intended surface area for `--minimal` is documented in [`.claude/README.md`](./.claude/README.md) and [`.claude/hooks/README.md`](./.claude/hooks/README.md). Some of that pruning is documentary today and is tracked as a follow-up to land in `install.sh`.

---

## 12. Operator autonomy — headless permission strategy

The operator agent runs 24/7 on a VPS with no human present. Any interactive permission prompt causes an indefinite freeze. The template applies a layered defence so the operator never blocks:

### Layer 1 — CLI flag (primary)

The systemd unit launches claude with `--dangerously-skip-permissions`. This sets the runtime permission mode to `bypassPermissions`, which makes Claude Code skip every tool-use permission check. It is the strongest and most reliable bypass.

```
ExecStart=/usr/bin/tmux new-session -d -s operator ... \
  'claude --dangerously-skip-permissions ...'
```

### Layer 2 — First-run TUI dialogs (pre-accepted)

Without pre-acceptance, claude shows interactive dialogs on first launch even with `--dangerously-skip-permissions`. The installer pre-fills `${CLAUDE_CONFIG_DIR}/. claude.json` with four flags to suppress them:

| Key | Dialog it skips |
|-----|-----------------|
| `hasCompletedOnboarding: true` | Onboarding flow |
| `bypassPermissionsModeAccepted: true` | "Bypass permissions" warning |
| `hasInitialThemeSetup: true` | Theme picker |
| `hasCompletedAuthSetup: true` | Auth setup screen |

Per-project trust dialogs are suppressed via `projects.<cwd>.hasTrustDialogAccepted: true` for each agent directory.

### Layer 3 — User-scope settings (belt-and-suspenders)

`${CLAUDE_CONFIG_DIR}/settings.json` (rendered from `.claude-settings.template.json`) sets:

- `skipDangerousModePermissionPrompt: true` — disables the startup warning that `--dangerously-skip-permissions` triggers.
- `permissions.allow: ["mcp__*", "Bash", "Read", "Write", ...]` — covers the case where the agent is started without the CLI flag (e.g. during a manual test run).

### Layer 4 — PermissionRequest hook (fallback auto-allow)

`agents/operator/.claude/hooks/permission-allow.sh` is wired as a `PermissionRequest` hook. It auto-allows every tool call if the permission mode is not already `bypassPermissions`. This fires only if layers 1–3 somehow fail to suppress a prompt.

The hook logs any unexpected permission requests to `$AGENTOS_HOOKS_LOG_DIR/operator-permission.log` for post-mortem inspection.

### Layer 5 — PostToolUse audit log

Because `--dangerously-skip-permissions` eliminates interactive checkpoints, visibility into what the operator actually does is important. `agents/operator/.claude/hooks/log-tool-use.sh` is a `PostToolUse` async hook that writes a TSV line for every tool call:

```
2026-05-08T07:40:00Z   <session>   Bash   {"command":"git status"}
```

Logs land in `$AGENTOS_HOOKS_LOG_DIR/operator-tool-calls.log` (default `/tmp/agentos-hooks/` on VPS; controlled by `AGENTOS_HOOKS_LOG_DIR` in `agent-os.env`).

### Trade-off summary

| Approach | Blast radius | Used |
|----------|-------------|------|
| `--dangerously-skip-permissions` | Operator can call any tool — mitigated by VPS egress firewall (`--harden`) and sandbox | ✓ Primary |
| `permissions.allow` in settings | Same tools, but only for listed patterns | ✓ Belt-and-suspenders |
| `PermissionRequest` auto-allow hook | Same as `--dangerously-skip-permissions` when hook fires | ✓ Fallback |
| `--permission-mode auto` | Not a real claude flag (not documented in CLI help) | — |
| PreToolUse `permissionDecision: "allow"` hook | Hooks are not called in `bypassPermissions` mode | — |

The `--harden` installer flag (UFW egress firewall) is the recommended complementary control — it limits network blast radius even if the agent is tricked into running unexpected commands.

---

## Further reading

- [`.claude/README.md`](./.claude/README.md) — settings cascade specifics
- [`.claude/hooks/README.md`](./.claude/hooks/README.md) — hook scripting contract, env vars, testing
- [`systemd/README.md`](./systemd/README.md) — placeholder substitution, hardening rationale, `Type=forking` for tmux
- [`plugins/VENDORING.md`](./plugins/VENDORING.md) — vendored plugin sources, exclusions, refresh policy
- [`.claude-plugin/marketplace.json`](./.claude-plugin/marketplace.json) — plugin index
- Anthropic's [Claude Code docs](https://code.claude.com/docs/en/) — settings, plugins, MCP, channels, hooks
