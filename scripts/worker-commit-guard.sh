#!/bin/bash
# worker-commit-guard.sh — pre-commit index assertion for workers.
#
# The lesson behind it: a worker ran green, then `git add` staged 2 files out of
# 5 and committed that silently — the other 3 edits never reached HEAD. A green
# run does NOT prove the edit lands. The working tree is what you SEE; the INDEX
# is what gets COMMITTED. They diverge (a sibling's `git restore`, a stale path,
# a typo'd glob, a .gitignore hit), and the divergence is silent.
#
# So: before `git commit`, assert the INDEX — never the working tree — matches
# the files you meant to ship.
#
#   scripts/worker-commit-guard.sh path/to/edited-file.md CHANGELOG.md
#
# Exit codes (all print the actual staged set, so the failure is legible):
#   0 — index exactly matches the expected set -> safe to commit
#   2 — index EMPTY: the commit would be a no-op ("silent commit of nothing")
#   3 — an expected file is MISSING from the index (the failure above, verbatim)
#   4 — an UNEXPECTED file is staged (cross-task contamination)
#   5 — WRONG REPOSITORY: cwd is not the worker's own worktree
#   64 — usage / not a git repo
#
# Intentionally read-only: it never stages, unstages, or commits. It answers one
# question — "is the index what I think it is?" — and refuses to guess.
set -uo pipefail

if [ $# -eq 0 ]; then
  echo "usage: worker-commit-guard.sh <expected-path> [<expected-path>...]" >&2
  echo "       (paths as they appear in \`git diff --cached --name-only\`, repo-relative)" >&2
  exit 64
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "guard: not a git repo (cwd=$PWD)" >&2; exit 64; }

# --- wrong-repo assert --------------------------------------------------------
# The index can be perfectly correct and still belong to the WRONG repository. An
# agent's shell tool typically remembers its working directory between calls: one
# `cd <main checkout>` for a grep moves every later git command out of the worker's
# worktree and into the main checkout on `main`, where `git add` + `git commit`
# succeed and the work lands on a branch the worker never delivers. Observed live:
# the index in the main checkout matched 4 of 5 expected files, i.e. a 5-for-5
# `git add` would have passed the checks below and committed straight onto `main`.
if [ -n "${AGENTOS_WORKER_WORKTREE:-}" ]; then
  TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  if [ "$TOP" != "$AGENTOS_WORKER_WORKTREE" ]; then
    echo "GUARD FAILED (5): wrong repository — cwd resolves to '$TOP'," >&2
    echo "  but your worktree is '$AGENTOS_WORKER_WORKTREE' (branch ${AGENTOS_WORKER_BRANCH:-?})." >&2
    echo "  A commit here would land outside your branch and never be delivered." >&2
    echo "  Fix: cd \"\$AGENTOS_WORKER_WORKTREE\" (or use git -C) and re-stage." >&2
    exit 5
  fi
fi

# The index — NOT `git status`, NOT the working tree. --diff-filter excludes nothing:
# adds, modifies, deletes and renames all count as "staged for commit".
STAGED="$(git diff --cached --name-only)"

echo "guard: staged in index (cwd=$PWD, branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)):"
if [ -z "$STAGED" ]; then
  echo "  <empty>"
else
  printf '  %s\n' $STAGED
fi

if [ -z "$STAGED" ]; then
  echo "GUARD FAILED (2): index is EMPTY — a commit here would ship nothing." >&2
  echo "  Your edits may exist in the working tree and still never reach HEAD." >&2
  echo "  Run \`git status\` and \`git add\` the real paths, then re-run the guard." >&2
  exit 2
fi

rc=0

# (3) expected-but-not-staged — the "staged 2 of 5, committed silently" bug
missing=""
for want in "$@"; do
  printf '%s\n' $STAGED | grep -qxF -- "$want" || missing="$missing $want"
done
if [ -n "$missing" ]; then
  echo "GUARD FAILED (3): expected file(s) NOT in the index:$missing" >&2
  echo "  This is the silent-loss shape: the work exists somewhere, but not in the commit." >&2
  echo "  A sibling worker's \`git restore\`/\`checkout\` can also have reverted it — check the file content." >&2
  rc=3
fi

# (4) staged-but-not-expected — someone else's file riding along in your commit
extra=""
for got in $STAGED; do
  hit=""
  for want in "$@"; do [ "$got" = "$want" ] && hit=1 && break; done
  [ -n "$hit" ] || extra="$extra $got"
done
if [ -n "$extra" ]; then
  echo "GUARD FAILED (4): UNEXPECTED file(s) staged:$extra" >&2
  echo "  Commit only your own paths: \`git reset\` then \`git add <your files>\`." >&2
  [ "$rc" -eq 0 ] && rc=4
fi

if [ "$rc" -eq 0 ]; then
  echo "GUARD OK: index matches the expected set exactly ($# file(s)) — safe to commit"
fi
exit "$rc"
