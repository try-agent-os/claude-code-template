---
description: Sync upstream template updates into a personal AgentOS fork. Use when user says "sync template", "update template", "pull template changes", or wants to merge new upstream commits without overwriting personal files (memory/, .env, .mcp.json).
allowed-tools: Bash(git:*) Bash(diff:*) Bash(jq:*) Read Edit Write
---

# Template Sync

You are syncing upstream template updates into the user's personal AgentOS fork.

## Pre-flight context

Current branch: !`git rev-parse --abbrev-ref HEAD`

Remotes:
!`git remote -v`

Last fetch from template:
!`git for-each-ref --sort=-committerdate refs/remotes/template/ --count=1 --format="%(refname:short)  %(committerdate:relative)"  2>/dev/null || echo "(no template remote yet)"`

Diverging files since last sync:
!`git diff --name-status template/main..main 2>/dev/null | head -50 || echo "(can't compute — fetch template first)"`

State of personal-owned files (must NOT be overwritten):
!`for d in memory/ .env logs/ .mcp.json; do test -e "$d" && echo "  $d (exists)"; done`

## File ownership rules

**Template-managed (T)** — synced from upstream:
- `agents/{sysadmin,operator,heartbeat}/CLAUDE.md`, SOUL.md, scripts (dispatcher.sh, worker-launcher.sh, etc.), `.mcp.json`
- `scripts/`, `systemd/`, `launchd/`, `plugins/`, `skills/` (shared)
- `install.sh`, `uninstall.sh`, `verify.sh`
- `README.md`, `ARCHITECTURE.md`, `UPGRADING.md`, `CHANGELOG.md`, `CLAUDE.md` (root)
- `.claude/`, `.claude-plugin/`

**Personal-owned (P)** — never overwritten by sync:
- `memory/` (all files including memory/contacts/, memory/postmortems/*.md non-TEMPLATE)
- `.env`, `.mcp.json` (rendered, not template), `logs/`
- Anything user added in `studio/`, `clients/`, etc.

## Workflow

### Step 1: Fetch upstream

```bash
git fetch template main
```

### Step 2: Compute T-files diff
List files changed in template/main since last merge that are template-managed.

### Step 3: Show diff to user
Per file, show `git diff template/main..HEAD -- <file>` summarized.

### Step 4: Confirm + apply
For each T-file with upstream changes:
- If user has local changes: surface conflict, ask user to resolve
- If clean: apply upstream version

For P-files: NEVER touch. Show user a notice if upstream changes a P-file (rare, but indicates template author put personal content in T-zone — flag for review).

### Step 5: Commit + summarize
```bash
git add <changed T-files>
git commit -m "sync template: <summary> (from template/main@<sha>)"
```

Tell user: how many T-files updated, list of them, link to template's CHANGELOG.md for details, suggest they run `verify.sh` post-sync.

## Errors

- No template remote → `git remote add template <UPSTREAM_URL>` first
- Fetch fails → check network / auth
- Detached HEAD → `git checkout main`
- Dirty working tree → ask user to commit or stash first
