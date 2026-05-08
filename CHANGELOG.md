# Changelog

All notable changes to this template are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file tracks **template** changes (T-marked files). Per-deployment changes belong in your fork's own changelog.

## [Unreleased]

## [0.1.1] — 2026-05-08

Patch release: fresh-eyes validation on a clean droplet found 5 issues with the v0.1.0 deploy path. None broke an already-running install; all 5 affected first-time deployers in ways the existing test matrix didn't catch.

Highlights:
- `cloud-init.yaml` was silently broken — non-ASCII bytes made the parser skip `runcmd`. The Deploy-to-DigitalOcean button left `/opt/agent-os-bootstrap/` empty.
- Install hardening could lock the operator out of their own droplet (UFW limit ssh + fail2ban combination).
- WHISPER_MODEL env var was ignored, forcing `medium` (1.5 GB, +3 min build).
- TELEGRAM_ADMIN_USER_IDS=empty install completed silently, then the bot ignored everyone.
- Documentation referenced services that aren't actually units.

### Fixed (v0.1.1 — fresh-eyes validation pass)
- `cloud-init.yaml` — strip non-ASCII bytes (em-dashes `U+2014`, box-drawing `┌─│└┘•→`). cloud-init's strict YAML 1.1 parser rejects non-ASCII silently with `unacceptable character #x0080: special characters are not allowed`, which made the parser load the file but skip `runcmd` entirely — the Deploy-to-DigitalOcean button left `/opt/agent-os-bootstrap/` empty, so the user found nothing to run. Now pure 7-bit ASCII (CI enforces this on every push). Verified with `python3 -c "all(b<128 for b in open('cloud-init.yaml','rb').read())"`.
- `.github/workflows/ci.yml` — new yaml-validate steps: ASCII-only check on `cloud-init.yaml` (catches the actual root cause cheaply) plus best-effort `cloud-init devel schema --config-file cloud-init.yaml` lint.
- `install.sh` Step 2 preflight — abort with a clear error if `TG_ADMIN_USER_IDS` and `TG_USER_ID` are both empty AND `--minimal` is not set. Previously install completed "successfully" with an empty allowlist; the bot booted, accepted webhooks, and silently rejected every author — first-time deployers spent 15 minutes trying to figure out why "/start" did nothing. The preflight banner explains both the fix (rerun with `TG_ADMIN_USER_IDS=<your-id>`) and the alternative path (`--minimal` for a no-Telegram install).
- `install.sh` Whisper model — env var `WHISPER_MODEL` was silently overridden in non-interactive mode: the wizard fell through to `medium` (1.5GB, ~3min build) even when SSH passed `WHISPER_MODEL=tiny`. Default lowered to `tiny` (75MB), and all four assignment sites now thread `${WHISPER_MODEL:-tiny}` through every fallback so env-var wins. Users who want full quality can re-run with `WHISPER_MODEL=medium`.
- `install.sh` ingress hardening — `ufw limit ssh/tcp` (rate-limit at 6 conns/30s) replaced with plain `ufw allow ssh/tcp`, because normal post-install SSH status polling from the Mac wizard tripped the limiter and the user's own IP got jailed for 10+ min by fail2ban (survived a power-cycle, since both UFW and fail2ban persist). fail2ban now allowlists `$SSH_CLIENT` source IP via `ignoreip` so the installer cannot lock itself out. A banner prints the unban command at the end of step so the operator at least knows the failure mode if they reconnect from a fresh IP. fail2ban handles brute-force at the application layer; UFW rate-limit at the firewall layer was redundant and over-aggressive for normal use.
- `TROUBLESHOOTING.md` — added "Service map" table at the top listing the four real systemd units (`agent-os-operator`, `agent-os-saga`, `agent-os-telegram-mcp`, `agent-os-dispatcher.timer`) with explicit note that there is **no** `agent-os-claude-peers.service` (peers is stdio MCP, spawned per claude session). Helps debuggers stop looking for a unit that doesn't exist.
- `QUICKSTART.md` + `README.md` — install timing claim corrected from "~3 min" / "~10-12 min" to honest "~7-8 min on s-2vcpu-4gb" (apt 2 min + plugin builds 3 min + whisper 2 min + claude warm-up 1 min). Faster on s-4vcpu-8gb.

### Added
- `install.sh` Step 4 / 4c — placeholder-token guards: wizard now rejects BotFather and OAuth tokens that contain `FAKE` / `fake` / `test_token` / `placeholder` / `PLACEHOLDER` / `EXAMPLE` (and the canonical fake `123456789:AAH` BotFather prefix). Plus the BotFather token now is live-validated against `https://api.telegram.org/bot<TOKEN>/getMe` so revoked or mistyped real tokens are caught at the prompt instead of silently writing into `/etc/agent-os/agent-os.env` and breaking the bot at runtime with 401. OAuth side accepts both `sk-ant-oat01-…` (long-lived) and `sk-ant-api03-…` (Console API key) formats. Closes the headache where a developer's placeholder token persisted across re-runs and the operator returned API 401 on every channel-routed Telegram message.
- `.claude-settings.template.json` — `permissions.defaultMode: "bypassPermissions"`. Belt-and-suspenders alongside `--dangerously-skip-permissions` for cloud deployments where there is no human at the terminal to approve permission requests. Local dev installs may want to override this to `default` for a per-tool permission UI.
- `.claude-config.template.json` — `claude-peers` stdio mcpServers entry pointing at `${INSTALL_ROOT}/claude/plugins/claude-peers/server.ts` via bun. Project `.mcp.json` already declares `telegram` + `saga-mcp` as SSE; claude-peers is the stdio MCP plugin spawned per session.
- `systemd/agent-os-telegram-mcp.service` — new dedicated systemd unit for telegram-mcp (HTTP/SSE bridge to the Telegram bot, port 3848). Previously the plugin manifest only declared mcpServers entries that claude spawned per-session — but two issues forced the standalone-service architecture: (1) telegram-mcp pushes channel notifications by iterating `activeSessions`, a map populated only by SSE clients (not stdio-spawned sessions), so operator stdio spawns never received incoming messages despite registering as a channel; (2) Telegram's getUpdates long-poll has a single-poller lock — multiple instances always conflict with 409. Operator connects via SSE per project `.mcp.json` mcpServers entry. install.sh Step 10 now renders this unit, Step 17 enables+starts it before operator. Operator unit gains `After=agent-os-telegram-mcp.service`. Logs at `/var/log/agent-os/telegram-mcp.log` show `[telegram-mcp] Seeded N admin(s) as allowed: <ids>` confirming env-driven admin auto-approve works.
- `systemd/agent-os-operator.service` — ExecStart now uses `--dangerously-load-development-channels server:telegram --dangerously-load-development-channels server:claude-peers` (`server:` prefix matches MCP server names, NOT `plugin:` marketplace IDs). This bypasses the channel allowlist gate which is enterprise-only via the `tengu_harbor_ledger` GrowthBook flag (saga task #802). Also adds `Environment=PATH={AGENT_HOME}/.bun/bin:...` because claude-peers' MCP server's broker child fails to spawn with `Fatal: Executable not found in $PATH: "bun"` under systemd's default minimal PATH.
- `agents/operator/.claude/hooks/log-tool-use.sh` — async PostToolUse hook that appends a TSV audit line for every tool call to `$AGENTOS_HOOKS_LOG_DIR/operator-tool-calls.log`. Because operator runs with `--dangerously-skip-permissions` there are no interactive permission checkpoints; this hook is the primary visibility mechanism for what the agent did during a session.
- `agents/operator/.claude/hooks/permission-allow.sh` — PermissionRequest hook that auto-allows every tool call. Belt-and-suspenders alongside `--dangerously-skip-permissions` for the case where the agent is started without the CLI flag. Exits early (no decision emitted) when the mode is already `bypassPermissions`; otherwise logs the unexpected request and returns `behavior: allow`.
- `agents/operator/.claude/settings.json` — wired the two new hooks: `PostToolUse` (async, matcher `""`) for `log-tool-use.sh` and `PermissionRequest` (matcher `""`) for `permission-allow.sh`.
- `ARCHITECTURE.md` — new section "12. Operator autonomy — headless permission strategy" documenting all five defence layers, trade-off table, and rationale for choosing `--dangerously-skip-permissions` as primary with hook-based logging for auditability.

### Fixed
- `install.sh` — `ssh_config_add_alias` now rewrites stale Host entry on reprovision (was: silently kept old IP, causing `wait_until_ssh_ready` to hang on dead droplet).
- `install.sh` — `STATE_FILE` is now Mac-aware. On Darwin (wizard runs as user, no sudo) it writes to `$HOME/.agent-os-deploy/install.state.json` next to `DEPLOY_STATE`; on Linux (root install) it stays at `/etc/agent-os/install.state.json`. Previously the Mac wizard spammed `mkdir: /etc/agent-os: Permission denied` on every `ask` prompt and never persisted answers across re-runs (resume was effectively broken).
- `install.sh` Step 5/18 — switched the apt URL to the canonical path documented at code.claude.com/docs/en/setup: `https://downloads.claude.ai/claude-code/apt/stable stable main` with the GPG key at `https://downloads.claude.ai/keys/claude-code.asc` and keyring at `/etc/apt/keyrings/claude-code.asc`. The previous URL `…/apt stable main` (without `/stable` channel suffix) returns 404. Bootstrap installer was tried as a workaround but lands the binary in `/root/.local/bin` which is unreadable to the system `agent-os` user (mode 0700 on `/root`); apt installs to `/usr/bin/claude` system-wide and gives proper `apt-get upgrade claude-code` semantics. Step 5 now also sweeps any orphaned bootstrap install from prior runs.
- `install.sh` Step 6/18 — pre-create `${AGENT_HOME}/.config` directory. The operator systemd unit lists this path in `ReadWritePaths`; if it doesn't exist when the unit starts, mount namespacing fails with `status=226/NAMESPACE`.
- `systemd/agent-os-operator.service` — set `NoNewPrivileges=no`. tmux invokes the setuid `utempter` helper to update utmp/wtmp on session create; with `NoNewPrivileges=yes` utempter fails with `pututline: Permission denied` and tmux exits 1, which makes systemd tear the unit down (`status=1/FAILURE`) before claude ever gets a pty. Comment in the unit documents the rationale.
- `agents/heartbeat/dispatcher.sh` — switch `CLAUDE="$HOME/.local/bin/claude"` (a hard-coded bootstrap-installer path that doesn't exist on the agent-os system user, since `/root/.local/...` is mode 0700) to a PATH-lookup with bootstrap fallback. Lets the dispatcher work whether claude was installed by apt (Linux droplet, `/usr/bin/claude`), Homebrew/npm (Mac), or the bootstrap installer (`~/.local/bin/claude`).
- `install.sh` Step 2/18 — wizard no longer lets the existing `agent-os.env` override env vars passed via SSH/cmdline. Previously a re-run with new tokens (e.g. real BotFather token after the first install used a placeholder) silently kept the old values, because `set -a; . "$ENV_FILE"; set +a` clobbered the incoming `TELEGRAM_BOT_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` / etc. Now we save originals, source the file, then restore originals so file values only fill in MISSING vars. Also adds `GITHUB_TOKEN` to the protected set.
- `.claude-config.template.json` — pre-acknowledge claude-code's first-run TUI dialogs so the agent boots cleanly under systemd. Adds `hasCompletedOnboarding: true`, `bypassPermissionsModeAccepted: true`, `hasInitialThemeSetup: true`, `hasCompletedAuthSetup: true`, `theme: "dark-daltonized"`, and per-project `hasTrustDialogAccepted: true` for the operator/dispatcher/heartbeat working dirs and the AgentOS root. Without these flags claude-code 2.1.x shows a sequence of theme picker → workspace trust → bypass-permissions warning that all wait on TTY input; the operator's `tmux new-session -d` provides a pty but no input ever arrives, so claude eventually exits 1 and systemd reaps the unit. Discovered the flag names by greping the claude binary for `bypassPermissions`, `hasTrustDialog`, etc.
- `managed-settings.template.json` — schema mismatch with claude-code 2.1.119+. `enabledPlugins`, `allowedChannelPlugins`, and `strictKnownMarketplaces` are now RECORDS (objects keyed by name) not arrays — the array form fails Zod validation with `Expected record, but received array`, claude shows a "Settings Error" modal and skips the entire file (which silently drops the channel/plugin allowlist). Converted all three to `{name: {}}` form. Also dropped the `Bash(:(){ :|:& };:)` deny rule (fork bomb pattern) since claude rejects empty parentheses with `"Bash(:(){ :|:& };:)" was skipped — Empty parentheses`. The other rm/dd/mkfs deny rules cover the destructive-syscall vector this was guarding. Updated `--minimal` jq logic in install.sh Step 13 to use `del(.["telegram@agentos"])` instead of `map(select(...))` to match the new object format.

### Changed
- Docs: README now documents git-clone install (Method A) as the recommended path; curl one-liner kept as Method B.
- `install.sh` — default droplet/server/Linode label changed from `agentos` to `claude` (lines 552, 605, 644). Matches the SSH alias users naturally pick to invoke their AgentOS host (`ssh claude`, `claude` desktop entry, etc.).

### Fixed (hotfix-tty-redirect: interactive prompts under curl-pipe)
- `install.sh` invoked via `curl ... | bash` had stdin attached to the script-body pipe, so every interactive `read` got immediate EOF and the wizard skipped through every prompt with empty answers. Added a tty-redirect block right after the Darwin+sudo guard (before `detect_mode`): when stdin is not a TTY but `/dev/tty` exists, `exec </dev/tty` reroutes stdin to the controlling terminal so all `read` prompts wait for the user. Headless CI (no `/dev/tty`) is unaffected. One-line fix that covers every interactive prompt in the wizard.
- Pre-flight internet check changed from `curl -fsS https://api.anthropic.com/v1/models` to `curl -sI https://api.anthropic.com/`. The `/v1/models` endpoint requires auth and returns 401, which `-f` treated as failure — so the warning fired even on healthy networks. HEAD-only on the root host validates DNS+TCP+TLS without needing an API key.

### Fixed (hotfix-mac-bash32: macOS bash 3.2 + curl-pipe + sudo guard)
- `install.sh` line 78 used `${BASH_SOURCE[0]}` directly under `set -u`. When piped via `curl ... | bash` on macOS, BASH_SOURCE[0] is empty/unset and the script aborted with `unbound variable`. Replaced with a `${BASH_SOURCE[0]:-${0:-/dev/stdin}}` fallback chain plus an `[ -f "$_SELF" ]` guard that leaves `SCRIPT_DIR=""` when there is no on-disk script (Mac branch git-clones the template anyway).
- `${var,,}` lowercase parameter expansion is bash 4+; macOS system bash is 3.2.57. All 8 occurrences (lines 212, 402, 554, 587, 607, 724, 739, 1057) replaced with a `lower()` helper that uses `tr '[:upper:]' '[:lower:]'`. Added a matching `upper()` helper for symmetry.
- Audited the rest of the script for bash-4-isms — no `mapfile` / `readarray` / `declare -n` / `declare -A` / `[[ -v ... ]]` / `${var@Q}` / single-char `${var,}` `${var^}` found.
- Added a Darwin-sudo guard right before `detect_mode`: running `install.sh` with sudo on macOS now bails out with a clear hint to re-run without sudo. Rationale: the Mac wizard manages `~/.ssh/config`, drives `claude setup-token` in the user's browser, and only sudoes on the remote VPS via ssh — running locally as root would resolve `~/.ssh/config` to `/root/.ssh/config` and break auth.
- The `install.sh` usage header comment block now spells out the macOS (no sudo) vs Linux (sudo) one-liners explicitly. README already documents this via T12-fix.

### Added (T06-amend6: multi-admin end-to-end)
- `install.sh` Linux-side wizard (Step 2) now consumes `TG_ADMIN_USER_IDS` / `TG_ADMIN_USERNAMES` env vars from the Mac wrapper (Step 4b). Falls back to a single `TG_USER_ID` prompt when no env is provided, and back-fills `TG_ADMIN_USER_IDS` from it for consistency.
- `/etc/agent-os/agent-os.env` (Step 11) now writes `TELEGRAM_ADMIN_USER_IDS`, `TELEGRAM_ADMIN_USERNAMES`, and the legacy `TELEGRAM_USER_ID` (= first admin).
- `plugins/telegram` adds `seedAdmins()` in `db.ts`, called from `index.ts` at startup. Reads `TELEGRAM_ADMIN_USER_IDS` (preferred) or `TELEGRAM_USER_ID` (legacy fallback) and upserts each ID with `status='allowed'` so wizard-detected admins skip the manual `/approve` step.
- `plugins/telegram/.claude-plugin/plugin.json` `userConfig` schema swapped `user_id` → `admin_user_ids` + `admin_usernames` (string, comma-separated). `mcp.json` env mapping updated to match.
- `.env.example` documents the new vars and the legacy compat semantics.
- Single-admin deployments keep working unchanged; multi-admin is now wired end-to-end (Mac wizard → install.sh → env file → bot allowlist).

### Added (T06-amend5: Mac UX polish)
- Cost transparency screen at start of Mac wizard (VPS pricing per provider, Telegram/Claude/Whisper costs).
- Pre-flight checks: ssh/rsync/git/curl/jq presence, internet, claude CLI, ~/.ssh/config writability, SSH key auto-generation.
- Provider CLI auto-install via brew (`ensure_brew_cli` helper) with auth-init prompts for doctl/hcloud/linode-cli.
- BotFather hand-holding box (step-by-step instructions) + bot token format validation regex.
- Multi-admin auto-detection via `/start` polling (Telegram getUpdates), populates `TG_ADMIN_USER_IDS` + `TG_ADMIN_USERNAMES`.
- Claude Code OAuth auto-launch via `osascript` opening Terminal with `claude setup-token`.
- Remote bootstrap via `git clone` (replaces rsync) — pulls fresh template directly on remote.
- Self-test: sends Telegram message via Bot API, polls operator peer registration up to 60s, optional verify.sh probe.
- Per-deploy log file at `~/.agent-os-deploy/deploy-YYYYMMDD-HHMMSS.log`.

## 2026-05-07 — Wave 3: T01 + T07 + T11 + T12 merged

- T01: full novostudio→template skeleton (~76 files, ~10K LOC, 11 commits).
- T07: `scripts/verify.sh` (1012 LOC, ~50 checks) + `uninstall.sh` enhancements (`--keep-data`, `--purge-credentials`).
- T11: `.claude/settings.json` + 8 lifecycle hooks + helper (`_common.sh`).
- T11-tests: 17 hook smoke fixtures (all pass) + bug fix in `guard-edit.sh` tilde expansion.
- T12: README + ARCHITECTURE + UPGRADING (extensive).
- T06-amend4: install.sh Mac-branch order hardening, `--minimal` truly subsets installer (skip telegram/operator/whisper/telegram-coupled hooks), `.template-ownership.json` machine-readable manifest, removed stale launchd plists for plugins (claude-peers + telegram).

### Added
- Three-tier agent topology: `sysadmin`, `operator`, `heartbeat`.
- saga-mcp + claude-peers + telegram-mcp default bundle, all wired via `.mcp.json` per agent.
- Heartbeat dispatcher (ephemeral, every 30–45 min) with throttling, lock, git pull, JSONL pipeline.
- Worker pattern: tmux session per task, iteration loop with timeout/max-iter, `result.md` frontmatter, conflict-detect on mid-iteration `git pull --rebase`, claude-peers operator notify.
- Strategist (Opus-class, every 6h): signal-analysis, blocker-resolution, business-analysis (configurable lenses via `memory/lenses.yaml`), self-improvement, worker-results-analysis, health-watchdog.
- 12 generic skills under `agents/heartbeat/skills/` + `strategist/` subdir.
- 21 reference skills under `examples/skills/` (preserved as-is from a real AgentOS deployment).
- saga-dashboard: Node static + REST proxy on port 7902, optional cloudflared tunnel.
- Self-heal runbook (RB-001..RB-008): 6 auto-fix patterns + 2 escalations, dual platform (mac launchd + linux systemd).
- Cost telemetry: per-iteration JSON, `scripts/cost-dashboard.sh` aggregator with customizable category map.
- Bundled Claude Code plugins: `agent-sdk-dev`, `code-review`, `commit-commands`, `security-guidance`.
- VPS install: one-command `curl ... | bash`, 18-step wizard, idempotent, mac/linux dual-platform.

### Notes
- Initial template release. Upstream development happens on `main`; users fork-ahead and sync via the `template-dev` plugin.

[Unreleased]: https://github.com/{REPO_OWNER}/claude-code-template/compare/v0.1.0...HEAD
