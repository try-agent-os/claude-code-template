# template-dev

AgentOS-native plugin that drives the **fork-ahead workflow** for the AgentOS template: bootstrap a personal repo from the upstream template, sync upstream updates without overwriting personal files, and inspect what has diverged.

## Why

The AgentOS template is meant to be cloned into your own repo, then evolved. But the template itself keeps shipping updates — new agents, hooks, skills, fixes. You want those changes pulled in, but you don't want your `memory/`, `.env`, `logs/`, or rendered `.mcp.json` clobbered.

`template-dev` codifies the file ownership rules — **template-managed (T)** vs **personal-owned (P)** — and applies them to git operations.

## Components

### Slash commands

| Command | What |
|---------|------|
| `/template:bootstrap <git-remote-url>` | Stage B setup. Renames `main` → `main-template`, creates a fresh `main`, rewires `origin` to your repo and `template` to upstream, optionally pushes. Run this once after cloning the template into a new working dir. |
| `/template:sync` | Fetches upstream, lists T-files changed, surfaces P-files that upstream tries to touch (red flag), applies clean updates, commits with `sync template: ...` message. |
| `/template:diff` | Read-only. Shows what's diverged from `template/main`, classified into T-edited (will conflict on next sync), P (expected), and locally-added. Runs in a forked Explore subagent. |

### Skills (powering the commands)

- `skills/sync/SKILL.md` — full sync workflow with pre-rendered context (current branch, remotes, last fetch, diverging files, P-state) injected via `` !`<cmd>` ``.
- `skills/bootstrap/SKILL.md` — Stage B bootstrap workflow with optional `gh repo create`.
- `skills/diff/SKILL.md` — read-only diff classifier.

## File ownership

**Template-managed (T)** — synced from upstream:

- `agents/{sysadmin,operator,heartbeat}/CLAUDE.md`, `SOUL.md`, scripts, agent-level `.mcp.json`
- `scripts/`, `systemd/`, `launchd/`, `plugins/`, `skills/` (shared)
- `install.sh`, `uninstall.sh`, `verify.sh`
- `README.md`, `ARCHITECTURE.md`, `UPGRADING.md`, `CHANGELOG.md`, root `CLAUDE.md`
- `.claude/`, `.claude-plugin/`

**Personal-owned (P)** — never overwritten by sync:

- `memory/` (all files including `memory/contacts/`, non-`TEMPLATE` postmortems)
- `.env`, root `.mcp.json` (rendered, not template), `logs/`
- Anything you add under `studio/`, `clients/`, etc.

## Typical flow

1. Clone template to your machine (or run `install.sh`).
2. `/template:bootstrap git@github.com:you/your-agentos.git` — sets up the two-branch model.
3. Work normally — commits go to `main`, your origin.
4. Periodically: `/template:sync` — fetches `template/main`, applies T-only updates, commits.
5. If sync surfaces a conflict (you edited a T-file): resolve manually, re-run.
6. `/template:diff` any time you want to see what you've customized vs upstream.

## Branch model

- `main` — your personal branch, push to your `origin`.
- `main-template` — mirrors upstream `template/main`, kept clean for sync.
- `template` remote → upstream AgentOS template.
- `origin` remote → your personal repo.

Sync flow: `git fetch template main` → fast-forward `main-template` → cherry-pick / merge T-file changes into `main`.

## Errors handled

- No `template` remote → ask to add it.
- Dirty working tree → ask to commit/stash first.
- Detached HEAD → checkout `main`.
- Upstream touches a P-file → flag, do not overwrite, ask user.
