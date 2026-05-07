# Changelog

All notable changes to this template are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file tracks **template** changes (T-marked files). Per-deployment changes belong in your fork's own changelog.

## [Unreleased]

### Fixed
- `install.sh` — `ssh_config_add_alias` now rewrites stale Host entry on reprovision (was: silently kept old IP, causing `wait_until_ssh_ready` to hang on dead droplet).
- `install.sh` — `STATE_FILE` is now Mac-aware. On Darwin (wizard runs as user, no sudo) it writes to `$HOME/.agent-os-deploy/install.state.json` next to `DEPLOY_STATE`; on Linux (root install) it stays at `/etc/agent-os/install.state.json`. Previously the Mac wizard spammed `mkdir: /etc/agent-os: Permission denied` on every `ask` prompt and never persisted answers across re-runs (resume was effectively broken).
- `install.sh` Step 5/18 — switched the apt URL to the canonical path documented at code.claude.com/docs/en/setup: `https://downloads.claude.ai/claude-code/apt/stable stable main` with the GPG key at `https://downloads.claude.ai/keys/claude-code.asc` and keyring at `/etc/apt/keyrings/claude-code.asc`. The previous URL `…/apt stable main` (without `/stable` channel suffix) returns 404. Bootstrap installer was tried as a workaround but lands the binary in `/root/.local/bin` which is unreadable to the system `agent-os` user (mode 0700 on `/root`); apt installs to `/usr/bin/claude` system-wide and gives proper `apt-get upgrade claude-code` semantics. Step 5 now also sweeps any orphaned bootstrap install from prior runs.
- `install.sh` Step 6/18 — pre-create `${AGENT_HOME}/.config` directory. The operator systemd unit lists this path in `ReadWritePaths`; if it doesn't exist when the unit starts, mount namespacing fails with `status=226/NAMESPACE`.

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
