#!/bin/bash
# test-worktree-reuse-guard.sh — reproduce the "reused worktree eats undelivered work"
# failure on a throwaway fixture, then prove the guard closes it.
#
# The baseline half sets AGENTOS_WORKTREE_GUARD_DISABLE=1 (pre-fix behaviour) and runs
# the SAME code path as the fixed half. So the delta is attributable to the guard and
# not to a hand-written imitation of the old code.
#
# Scenarios:
#   1. tick 1 works + commits + dies hard (no /done) → tick 2 reuses the path
#      baseline: commit never reaches origin, no sentinel, uncommitted work deleted
#      fixed:    branch pushed to origin, sentinel written, path preserved
#   2. worker-deliver.sh on a worktree sitting on the WRONG branch (the persistent-cwd
#      trap): must exit 3 (FAILED), not 2 (n/a → /done reports green)
#   3. delivery-guard.sh must refuse `outcome: done` while the sentinel stands, and
#      must self-clear once the commits genuinely land in origin/main
#   4. (negative) DELIVERED work is still reaped — the guard must not hoard paths
#   5. worker-commit-guard.sh must refuse to bless an index in the WRONG repository
#
# Usage: scripts/test-worktree-reuse-guard.sh          (exit 0 = all scenarios pass)
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
. "$REPO_ROOT/scripts/lib/worker-worktree.sh"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1: expected '$3', got '$2'"; fi; }

git config --global --get user.email >/dev/null 2>&1 || export GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_NAME="fixture" GIT_COMMITTER_NAME="fixture"

# --- fixture: bare origin + hub clone + per-slug worktree base --------------
build_fixture() {
  local root="$1"
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare -b main "$root/origin.git"
  git init -q -b main "$root/hub"
  git -C "$root/hub" config user.email t@t; git -C "$root/hub" config user.name fixture
  echo seed > "$root/hub/README.md"
  git -C "$root/hub" add README.md
  git -C "$root/hub" commit -qm seed
  git -C "$root/hub" remote add origin "$root/origin.git"
  git -C "$root/hub" push -q -u origin main
  mkdir -p "$root/.worktrees"
}

# --- tick 1: a worker does real work, commits, and dies without /done -------
tick1() {
  local root="$1" slug=demo
  git -C "$root/hub" worktree add -q --force -B "worker/$slug-1000" "$root/.worktrees/$slug" origin/main
  echo "delivered briefing" > "$root/.worktrees/$slug/artifact.txt"
  git -C "$root/.worktrees/$slug" add artifact.txt
  git -C "$root/.worktrees/$slug" commit -qm "worker: demo — artifact"
  echo "work in progress, never committed" > "$root/.worktrees/$slug/wip-untracked.txt"
  git -C "$root/.worktrees/$slug" rev-parse HEAD
}

# --- tick 2: the launcher reuses the slug path (mirrors scripts/spawn-worker.sh:
#     orphan GC → same-slug requeue guard → move-aside → prune → worktree add) --
tick2() {
  local root="$1" slug=demo wt
  wt="$root/.worktrees/$slug"
  git -C "$root/hub" fetch -q origin main
  # orphan GC (no tmux session named worker-<slug> exists in the fixture → reap path)
  if preserve_undelivered_worktree "$wt"; then
    git -C "$root/hub" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    git -C "$root/hub" worktree prune
  fi
  # same-slug requeue: sentinel → move aside, keeping branch + files
  if [ -f "$wt/.agentos-undelivered" ]; then
    git -C "$root/hub" worktree move "$wt" "$wt.undelivered-2000" 2>/dev/null || true
  else
    rm -rf "$wt"; git -C "$root/hub" worktree prune
  fi
  git -C "$root/hub" worktree add -q --force -B "worker/$slug-2000" "$wt" origin/main
}

verdict() {   # <root> <sha> <label>
  local root="$1" sha="$2" label="$3" on_origin sentinel wip
  git -C "$root/origin.git" cat-file -e "$sha^{commit}" 2>/dev/null && on_origin=yes || on_origin=no
  if [ "$on_origin" = yes ]; then
    git -C "$root/origin.git" branch --contains "$sha" 2>/dev/null | grep -q . || on_origin=no
  fi
  if [ -f "$root/.worktrees/demo/.agentos-undelivered" ] || \
     [ -f "$root/.worktrees/demo.undelivered-2000/.agentos-undelivered" ]; then sentinel=yes; else sentinel=no; fi
  if [ -f "$root/.worktrees/demo/wip-untracked.txt" ] || \
     [ -f "$root/.worktrees/demo.undelivered-2000/wip-untracked.txt" ]; then wip=kept; else wip=DELETED; fi
  echo "$label: tick1_commit_on_origin=$on_origin sentinel=$sentinel uncommitted_work=$wip"
}

echo "=== scenario 1: worktree reuse across two ticks ==="

echo "--- BASELINE (AGENTOS_WORKTREE_GUARD_DISABLE=1 → pre-fix behaviour) ---"
build_fixture "$FIX/base"
SHA_BASE="$(tick1 "$FIX/base")"
AGENTOS_WORKTREE_GUARD_DISABLE=1 tick2 "$FIX/base"
B="$(verdict "$FIX/base" "$SHA_BASE" baseline)"; echo "  $B"
check "baseline commit reachable from origin" "$(echo "$B" | grep -o 'on_origin=[a-z]*' | cut -d= -f2)" "no"
check "baseline sentinel"                     "$(echo "$B" | grep -o 'sentinel=[a-z]*'  | cut -d= -f2)" "no"
check "baseline uncommitted work"             "$(echo "$B" | grep -o 'uncommitted_work=[A-Za-z]*' | cut -d= -f2)" "DELETED"

echo "--- FIXED (guard active) ---"
build_fixture "$FIX/fixed"
SHA_FIX="$(tick1 "$FIX/fixed")"
tick2 "$FIX/fixed" 2>/dev/null
F="$(verdict "$FIX/fixed" "$SHA_FIX" fixed)"; echo "  $F"
check "fixed commit reachable from origin" "$(echo "$F" | grep -o 'on_origin=[a-z]*' | cut -d= -f2)" "yes"
check "fixed sentinel"                     "$(echo "$F" | grep -o 'sentinel=[a-z]*'  | cut -d= -f2)" "yes"
check "fixed uncommitted work"             "$(echo "$F" | grep -o 'uncommitted_work=[A-Za-z]*' | cut -d= -f2)" "kept"

# the new tick must still get a usable worktree — a guard that blocks the queue is not a fix
if git -C "$FIX/fixed/hub" worktree list --porcelain | grep -qx "worktree $FIX/fixed/.worktrees/demo"; then
  ok "fixed: new tick got its worktree (queue not blocked)"
else bad "fixed: new tick has no worktree — guard blocked the queue"; fi

# fidelity: the launcher must actually call the guard on both destructive paths
grep -q 'preserve_undelivered_worktree "\$wt" || continue' "$REPO_ROOT/scripts/spawn-worker.sh" \
  && ok "spawn-worker.sh guards the orphan-GC reap" \
  || bad "spawn-worker.sh orphan-GC reap is unguarded"
grep -q 'preserve_undelivered_worktree "\$WORKER_WORKTREE"' "$REPO_ROOT/scripts/spawn-worker.sh" \
  && ok "spawn-worker.sh guards the same-slug requeue" \
  || bad "spawn-worker.sh same-slug requeue is unguarded"

echo
echo "=== scenario 2: worker-deliver.sh on the wrong branch (persistent-cwd trap) ==="
build_fixture "$FIX/wrongbr"
tick1 "$FIX/wrongbr" >/dev/null
git -C "$FIX/wrongbr/.worktrees/demo" checkout -q -B other-branch origin/main   # HEAD moved off the worker branch
OUT="$(AGENTOS_WORKER_WORKTREE="$FIX/wrongbr/.worktrees/demo" \
       AGENTOS_WORKER_BRANCH="worker/demo-1000" \
       AGENTOS_WORKER_MAIN_REPO="$FIX/wrongbr/hub" \
       "$REPO_ROOT/scripts/worker-deliver.sh" 2>&1)"; RC=$?
echo "  worker-deliver.sh exit=$RC :: $(echo "$OUT" | head -n1)"
check "wrong-branch delivery exit code" "$RC" "3"
[ -f "$FIX/wrongbr/.worktrees/demo/.agentos-undelivered" ] \
  && ok "wrong-branch delivery wrote the sentinel" \
  || bad "wrong-branch delivery left no sentinel"

echo
echo "=== scenario 3: delivery-guard refuses 'outcome: done' on undelivered work ==="
# shellcheck source=scripts/lib/delivery-guard.sh
. "$REPO_ROOT/scripts/lib/delivery-guard.sh"
build_fixture "$FIX/guard"
SHA_GUARD="$(tick1 "$FIX/guard")"
printf 'branch=worker/demo-1000\nhead=%s\nreason=fixture\n' "$SHA_GUARD" \
  > "$FIX/guard/.worktrees/demo/.agentos-undelivered"
( AGENTOS_WORKER_WORKTREE="$FIX/guard/.worktrees/demo" \
  delivery_guard_check "outcome: done | score: 5/5 | note: fixture" ) >/dev/null 2>&1; RC2=$?
check "delivery-guard on undelivered work (1 = refused)" "$RC2" "1"
( AGENTOS_WORKER_WORKTREE="$FIX/guard/.worktrees/demo" \
  delivery_guard_check "outcome: blocked | note: fixture" ) >/dev/null 2>&1; RC3=$?
check "delivery-guard still lets 'outcome: blocked' through" "$RC3" "0"
# self-clearing: once the commits land, the same call must pass and drop the sentinel
git -C "$FIX/guard/.worktrees/demo" push -q origin HEAD:main
( AGENTOS_WORKER_WORKTREE="$FIX/guard/.worktrees/demo" \
  delivery_guard_check "outcome: done | score: 5/5 | note: fixture" ) >/dev/null 2>&1; RC4=$?
check "delivery-guard after real delivery (0 = published)" "$RC4" "0"
[ -f "$FIX/guard/.worktrees/demo/.agentos-undelivered" ] \
  && bad "sentinel survived a genuine delivery — worker stays locked out" \
  || ok "sentinel self-cleared after the commits landed"

echo
echo "=== scenario 4 (negative): DELIVERED work is still reaped — the guard must not hoard ==="
build_fixture "$FIX/clean"
SHA_CLEAN="$(tick1 "$FIX/clean")"
rm -f "$FIX/clean/.worktrees/demo/wip-untracked.txt"                       # clean tree
git -C "$FIX/clean/.worktrees/demo" push -q origin HEAD:main               # work delivered
tick2 "$FIX/clean" 2>/dev/null
if [ -d "$FIX/clean/.worktrees/demo.undelivered-2000" ]; then
  bad "delivered worktree was preserved anyway — guard hoards paths"
else ok "delivered worktree reaped normally (no .undelivered-* left behind)"; fi
[ -f "$FIX/clean/.worktrees/demo/.agentos-undelivered" ] \
  && bad "sentinel written for delivered work" \
  || ok "no sentinel for delivered work"
git -C "$FIX/clean/hub" merge-base --is-ancestor "$SHA_CLEAN" origin/main 2>/dev/null \
  && ok "delivered commit is an ancestor of origin/main" \
  || bad "fixture broken: delivered commit not on main"

echo
echo "=== scenario 5: worker-commit-guard.sh refuses an index in the WRONG repo ==="
build_fixture "$FIX/repo"
tick1 "$FIX/repo" >/dev/null
WT5="$FIX/repo/.worktrees/demo"
# the neighbour checkout the persistent-cwd trap drops the worker into
git init -q -b main "$FIX/repo/neighbour"
git -C "$FIX/repo/neighbour" config user.email t@t; git -C "$FIX/repo/neighbour" config user.name fixture
echo neighbour > "$FIX/repo/neighbour/README.md"
git -C "$FIX/repo/neighbour" add README.md && git -C "$FIX/repo/neighbour" commit -qm seed
echo "worker output" > "$FIX/repo/neighbour/artifact.txt"
git -C "$FIX/repo/neighbour" add artifact.txt          # a perfectly correct index — in the wrong repo
OUT5="$(cd "$FIX/repo/neighbour" && AGENTOS_WORKER_WORKTREE="$WT5" AGENTOS_WORKER_BRANCH="worker/demo-1000" \
        "$REPO_ROOT/scripts/worker-commit-guard.sh" artifact.txt 2>&1)"; RC5=$?
echo "  commit-guard (wrong repo) exit=$RC5 :: $(echo "$OUT5" | grep -m1 'GUARD FAILED' || echo "$OUT5" | head -n1)"
check "wrong-repo commit-guard exit code" "$RC5" "5"
# positive control: the SAME staged set inside the worker's own worktree passes
echo "worker output" > "$WT5/artifact2.txt"
git -C "$WT5" add artifact2.txt
OUT5B="$(cd "$WT5" && AGENTOS_WORKER_WORKTREE="$WT5" AGENTOS_WORKER_BRANCH="worker/demo-1000" \
         "$REPO_ROOT/scripts/worker-commit-guard.sh" artifact2.txt 2>&1)"; RC5B=$?
echo "  commit-guard (own worktree) exit=$RC5B :: $(echo "$OUT5B" | grep -m1 'GUARD OK' || echo "$OUT5B" | head -n1)"
check "own-worktree commit-guard exit code" "$RC5B" "0"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
