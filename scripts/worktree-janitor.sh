#!/bin/bash
# worktree-janitor.sh — reap stale/merged per-workspace git worktrees.
#
# Why: submodule dev pipelines (start-feature / setup-worktree.sh) create a git
# worktree per feature under workspaces/<ws>/platform/.worktrees/, each with its
# own node_modules (~180-250k inodes). They have a *setup* path but no reliable
# *teardown* — abandoned worktrees accumulate forever. In one incident this
# filled the root FS to 100% inodes and deadlocked the whole install. The
# per-worker worktree GC (spawn-worker.sh) only covers the install's own
# worker/<slug> worktrees, NOT these per-workspace ones. This janitor closes
# that gap.
#
# Reap policy (a worktree is removed if EITHER holds):
#   * merged  — its branch tip is an ancestor of origin/main (work landed)
#   * stale   — NO activity within STALE_HOURS (default 24h): neither the top
#               dir mtime, nor git metadata (HEAD/index/FETCH_HEAD in the
#               worktree's private gitdir), nor any working-tree file (find
#               with node_modules/.git pruned, -quit on first fresh hit). Top
#               dir mtime alone is NOT usable — writes to nested files don't
#               bump it, so an active worktree would false-positive as stale.
# Branch refs are kept (cheap; preserves recoverability). Only the working
# directory + its node_modules are removed, then `git worktree prune`.
# NOTE: dirty worktrees are STILL reaped — in the incident every reaped worktree
# had only a machine-written apps/api/.env.test as its uncommitted change, so a
# "skip if dirty" rule would let them accumulate indefinitely. Age is the guard.
#
# DRY_RUN=1 -> report only. Exit 0 always. Alerts only on a large reap (signal
# that the teardown gap fired) via an optional notify hook (AGENT_OS_NOTIFY_HOOK;
# unset => log-only).

set -uo pipefail

REPO_ROOT="${AGENT_OS_HUB:-/opt/agent-os/claude}"
# Optional alert hook. Set AGENT_OS_NOTIFY_HOOK to an executable accepting
# `--source <name> --severity <info|warn|error> --msg <text>`; unset => log-only.
NOTIFY="${AGENT_OS_NOTIFY_HOOK:-}"
LOG="/var/log/agent-os/worktree-janitor.log"
STALE_HOURS="${STALE_HOURS:-24}"
DRY_RUN="${DRY_RUN:-0}"
ALERT_THRESHOLD="${ALERT_THRESHOLD:-10}"   # notify if >= this many reaped in one run

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
ts() { date -u +%FT%TZ; }
now_epoch=$(date +%s)
stale_secs=$(( STALE_HOURS * 3600 ))

total_reaped=0
report=""

# Freshness probe for the stale-guard. Dir mtime alone is NOT enough: a worker
# writing into deeply nested files (src/..., logs) never bumps the mtime of the
# worktree's top dir, so a >24h-old but ACTIVE worktree would look stale.
# A worktree counts as fresh (return 0) if ANY of these is younger than cutoff:
#   1. the top dir itself (files created/removed directly in it),
#   2. its private gitdir metadata (HEAD/index/FETCH_HEAD — git bumps these on
#      checkout/add/commit/fetch; cheap, 3 stats),
#   3. any working-tree file, with node_modules and .git pruned — `-print -quit`
#      stops at the first fresh hit, and pruning node_modules keeps the scan to
#      the source tree (thousands of files, not hundreds of thousands).
is_fresh() {
  local path="$1" cutoff=$(( now_epoch - stale_secs )) m f gitdir
  m=$(stat -c %Y "$path" 2>/dev/null || echo 0)
  [ "$m" -gt "$cutoff" ] && return 0
  gitdir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null || true)
  if [ -n "$gitdir" ]; then
    for f in "$gitdir/HEAD" "$gitdir/index" "$gitdir/FETCH_HEAD"; do
      m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
      [ "$m" -gt "$cutoff" ] && return 0
    done
  fi
  if [ -n "$(find "$path" \( -name node_modules -o -name .git \) -prune -o -type f -newermt "@$cutoff" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  return 1
}

# Remove now-empty intermediate dirs left by nested branch names
# (.worktrees/feat/dev-xxx leaves an empty .worktrees/feat behind). Walk up
# strictly BELOW .worktrees; stop at the first non-empty level.
cleanup_parents() {
  local platform="$1" parent="$2"
  while [ "$parent" != "$platform/.worktrees" ]; do
    case "$parent" in "$platform"/.worktrees/*) : ;; *) return 0 ;; esac
    rmdir "$parent" 2>/dev/null || return 0
    parent="$(dirname "$parent")"
  done
}

# Decide + reap a single worktree. Args: platform_repo ws path branch_ref locked
# branch_ref is the FULL ref (refs/heads/...) — unambiguous for merge-base even
# when a tag or file shares the short name.
consider() {
  local platform="$1" ws="$2" path="$3" branch="$4" locked="$5"
  [ -n "$path" ] || return 0
  # Never touch the main checkout or anything outside this platform's
  # .worktrees. NOTE: for a SUBMODULE the porcelain main-worktree entry is the
  # gitdir under the superproject's .git/modules/, not $platform itself — the
  # case-guard below is what actually excludes it; the equality check is
  # belt-and-suspenders for a plain (non-submodule) checkout.
  [ "$path" = "$platform" ] && return 0
  case "$path" in "$platform"/.worktrees/*) : ;; *) return 0 ;; esac
  [ -d "$path" ] || return 0
  local disp="${branch#refs/heads/}"   # short name for logs
  # `git worktree lock` is an explicit keep-me signal (and `remove --force`
  # refuses locked anyway, which would push us into blind rm -rf). Honor it.
  if [ "$locked" = "1" ]; then
    echo "[$(ts)] skip locked [$ws] $path branch=${disp:-?}" >> "$LOG"
    return 0
  fi

  local reason=""
  # merged: branch tip is an ancestor of origin/main
  if [ -n "$branch" ] && git -C "$platform" merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
    reason="merged"
  elif ! is_fresh "$path"; then
    reason="stale(>${STALE_HOURS}h)"
  fi

  [ -n "$reason" ] || return 0

  if [ "$DRY_RUN" = "1" ]; then
    echo "[$(ts)] DRY would reap [$ws] $path branch=${disp:-?} ($reason)" >> "$LOG"
    report+=$'\n'"  DRY [$ws] ${disp:-?} ($reason)"
  else
    git -C "$platform" worktree remove --force "$path" 2>/dev/null || rm -rf "$path"
    cleanup_parents "$platform" "$(dirname "$path")"
    echo "[$(ts)] reaped [$ws] $path branch=${disp:-?} ($reason)" >> "$LOG"
    report+=$'\n'"  [$ws] ${disp:-?} ($reason)"
  fi
  total_reaped=$(( total_reaped + 1 ))
}

for platform in "$REPO_ROOT"/workspaces/*/platform; do
  [ -d "$platform/.worktrees" ] || continue
  git -C "$platform" rev-parse --git-dir >/dev/null 2>&1 || continue
  ws="$(basename "$(dirname "$platform")")"

  # Refresh origin/main so merge-detection is accurate (best-effort, quiet).
  git -C "$platform" fetch --quiet origin main 2>/dev/null || true

  # Parse porcelain worktree list: records separated by blank lines; each has a
  # "worktree <path>" line, optionally "branch refs/heads/<name>" (absent for
  # detached HEAD — such worktrees get no merged-check, only the stale-guard),
  # optionally "locked [reason]" / "prunable ...". Keep the FULL branch ref —
  # stripping refs/heads/ with ${line#branch refs/heads/} silently returns the
  # whole line (incl. "branch " prefix) for any non-refs/heads ref. The trailing
  # `echo` guarantees the last record is flushed even without a final blank line
  # (an extra blank line just calls consider with an empty path, which no-ops).
  wt_path=""; wt_branch=""; wt_locked=0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)       wt_path="${line#worktree }" ;;
      "branch "*)         wt_branch="${line#branch }" ;;
      locked|"locked "*)  wt_locked=1 ;;
      "")                 consider "$platform" "$ws" "$wt_path" "$wt_branch" "$wt_locked"
                          wt_path=""; wt_branch=""; wt_locked=0 ;;
    esac
  done < <(git -C "$platform" worktree list --porcelain 2>/dev/null; echo)

  [ "$DRY_RUN" = "1" ] || git -C "$platform" worktree prune 2>/dev/null || true
done

if [ "$DRY_RUN" != "1" ] && [ "$total_reaped" -ge "$ALERT_THRESHOLD" ]; then
  # Clip the per-worktree list for Telegram (a 68-entry reap would blow the
  # message size); the full list is always in $LOG.
  report_clip="$(printf '%s' "$report" | head -n 21)"
  [ "$report_clip" != "$report" ] && report_clip+=$'\n'"  ... (full list in $LOG)"
  [ -n "$NOTIFY" ] && [ -x "$NOTIFY" ] && "$NOTIFY" --source worktree-janitor --severity warn \
    --msg "Reaped $total_reaped stale/merged worktrees this run (>= $ALERT_THRESHOLD). Teardown gap is firing — check that the creating pipeline (start-feature/setup-worktree) has a teardown hook.$report_clip" 2>>"$LOG" || true
fi

echo "[$(ts)] done: reaped=$total_reaped (dry_run=$DRY_RUN, stale_hours=$STALE_HOURS)$report" >> "$LOG"
exit 0
