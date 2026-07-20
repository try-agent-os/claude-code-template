#!/bin/bash
# worker-deliver.sh — merge a worker's isolated worktree into origin/main, then PROVE it landed.
#
# This is step 0 of `/done`, extracted out of .claude/commands/done.md into a real
# executable for one reason: **prose cannot be enforced, an exit code can.**
#
# The defect this closes:
#   • A worker reports `outcome: done`, its fast-forward push silently lost a race with a
#     sibling worker, and the fix never reaches main. The branch is orphaned; the work is
#     only found by hand days later. GitHub happily serves dangling commits by SHA, so even
#     a commit link in the report looks healthy — the loss is invisible in `git log main`.
#   • An earlier fix put the verify-gate INSIDE done.md. The gate was logically correct
#     (scripts/test-done-verify-gate.sh proves it flips to FAILED on a rejected push) and
#     was still bypassed twice: the gate ran, printed `DELIVERY_STATUS=FAILED`, and the
#     model walked straight past it into the done path anyway.
#
# So the gate stops being a paragraph the agent is asked to obey and becomes an exit code
# it has to handle. Paired with the comment-time guard in scripts/lib/delivery-guard.sh
# (the task-queue transport refuses to post `outcome: done` while .agentos-undelivered
# exists), the bypass is mechanically unavailable rather than merely forbidden.
#
# Exit codes (the contract — done.md branches on these, nothing else):
#   0  ok      — every commit on this branch is an ancestor of origin/main. Safe to report done.
#   2  n/a     — nothing to deliver (no worktree, or no commits ahead of origin/main).
#   3  FAILED  — commits are NOT in origin/main. Sentinel written, worktree preserved,
#                operator alerted. The caller MUST go to /blocked, never /done.
set -uo pipefail

WT="${AGENTOS_WORKER_WORKTREE:-}"
BR="${AGENTOS_WORKER_BRANCH:-}"
MAIN="${AGENTOS_WORKER_MAIN_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"

# No worktree → submodule-routed worker or shared-tree fallback: not ours to deliver.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  echo "DELIVERY n/a: no worker worktree (AGENTOS_WORKER_WORKTREE unset or missing)"
  exit 2
fi

cd "$WT" || { echo "DELIVERY FAILED: cannot cd into worktree $WT" >&2; exit 3; }

git fetch origin main -q 2>/dev/null || true   # stale origin/main would fake "nothing to merge"
if [ -z "$(git log origin/main..HEAD --oneline 2>/dev/null)" ]; then
  # Nothing ahead of origin/main ⇒ HEAD is an ancestor of it ⇒ anything this worktree
  # once held IS delivered. Drop a sentinel left by an earlier failed attempt, otherwise
  # a worker that re-merged by hand stays locked out of `outcome: done` forever.
  rm -f "$WT/.agentos-undelivered"
  echo "DELIVERY n/a: no commits on ${BR:-HEAD} — nothing to merge"
  exit 2
fi

# --- merge: ff-push straight to origin/main, retrying past sibling-worker races ---
git push -u origin "$BR"          # unique per-worker branch — never races a sibling
for _ in 1 2 3 4 5; do
  git fetch origin main
  git rebase origin/main || { git rebase --abort 2>/dev/null; break; }
  if git push origin HEAD:main; then echo "MERGED $BR -> origin/main"; break; fi
  sleep 2
done

# --- VERIFY GATE: every commit in origin/main..HEAD is BY DEFINITION undelivered ---
git fetch origin main -q 2>/dev/null || true
UNDELIVERED=""
for sha in $(git rev-list origin/main..HEAD 2>/dev/null); do
  git merge-base --is-ancestor "$sha" origin/main 2>/dev/null || UNDELIVERED="$UNDELIVERED $sha"
done

if [ -z "$UNDELIVERED" ] && git merge-base --is-ancestor "$(git rev-parse HEAD)" origin/main 2>/dev/null; then
  rm -f "$WT/.agentos-undelivered"   # a previous failed attempt may have left one; the work landed now
  echo "DELIVERY OK: every commit is an ancestor of origin/main"
  exit 0
fi

echo "DELIVERY FAILED: not in origin/main —$UNDELIVERED (branch '$BR' orphaned, work NOT delivered)" >&2

# Sentinel — two jobs:
#  (1) spawn-worker.sh's orphan GC must NOT reap this worktree when the session dies
#      (the GC keys on a dead tmux session, which /done is about to cause). Self-clearing:
#      the GC reaps it once the commits genuinely land in origin/main.
#  (2) the comment guard reads it and refuses to post `outcome: done`.
printf 'branch=%s\nhead=%s\nundelivered=%s\ntask=%s\nat=%s\n' \
  "$BR" "$(git rev-parse HEAD)" "$UNDELIVERED" "${AGENTOS_WORKER_TASK_ID:-unknown}" \
  "$(date -u +%FT%TZ)" > "$WT/.agentos-undelivered"

git push -u origin "$BR" 2>/dev/null || true   # best-effort: keep the work reachable from the remote

[ -x "${MAIN}/scripts/notify-operator.sh" ] && "${MAIN}/scripts/notify-operator.sh" \
  --source worker --severity warn \
  --msg "worker ${AGENTOS_WORKER_TASK_ID:-$BR}: /done verify-gate FAILED — commits never reached main, branch '${BR}' orphaned, worktree preserved, needs a manual re-merge" \
  2>/dev/null || true

exit 3
