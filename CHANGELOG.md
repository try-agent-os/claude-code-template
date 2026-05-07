# Changelog

All notable changes to this template are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file tracks **template** changes (T-marked files). Per-deployment changes belong in your fork's own changelog.

## [Unreleased]

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
