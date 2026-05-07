---
description: Bootstrap a personal AgentOS instance from this template. Renames `main` to `main-template`, creates fresh `main` for personal work, sets `origin` to user's repo, sets `template` remote pointing at upstream. Use when user says "bootstrap personal repo", "fork template", "set up my AgentOS project from template".
allowed-tools: Bash(git:*) Bash(gh:*) Read Write
---

# Template Bootstrap (Stage B)

Pre-flight:

Current remotes:
!`git remote -v`

Current branch:
!`git rev-parse --abbrev-ref HEAD`

## Steps

1. Confirm with user:
   - personal git URL (`git@github.com:USER/REPO.git`)
   - whether to push immediately or just rename branches

2. Rename `main` → `main-template`:
   ```bash
   git branch -m main main-template
   ```

3. Create fresh `main` from `main-template`:
   ```bash
   git checkout -b main main-template
   ```

4. Rewire remotes:
   ```bash
   git remote rename origin template
   git remote add origin <USER_GIT_URL>
   ```

5. Push both branches to user's origin:
   ```bash
   git push -u origin main main-template
   ```

6. Tell user:
   - `main` is yours, evolve freely
   - `main-template` mirrors upstream — use `/template:sync` periodically to fetch + merge into main-template, then merge into main
   - DO NOT push main-template manually with personal commits — keep it clean for sync

## Optional: gh repo create
If user has gh CLI and no repo yet, offer to create:
```bash
gh repo create <name> --private
```
