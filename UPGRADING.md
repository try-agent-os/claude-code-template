# Upgrading

How to pull upstream `claude-code-template` changes into a running install without losing your customizations.

For day-one install instructions see [README.md](./README.md). For why the template is shaped the way it is see [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## 1. Fork-ahead workflow (recommended)

The supported pattern: **fork the template, customize on your fork, periodically merge upstream**. This preserves your edits as proper git commits with conflict markers when upstream and you both touch the same file.

### Initial setup

```bash
# 1. Fork on GitHub:
#    https://github.com/try-agent-os/claude-code-template → Fork → your-user/claude-code-template

# 2. Install pointing at your fork instead of upstream:
curl -fsSL https://raw.githubusercontent.com/your-user/claude-code-template/main/install.sh \
  | sudo bash -s -- --bootstrap-personal-repo=git@github.com:your-user/claude-code-template.git

# 3. On the VPS, add `upstream` remote so you can pull from try-agent-os later:
sudo -u agent-os git -C /opt/agent-os/claude remote add upstream \
  https://github.com/try-agent-os/claude-code-template.git
sudo -u agent-os git -C /opt/agent-os/claude fetch upstream
```

### Periodic update

```bash
cd /opt/agent-os/claude
sudo -u agent-os git fetch upstream
sudo -u agent-os git checkout main
sudo -u agent-os git merge upstream/main           # merge or rebase, your choice
# Resolve any conflicts (see §4 below)
sudo -u agent-os git push origin main              # push merged result to your fork
```

Then re-run `install.sh` to apply any changes that touch systemd units, managed-settings, or per-agent `.claude.json`:

```bash
curl -fsSL https://raw.githubusercontent.com/your-user/claude-code-template/main/install.sh | sudo bash
```

The installer is idempotent — completed steps are skipped via the state file, only changed steps re-execute. Use `--force-reinstall` to re-execute every step regardless.

---

## 2. T / P file ownership convention

To make merges predictable, the template (will) adopt a **T / P marker convention**:

- **T (template-owned)** — files you should let upstream overwrite. install.sh and the planned `template-dev` plugin's sync skill will replace these on update.
- **P (project-owned)** — files you should preserve. The sync tool will leave these untouched even if upstream changes them.

> **Status (2026-05-07):** the T/P marker scheme is now declared in [`.template-ownership.json`](./.template-ownership.json) at the repo root. It is a machine-readable JSON manifest with three globs lists — `template_managed` (T), `personal_owned` (P), and `generated`. The `template-dev@agentos` sync skill consumes it via `jq -r '.template_managed[]' .template-ownership.json` to compute the upstream-overwrite set.

If you fork the template and start authoring outside the P globs, either (a) move that file into a P-globbed directory (`memory/`, `studio/`, etc.), or (b) edit `.template-ownership.json` in your fork to extend the `personal_owned` list. The sync skill always trusts the manifest in your working tree, not the upstream version.

Changes you authored are in your fork's commits; upstream changes come in via merges. The manifest tells the sync tool which files to auto-apply vs. flag for manual review.

### Suggested current rules of thumb

| Path | Treat as |
|------|----------|
| `install.sh`, `uninstall.sh` | T (let upstream overwrite) |
| `systemd/*.service`, `systemd/*.timer`, `launchd/*.plist` | T |
| `managed-settings.template.json` | T |
| `.claude/settings.json`, `.claude/hooks/*.sh`, `.claude/hooks/_common.sh` | T (until you have a real reason to fork) |
| `.claude-plugin/marketplace.json`, `plugins/VENDORING.md` | T |
| `plugins/<vendored-plugin>/*` | T (refreshed via vendoring scripts) |
| `CLAUDE.md` (root), `agents/operator/CLAUDE.md`, `agents/dispatcher/CLAUDE.md` | P (your agent personality) |
| `agents/<custom-role>/*` | P (anything you add) |
| `memory/`, `studio/`, `research/`, `resources/`, `clients/` | P (your data) |
| `.env` (local secrets, never committed) | P |
| `/etc/agent-os/agent-os.env` (on VPS, never in repo) | P |

If you must edit a T file (say, you patched `install.sh` for a corporate proxy), keep the change atomic and document it in your fork's commit message — that makes future merges easier.

---

## 3. Sync via `template-dev` plugin (planned)

The marketplace lists `template-dev@agentos` as a placeholder. When implemented, it will provide a slash command (e.g. `/template-dev:sync`) that:

1. Fetches the latest commit from `upstream/main` (or whatever upstream remote is configured).
2. Diffs each T-marked file between your fork's `main` and upstream's `main`.
3. Applies T-only changes via `git checkout upstream/main -- <path>`.
4. Reports any P files that upstream also modified — these you must merge by hand.
5. Stages and commits the result with a structured message.
6. Prints a one-shot follow-up command to re-run `install.sh` (since some changes — systemd unit edits, managed-settings — only take effect after the installer re-runs).

Until that plugin lands, follow §1 manually.

---

## 4. Conflict resolution

When upstream and you both edit the same file, git produces conflict markers in the affected hunks. Standard resolution:

```bash
# After git merge upstream/main shows conflicts:
sudo -u agent-os git -C /opt/agent-os/claude status
# Look for "Unmerged paths" — those are your conflicts.

# For each file:
sudo -u agent-os git -C /opt/agent-os/claude diff <file>          # see the conflict in detail
sudo -u agent-os vim /opt/agent-os/claude/<file>                  # resolve
sudo -u agent-os git -C /opt/agent-os/claude add <file>

# When all resolved:
sudo -u agent-os git -C /opt/agent-os/claude commit               # finalize merge
```

### Three-way merge tips

For non-trivial conflicts, use a graphical merger:

```bash
sudo -u agent-os git -C /opt/agent-os/claude mergetool
```

Look for "ours" (your fork's version), "theirs" (upstream's version), and the common ancestor. For settings JSON, prefer "ours" when in doubt — your hook configurations and permissions tend to be more recent than upstream's.

### Recovery commands

If a merge goes sideways and you want to abort:

```bash
sudo -u agent-os git -C /opt/agent-os/claude merge --abort
```

If you committed a bad merge and want to reset to before you started (assumes you didn't push yet):

```bash
sudo -u agent-os git -C /opt/agent-os/claude reflog                # find the pre-merge SHA
sudo -u agent-os git -C /opt/agent-os/claude reset --hard <pre-merge-SHA>
```

If you pushed a bad merge to your fork's `main` and need to undo on the remote:

```bash
sudo -u agent-os git -C /opt/agent-os/claude reset --hard <pre-merge-SHA>
sudo -u agent-os git -C /opt/agent-os/claude push --force-with-lease origin main
```

`--force-with-lease` is safer than `--force` — it refuses to push if someone else committed to your fork's `main` in the meantime.

### Where to escalate

Upstream conflicts that look architectural (a setting moved scope, a plugin renamed, a hook event was deprecated) are worth raising on the upstream issue tracker:

[github.com/try-agent-os/claude-code-template/issues](https://github.com/try-agent-os/claude-code-template/issues)

Include the upstream SHA you're merging and your last-known-good SHA.

---

## 5. Version pinning

`managed-settings.template.json` includes:

```json
"minimumVersion": "2.1.132"
```

This prevents Claude Code from running if a downgrade somehow lands. Any session against an older binary fails the policy check. The version reflects the lowest Claude Code release that supports the features the template depends on (`channelsEnabled`, `allowedChannelPlugins`, `strictKnownMarketplaces`, etc.).

### Bumping `minimumVersion`

When upstream raises `minimumVersion` (e.g. because a new managed-settings field was introduced):

```bash
# On the VPS, after pulling upstream:
sudo cp /opt/agent-os/claude/managed-settings.template.json /etc/claude-code/managed-settings.json
# Or simpler: re-run install.sh — step 13 reinstalls managed-settings.json from the template.
sudo bash /opt/agent-os/claude/install.sh
```

### Forcing an older Claude Code

If a new release has a regression and you want to roll back:

```bash
# 1. Find available versions
apt list -a claude-code

# 2. Pin to a specific version
sudo apt install claude-code=2.1.131-1
sudo apt-mark hold claude-code

# 3. Bump minimumVersion DOWN in managed-settings.json to match
sudo vim /etc/claude-code/managed-settings.json   # set minimumVersion to 2.1.131

# 4. Restart units
sudo systemctl restart agent-os-operator agent-os-saga
```

To re-allow upgrades: `sudo apt-mark unhold claude-code`.

---

## 6. Plugin updates

Plugin lifecycle is **separate from template lifecycle**. Plugins are vendored under `plugins/` at pinned upstream commits — see [`plugins/VENDORING.md`](./plugins/VENDORING.md). They get refreshed by re-vendoring upstream snapshots into the template, not by users running `claude /plugin update`.

### When the template ships new plugin versions

The vendored copies under `plugins/` change in a template release. After `git pull` and `install.sh`:

- The `enabledPlugins` block in `/etc/claude-code/managed-settings.json` will continue to point at the same plugin names (`claude-peers@agentos`, etc.) — names don't change.
- The plugin's `version` in `marketplace.json` will bump (e.g. `vendored-fc26491` → `vendored-abcdef0`).
- Claude Code reloads plugin state next session start. Existing operator session keeps using the old plugin until restarted.

To force a plugin reload mid-session: type `/reload-plugins` in Claude Code, or restart the agent (`sudo systemctl restart agent-os-operator`).

### When you customize a vendored plugin

If you edit `plugins/claude-peers/server.ts` (or any other vendored file) directly in your fork, your changes will conflict on the next refresh. Two options:

1. **Patch upstream.** Send the change to the upstream plugin repo (e.g. `novostudiotech/claude-peers-mcp`). Once merged + revendored, you'll get it back through normal template updates.
2. **Maintain a patch.** Keep the change in your fork and resolve the conflict each refresh. Use `git format-patch` to extract a reusable patch file.

### Cache and runtime state

Plugins keep some state outside the repo:

- `node_modules/` for telegram (npm) and claude-peers (bun) — installed by `install.sh` step 9, not committed
- `plugins/telegram/messages.db*` — SQLite + FTS5 of Telegram history. Persists across plugin updates.
- `plugins/telegram/node_modules/nodejs-whisper/cpp/whisper.cpp/models/ggml-*.bin` — Whisper model file (75 MB to 1.5 GB). Persists.
- `plugins/claude-peers/.../` — broker DB lives at `/var/lib/agent-os/claude-peers.db` per the user-config default in `plugin.json`.

After a plugin update, only the source code is replaced. Runtime state survives. If a schema migration is needed, it's the plugin's responsibility to run it on first boot.

---

## 7. Breaking changes

> **Reserved for future releases.** Migration notes for breaking changes will land here, dated, with the from→to range.
>
> **2026-05-07 — initial release:** N/A. There's nothing to migrate from.
>
> **2026-05-07 — T06-amend6: multi-admin Telegram allowlist (non-breaking).** New env vars `TELEGRAM_ADMIN_USER_IDS` (comma-separated) and `TELEGRAM_ADMIN_USERNAMES` (display only) replace the single-admin `TELEGRAM_USER_ID` as the canonical source. Existing deployments keep working — `TELEGRAM_USER_ID` is still honoured as a fallback when `TELEGRAM_ADMIN_USER_IDS` is empty, and install.sh now writes both. New deploys via the Mac wizard auto-populate `TELEGRAM_ADMIN_USER_IDS` from `/start` polling (Step 4b) and pass it through to the remote install. To upgrade an existing install: re-run `install.sh` (idempotent) — it will re-write `/etc/agent-os/agent-os.env` with the new vars, defaulting `TELEGRAM_ADMIN_USER_IDS` to the existing `TELEGRAM_USER_ID`. To add more admins, edit the env file directly and restart `agent-os-operator.service` (the telegram MCP plugin re-seeds the admin list at every startup).
>
> A change is "breaking" if any of the following is true:
> - A managed-settings field changed name or shape and must be re-rendered.
> - A systemd unit was renamed (so the previous one must be stopped + disabled before re-install).
> - A plugin name in the marketplace changed (`enabledPlugins` references break).
> - A hook script was renamed AND `.claude/settings.json` references must be updated together.
> - The `.env.example` schema changed in a way that requires manual edits to `/etc/agent-os/agent-os.env`.

If you're hitting one of those classes of issue and don't see it here, the upstream changelog (or the merge commit) is the next place to check.

---

## 8. Rollback

When an update breaks the install and you need to recover quickly:

### Roll back template repo

```bash
# Find the last known-good commit
sudo -u agent-os git -C /opt/agent-os/claude log --oneline -20

# Reset to it
sudo -u agent-os git -C /opt/agent-os/claude reset --hard <good-SHA>

# Re-render systemd units etc.
sudo bash /opt/agent-os/claude/install.sh
sudo systemctl restart 'agent-os-*'
```

### Roll back Claude Code itself

See §5 above ("Forcing an older Claude Code").

### Roll back a plugin to a previous vendored snapshot

```bash
# Inside /opt/agent-os/claude:
sudo -u agent-os git -C /opt/agent-os/claude log --oneline plugins/claude-peers/    # find a previous vendoring commit
sudo -u agent-os git -C /opt/agent-os/claude checkout <previous-SHA> -- plugins/claude-peers/
# Also roll back the marketplace.json entry's version + source URL to match
sudo -u agent-os vim /opt/agent-os/claude/.claude-plugin/marketplace.json
sudo -u agent-os bash -c "cd /opt/agent-os/claude/plugins/claude-peers && bun install"
sudo systemctl restart agent-os-operator
```

### Restore from preserved data after a botched purge

If you ran `uninstall.sh` (default — keeps data) before discovering an issue:

```bash
# The repo is gone but state survives:
ls -la /var/lib/agent-os/                   # saga.db, claude-peers.db, claude-config/
ls -la /var/log/agent-os/                   # logs
cat /etc/agent-os/agent-os.env              # secrets

# Re-install — wizard reads existing state file and skips already-completed steps:
curl -fsSL https://raw.githubusercontent.com/your-user/claude-code-template/main/install.sh \
  | sudo bash
```

If you ran `--purge` and lost everything: nothing to restore unless you have backups. `/var/lib/agent-os/saga.db` is the most valuable file — it has every task you ever filed. Add it to your VPS backup policy.

### Wizard answer reset

If you only want to re-prompt the wizard (e.g. you changed your Telegram bot) without touching services or data:

```bash
sudo /opt/agent-os/claude/uninstall.sh --reset-state
sudo bash /opt/agent-os/claude/install.sh
```

---

## Quick reference

```bash
# Update from upstream (your-fork pattern)
sudo -u agent-os git -C /opt/agent-os/claude fetch upstream && \
  sudo -u agent-os git -C /opt/agent-os/claude merge upstream/main && \
  sudo -u agent-os git -C /opt/agent-os/claude push origin main && \
  sudo bash /opt/agent-os/claude/install.sh

# Force re-execute all install steps
sudo bash /opt/agent-os/claude/install.sh --force-reinstall

# Re-prompt the wizard
sudo /opt/agent-os/claude/uninstall.sh --reset-state && \
  sudo bash /opt/agent-os/claude/install.sh

# Pin to a specific Claude Code version
sudo apt install claude-code=<version>-1 && sudo apt-mark hold claude-code

# Restart all services
sudo systemctl restart 'agent-os-*'

# Reload plugins inside a running session
# (in the operator's tmux session, type: /reload-plugins)
```
