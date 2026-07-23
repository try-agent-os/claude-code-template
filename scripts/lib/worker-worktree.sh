#!/bin/bash
# worker-worktree.sh — the "never bulldoze undelivered work" guard for worker worktrees.
#
# The launcher reuses ONE path per slug (<repo-parent>/.worktrees/<slug>) across
# ticks and, before this guard, reaped it unconditionally as soon as the previous
# tick's tmux session was gone:
#
#   git worktree remove --force "$wt" || rm -rf "$wt"     # spawn-worker.sh, orphan GC
#   rm -rf "$WORKER_WORKTREE"                             # spawn-worker.sh, prune-on-respawn
#
# Both run BEFORE anything checks whether the previous tick's commits reached
# origin/main. A tick that did real work, committed, and then died without a
# successful /done (hard kill by the timeout janitor, crash, or a /done whose
# ff-push lost the race) had its worktree deleted and its commits left reachable
# only from a local branch — or, when the branch was reset onto origin/main, from
# nothing at all. Measured on a live install over a 7-day window: 30 worker-created
# files never reached origin/main, including a whole guard script and five
# proposals. No monitor went red — the loss is invisible in `git log main`.
#
# The sentinel-based skips already in spawn-worker.sh only protect a worktree that
# a *successful* /done verify-gate had time to mark. The losses above happened to
# worktrees with NO sentinel: nothing ran to write one. This guard closes that half
# by deriving the answer from git state instead of from a file someone remembered
# to drop.
#
# It is deliberately conservative: it never deletes and never rewrites history. It
# only decides "may this path be destroyed?" and, when the answer is no, makes the
# work durable (push the branch to origin) and visible (sentinel
# .agentos-undelivered, which spawn-worker's GC, scripts/lib/delivery-guard.sh and
# scripts/undelivered-work-sweep.py all already honour).
#
# Usage:
#   . "$REPO_ROOT/scripts/lib/worker-worktree.sh"
#   preserve_undelivered_worktree "$wt" || continue   # 1 = do NOT touch this path
#
# AGENTOS_WORKTREE_GUARD_DISABLE=1 restores the pre-fix behaviour. It exists for
# scripts/test-worktree-reuse-guard.sh, which runs the SAME code path twice so the
# baseline half is genuinely the old behaviour and not a hand-written imitation of
# it. Do not set it anywhere else.

# preserve_undelivered_worktree <worktree-path>
#   0 — nothing of value here, the caller may remove/reset the path
#   1 — the path holds work that is not in origin/main; branch pushed, sentinel
#       written, caller MUST leave it alone
preserve_undelivered_worktree() {
  local wt="${1:-}" head br reason dirty
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  [ "${AGENTOS_WORKTREE_GUARD_DISABLE:-0}" = "1" ] && return 0
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0

  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  reason=""

  if [ -n "$head" ] && ! git -C "$wt" merge-base --is-ancestor "$head" origin/main 2>/dev/null; then
    reason="commits not in origin/main (branch=$br head=$head)"
  else
    # Uncommitted work counts too: a freshly written, still UNTRACKED script in a
    # worktree is exactly what a GC pass silently deletes — observed on the very
    # detector written for this failure class.
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null | head -n 5)"
    [ -n "$dirty" ] && reason="uncommitted/untracked changes in the working tree"
  fi

  [ -n "$reason" ] || return 0

  # Durability first: the local branch ref is a single point of failure (a later
  # glob-based branch reap, a `git gc` after a reset). origin is not.
  if [ -n "$br" ] && [ "$br" != "HEAD" ]; then
    if git -C "$wt" push -q -u origin "$br" 2>/dev/null; then
      echo "worktree-guard: pushed orphan branch $br -> origin" >&2
    else
      echo "worktree-guard: WARN could not push orphan branch $br (work is local-only)" >&2
    fi
  fi

  printf 'branch=%s\nhead=%s\nreason=%s\nsource=%s\nat=%s\n' \
    "$br" "$head" "$reason" "spawn-worker/worktree-guard" "$(date -u +%FT%TZ)" \
    > "$wt/.agentos-undelivered" 2>/dev/null || true

  echo "worktree-guard: PRESERVING $wt — $reason" >&2
  return 1
}
