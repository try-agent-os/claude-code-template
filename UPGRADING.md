# Upgrading

This template is designed for a **fork-ahead** workflow: you clone, install, take ownership of the repo, and pull upstream improvements via the `template-dev` plugin.

## File ownership

Every tracked file is one of:

- **T (template-owned)** — overwritten on sync. Algorithm scripts, role docs, hooks, settings template, install.sh.
- **P (personal-owned)** — never overwritten. `memory/*.md` (your context, decisions, learnings), `.claude/settings.local.json`, your additions in `studio/`, `research/`, etc.
- **G (generated)** — runtime artifacts. `.mcp.json` (rendered from `.mcp.json.template`), `logs/`, `memory/worker-*.log`. Gitignored.

Full classification: see [`ARCHITECTURE.md`](ARCHITECTURE.md) §"Folder structure" (T/P/G column).

## Sync workflow

```bash
# Pull upstream T-marked changes (does NOT touch P/G)
/sync                    # in claude

# Or via shell:
bash sync-template
```

The skill diffs `template/main` against your `HEAD`, surfaces P-marked conflicts (so you can review before overwrite), applies T-only updates, commits with message `template-sync: <commit-range>`.

## Stage A → Stage B (template → personal repo)

After install, the repo's `origin` points at the upstream template. To take ownership:

```bash
git remote rename origin template
git remote add origin <your-personal-repo-url>
git push -u origin main
```

Now `git pull` pulls from your personal repo; `template-dev` keeps the upstream link as `template/main`.

The installer flag `--bootstrap-personal-repo <url>` automates this on first install.

## Breaking changes

When upstream introduces a breaking change, the relevant T-marked file's diff will surface during `/sync`. The skill flags:

- Renamed/moved T files
- Deleted T files (e.g. the install path changed and an old script is gone)
- T files that conflict with your local edits (you edited a T file directly — common but discouraged)

Resolution patterns are documented in `{INSTALL_ROOT}/agents/sysadmin/docs/template-sync-patterns.md` (added by `template-dev`).

## When things break

If `/sync` fails partway:

```bash
# Revert
git reset --hard HEAD~1

# Re-run with verbose
/sync --verbose

# Or skip the bad file
/sync --skip <path>
```

For sync-related issues, the `template-dev` plugin keeps a rolling log at `memory/template-sync.log`.

---

*Detailed sync UX, conflict resolution, and migration patterns are filled in by the `template-dev` plugin (T03) and finalized in T12 docs pass.*
