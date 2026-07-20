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
# Self-clearing: if the commits have landed since the sentinel was written, the guard
# removes it and allows the post. A worker who re-merged by hand is never locked out.
#
# `outcome: blocked` is always publishable — /blocked must stay reachable, otherwise a
# failed delivery would leave the worker with no way to finalize at all.

delivery_guard_check() {
  local text="${1:-}" wt head
  # Only green completions are gated.
  printf '%s' "$text" | grep -qiE 'outcome:[[:space:]]*done' || return 0

  wt="${AGENTOS_WORKER_WORKTREE:-}"
  [ -z "$wt" ] && wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$wt" ] && [ -f "$wt/.agentos-undelivered" ] || return 0

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
