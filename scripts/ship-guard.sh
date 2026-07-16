#!/usr/bin/env bash
# ship-guard.sh — phantom-ship detector for headless workers and scheduled agents.
#
# WHY: an agent commits and pushes, but its branch (a worker branch, or a feature
# branch a `git pull --rebase` left it on) is NOT main. The push lands on an orphan
# remote ref and the work is INVISIBLE to main — every downstream consumer that reads
# main never sees it. This failure is SILENT: the task status flips to in_review, the
# completion comment posts, the operator gets a "done" ping — but the artifact never
# reached origin/main, so "shipped" and "delivered" quietly diverge. Catching it needs
# manual git forensics unless something checks. This guard is the cheap detection net,
# generic to ANY root cause: it asserts the one invariant that matters — HEAD is an
# ancestor of origin/main.
#
# Run it AFTER you commit and push. Typical call right after `git push origin HEAD:main`:
#   bash scripts/ship-guard.sh
#
# Read-only except for one best-effort operator notification on failure. Reversible.
#
# Usage:
#   ship-guard.sh [REPO_ROOT] [FROM_ID]
#     REPO_ROOT — repo to check (default: $REPO_ROOT env, else this script's repo)
#     FROM_ID   — sender id passed to the notify hook (default: ship-guard)
#
# Notification hook: on failure the script runs $SHIP_GUARD_NOTIFY_CMD (via `bash -c`)
# with FROM_ID as $1 and the alert message as $2, if that variable is set and the
# command is resolvable. Wire it to whatever alerting this instance uses, e.g.:
#   export SHIP_GUARD_NOTIFY_CMD='scripts/my-notify.sh'
# Unset means detect-and-report only (stderr + exit code) — the guard still works.
#
# SHIP_GUARD_NO_NOTIFY=1 suppresses the notification — for a pre-push dry check (where
# a phantom-ship state is expected and about to be fixed) and for tests.
#
# Exit codes:
#   0 — HEAD is an ancestor of origin/main (the ship landed)
#   1 — phantom-ship: HEAD has commits not on origin/main (work orphaned) → notified
#   2 — could not determine (no git / fetch failed) — does not notify, just warns

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO="${1:-${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FROM_ID="${2:-ship-guard}"

cd "$REPO" 2>/dev/null || { echo "ship-guard: cannot cd $REPO" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ship-guard: not a git repo: $REPO" >&2; exit 2; }

HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)" || { echo "ship-guard: no HEAD" >&2; exit 2; }
HEAD_SHORT="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

# Refresh origin/main so we judge against the real remote tip, not a stale local ref.
if ! git fetch origin main --quiet 2>/dev/null; then
  echo "ship-guard: WARN could not fetch origin main — skipping verification (network/auth?)" >&2
  exit 2
fi

if git merge-base --is-ancestor "$HEAD_SHA" origin/main 2>/dev/null; then
  echo "ship-guard: OK — HEAD $HEAD_SHORT is on origin/main"
  exit 0
fi

# Phantom-ship: local HEAD carries commits that never reached origin/main.
AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
ORPHANED="$(git log --oneline origin/main..HEAD 2>/dev/null | head -5)"

MSG="[SHIP-GUARD] phantom-ship detected: HEAD ${HEAD_SHORT} on branch '${BRANCH}' is NOT on origin/main — ${AHEAD} commit(s) orphaned and invisible to main. Remediate: \`git push origin HEAD:main\` (verify fast-forward first)."

echo "ship-guard: FAIL — $MSG" >&2
[ -n "$ORPHANED" ] && { echo "ship-guard: orphaned commits:" >&2; echo "$ORPHANED" >&2; }

# Alert via the configured hook. Best-effort, never blocks the caller.
if [ "${SHIP_GUARD_NO_NOTIFY:-0}" != "1" ] && [ -n "${SHIP_GUARD_NOTIFY_CMD:-}" ]; then
  bash -c "$SHIP_GUARD_NOTIFY_CMD \"\$1\" \"\$2\"" _ "$FROM_ID" "$MSG" >/dev/null 2>&1 || true
fi

exit 1
