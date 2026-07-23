#!/usr/bin/env bash
# delivery-guard.sh — backend-agnostic guard: `outcome: done` is UNPUBLISHABLE while
# the worker's commits are not in origin/main.
#
# Companion to scripts/worker-deliver.sh. That script makes the verify-gate an exit
# code; this one closes the last hole — the step where the bypass actually happened.
# A worker whose delivery FAILED can still reach the task backend and post a green
# `outcome: done | score: 5/5`. The gate therefore lives in the TRANSPORT, not in the
# agent's instructions: the comment call itself dies non-zero.
#
# It is deliberately NOT ClickUp-specific. scripts/lib/task-queue.sh wraps every
# backend's tq_comment with it, so a Linear/Jira/GitHub-Issues adapter inherits the
# same protection for free.
#
# Contract:
#   delivery_guard_check <comment_text>
#     exit 0  — publish it (text is not a green done, OR the work really is delivered)
#     exit 1  — REFUSE, reason on stderr (caller must abort the post)
#
# Two independent conditions refuse the post:
#   (a) the sentinel .agentos-undelivered is on disk — scripts/worker-deliver.sh writes it
#       when the commits did NOT reach origin/main;
#   (b) no sentinel, but the branch still carries commits outside origin/main — i.e. the
#       report is running AHEAD of the delivery.
# (b) exists because (a) alone is a trace of a delivery ATTEMPT: a worker that posts its
# green comment from its own /goal loop, before /done ever reaches the delivery step, has
# no sentinel on disk yet — there was nothing to check and the green report went out first
# (live incident: a `done` comment saying "the merge will be done by the /done skill
# automatically", with the merge then performed by hand). The only thing that breaks the
# "report first, deliver later" ordering is the comment itself looking at branch state.
#
# Self-clearing: if the commits have landed since the sentinel was written, the guard
# removes it and allows the post. A worker who re-merged by hand is never locked out.
#
# `outcome: blocked` is always publishable — /blocked must stay reachable, otherwise a
# failed delivery would leave the worker with no way to finalize at all.

delivery_guard_check() {
  local text="${1:-}" wt head top
  # Only green completions are gated.
  printf '%s' "$text" | grep -qiE 'outcome:[[:space:]]*done' || return 0

  # Domain of the guard: the WORKER inside its own worktree ($AGENTOS_WORKER_WORKTREE,
  # exported by scripts/spawn-worker.sh) — and nobody else. Falling back to
  # `git rev-parse --show-toplevel` for the live check would put every checkout on trial:
  # an operator/sysadmin holding a local unpushed commit on main would get their comment
  # refused over a delivery that is not theirs. The guard's claim — "the worker's branch
  # is not merged" — is simply undefined outside the worker contour, so there it stays quiet.
  wt="${AGENTOS_WORKER_WORKTREE:-}"
  if [ -z "$wt" ]; then
    # One exception: the env is gone but a sentinel physically lies in the current
    # checkout. Only worker-deliver.sh writes that file, so it is an unambiguous trace of
    # undelivered work — no false positives outside a worker worktree (no file there).
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] && [ -f "$top/.agentos-undelivered" ] || return 0
    wt="$top"
  fi
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0

  # (b) LIVE check — branch state now, not the trace of an earlier attempt.
  if [ ! -f "$wt/.agentos-undelivered" ]; then
    git -C "$wt" fetch origin main -q 2>/dev/null || true
    if [ -n "$(git -C "$wt" log origin/main..HEAD --oneline 2>/dev/null)" ]; then
      {
        echo "REFUSED: 'outcome: done' is not publishable — the commits are NOT in origin/main yet."
        echo "  Worktree: $wt"
        echo "  Undelivered:"
        git -C "$wt" log origin/main..HEAD --oneline 2>/dev/null | sed 's/^/    /'
        echo "  Deliver first, report second:"
        echo "    \"\${AGENTOS_WORKER_MAIN_REPO:-\$PWD}/scripts/worker-deliver.sh\""
        echo "  exit 0 -> publish done; exit 3 -> go to /blocked."
      } >&2
      return 1
    fi
    return 0
  fi

  # (a) sentinel path — a delivery attempt already failed here.
  git -C "$wt" fetch origin main -q 2>/dev/null || true
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$head" ] && git -C "$wt" merge-base --is-ancestor "$head" origin/main 2>/dev/null; then
    rm -f "$wt/.agentos-undelivered"
    echo "delivery-guard: commits reached origin/main, sentinel cleared — publishing" >&2
    return 0
  fi

  {
    echo "REFUSED: 'outcome: done' is not publishable — the work is NOT in origin/main."
    echo "  Sentinel: $wt/.agentos-undelivered"
    sed 's/^/    /' "$wt/.agentos-undelivered" 2>/dev/null
    echo "  Branch orphaned, worktree preserved. Finalize via /blocked, not /done."
    echo "  The guard clears itself once the commits genuinely land in origin/main."
  } >&2
  return 1
}
