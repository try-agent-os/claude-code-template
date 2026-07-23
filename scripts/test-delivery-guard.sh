#!/usr/bin/env bash
# test-delivery-guard.sh — fixture for delivery_guard_check() (scripts/lib/delivery-guard.sh).
#
# The guard refuses to publish `outcome: done` while the worker's commits are not in
# origin/main. That claim is checkable, but it has a DOMAIN: the worker's branch.
# Outside the worker contour (operator, sysadmin, a hand-written comment from the main
# checkout) "not merged yet" is a normal working state, not a defect — refusing there
# breaks the wrong process.
#
# So the fixture holds both directions at once:
#   1. worker, commit outside origin/main   -> REFUSE (live check: the report must not precede delivery)
#   2. non-worker, commit outside origin/main -> ALLOW  (guard stays silent outside its domain)
#   3. worker, commits delivered            -> ALLOW
#   4. non-worker but a sentinel lies in the checkout -> REFUSE (env lost, delivery trace present)
#   5. `outcome: blocked` on an undelivered branch    -> ALLOW (/blocked must stay publishable)
#
# Case 1 is the regression this fixture was written for: before the live check the guard
# only reacted to the .agentos-undelivered sentinel, which scripts/worker-deliver.sh writes.
# A worker that posts its green comment BEFORE reaching the delivery step has no sentinel
# on disk yet — there was nothing to check, and the green report went out ahead of the merge.
#
# Run against an arbitrary version of the lib (for the baseline half of a fix):
#   scripts/test-delivery-guard.sh [path-to-delivery-guard.sh]
# Exit 0 — every case passed, 1 — at least one failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-$REPO_ROOT/scripts/lib/delivery-guard.sh}"
[ -f "$TARGET" ] || { echo "no such file: $TARGET" >&2; exit 2; }
grep -q '^delivery_guard_check() {' "$TARGET" || {
  echo "delivery_guard_check() not found in $TARGET" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Harness: source the lib, call the guard, surface its exit code.
HARNESS="$TMP/harness.sh"
{
  echo 'set -uo pipefail'
  printf '. %q\n' "$TARGET"
  echo 'delivery_guard_check "$1" || exit 1'
  echo 'echo PASSED-THROUGH'
} > "$HARNESS"

# --- repo fixture: bare origin + working clone ------------------------------
setup_repo() {  # $1 = name; prints the path to the working clone
  local name="$1" bare="$TMP/$1.git" work="$TMP/$1"
  git init -q --bare "$bare"
  git clone -q "$bare" "$work" 2>/dev/null
  git -C "$work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$work" push -q origin HEAD:main 2>/dev/null
  git -C "$work" fetch -q origin main 2>/dev/null
  printf '%s' "$work"
}
add_unpushed_commit() {
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m undelivered
}

pass=0; fail=0
echo "target: $TARGET"

# 3: worker, commits delivered -> publish
W="$(setup_repo worker)"
( cd "$W" && env AGENTOS_WORKER_WORKTREE="$W" bash "$HARNESS" "outcome: done | score: 5/5" >/dev/null 2>&1 )
rc=$?; if [ $rc -eq 0 ]; then echo "  ok   [ALLOW] worker, commits delivered -> publish"; pass=$((pass+1));
else echo "  FAIL [expected ALLOW] worker with delivered commits was refused"; fail=$((fail+1)); fi

# 1: worker with a commit outside origin/main -> refuse (no sentinel on disk)
add_unpushed_commit "$W"
( cd "$W" && env AGENTOS_WORKER_WORKTREE="$W" bash "$HARNESS" "outcome: done" >/dev/null 2>&1 )
rc=$?; if [ $rc -ne 0 ]; then echo "  ok   [REFUSE] worker with an undelivered commit -> refused"; pass=$((pass+1));
else echo "  FAIL [expected REFUSE] worker with an undelivered commit was allowed to report done"; fail=$((fail+1)); fi

# 5: blocked is always publishable
( cd "$W" && env AGENTOS_WORKER_WORKTREE="$W" bash "$HARNESS" "outcome: blocked | note: x" >/dev/null 2>&1 )
rc=$?; if [ $rc -eq 0 ]; then echo "  ok   [ALLOW] outcome: blocked on an undelivered branch"; pass=$((pass+1));
else echo "  FAIL [expected ALLOW] outcome: blocked was refused"; fail=$((fail+1)); fi

# 2: non-worker (env unset) with an undelivered commit -> the guard must stay silent
N="$(setup_repo plain)"
add_unpushed_commit "$N"
( cd "$N" && env -u AGENTOS_WORKER_WORKTREE bash "$HARNESS" "outcome: done | score: 4/5" >/dev/null 2>&1 )
rc=$?; if [ $rc -eq 0 ]; then echo "  ok   [ALLOW] non-worker with an undelivered commit -> comment goes through"; pass=$((pass+1));
else echo "  FAIL [expected ALLOW] non-worker was refused (guard reaching outside its domain)"; fail=$((fail+1)); fi

# 4: env lost but the sentinel is on disk -> refuse
printf 'DELIVERY_STATUS=FAILED\n' > "$N/.agentos-undelivered"
( cd "$N" && env -u AGENTOS_WORKER_WORKTREE bash "$HARNESS" "outcome: done" >/dev/null 2>&1 )
rc=$?; if [ $rc -ne 0 ]; then echo "  ok   [REFUSE] sentinel without env -> refused"; pass=$((pass+1));
else echo "  FAIL [expected REFUSE] sentinel ignored"; fail=$((fail+1)); fi
rm -f "$N/.agentos-undelivered"

echo "total: passed=$pass failed=$fail"
[ $fail -eq 0 ]
