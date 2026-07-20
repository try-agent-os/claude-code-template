#!/bin/bash
# test-done-verify-gate.sh — verifier for the /done delivery gate.
#
# Proves the gate's contract WITHOUT touching a live repo: it builds a throwaway bare
# "origin" plus a worker worktree, then runs the REAL step-0 bash block extracted from
# .claude/commands/done.md (not a copy of it — extracting the shipped text is what keeps
# this test honest if the skill is edited) and the REAL scripts/worker-deliver.sh.
#
# Why this exists: a worker whose fast-forward push loses a race reports
# `outcome: done | score: 5/5` while its commits never reached origin/main — dangling in
# the object store, invisible in `git log main`, recovered by hand days later. The gate
# turns that silent loss into a loud blocked.
#
# Asserts:
#   (1) POSITIVE — push lands  → DELIVERY_STATUS=ok, no sentinel;
#   (2) NEGATIVE — push rejected → DELIVERY_STATUS=FAILED, sentinel written,
#       worktree ALIVE, branch ALIVE, commits still reachable;
#   (3) GC honours the sentinel: keeps an undelivered worktree whose session is dead;
#   (4) GC self-clears: reaps it once the commits ARE in origin/main;
#   (5) the branch-reap invariant + cleanup guards are present in the shipped scripts;
#   (6) worker-deliver.sh's exit-code contract (0 ok / 2 n/a / 3 FAILED);
#   (7) the comment transport refuses to publish `outcome: done` on an undelivered worktree.
#
# Exit 0 + "ALL CHECKS PASSED" on success; non-zero + the failed assertion otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DONE_MD="$REPO_ROOT/.claude/commands/done.md"
SPAWN_SH="$REPO_ROOT/scripts/spawn-worker.sh"
DELIVER_SH="$REPO_ROOT/scripts/worker-deliver.sh"
GUARD_SH="$REPO_ROOT/scripts/lib/delivery-guard.sh"
TASK_QUEUE_SH="$REPO_ROOT/scripts/lib/task-queue.sh"
CLICKUP_SH="$REPO_ROOT/scripts/clickup/clickup.sh"
TMP="$(mktemp -d /tmp/done-gate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@x GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@x
fail() { echo "FAIL: $1" >&2; exit 1; }
q() { "$@" >/dev/null 2>&1; }
ok() { echo "  ok — $1"; }

# --- extract the REAL step-0 block out of the skill -------------------------
# The block is a thin caller: it invokes scripts/worker-deliver.sh and branches on its
# EXIT CODE. The gate logic itself lives in that script (prose can be walked past; an
# exit code cannot).
awk '/^## 0\./{f=1} f && /^```bash$/{c=1;next} c && /^```$/{exit} c{print}' "$DONE_MD" > "$TMP/gate.sh"
[ -s "$TMP/gate.sh" ] || fail "could not extract step-0 bash block from $DONE_MD"
grep -q 'worker-deliver.sh' "$TMP/gate.sh" || fail "step-0 block does not call scripts/worker-deliver.sh"
grep -q 'rc=\$?' "$TMP/gate.sh" || fail "step-0 block does not capture worker-deliver.sh's exit code"
bash -n "$TMP/gate.sh" || fail "extracted gate block is not valid bash"
grep -q 'merge-base --is-ancestor' "$DELIVER_SH" || fail "worker-deliver.sh has no merge-base --is-ancestor gate"
grep -q 'agentos-undelivered'     "$DELIVER_SH" || fail "worker-deliver.sh never writes the .agentos-undelivered sentinel"
bash -n "$DELIVER_SH" || fail "worker-deliver.sh syntax error"
ok "step-0 delegates to worker-deliver.sh and branches on its exit code; both valid bash"

# stub notify-operator.sh so the gate's alert is observable but inert
mkdir -p "$TMP/stub/scripts"
cat > "$TMP/stub/scripts/notify-operator.sh" <<'EOF'
#!/bin/bash
echo "NOTIFY: $*" >> "${NOTIFY_LOG:-/dev/null}"
EOF
chmod +x "$TMP/stub/scripts/notify-operator.sh"
# the REAL worker-deliver.sh under the stub root, so step-0 resolves it via AGENTOS_WORKER_MAIN_REPO
cp "$DELIVER_SH" "$TMP/stub/scripts/worker-deliver.sh"

# --- build throwaway origin -------------------------------------------------
q git init --bare "$TMP/origin.git"
q git clone "$TMP/origin.git" "$TMP/seed"
cd "$TMP/seed"
echo seed > seed.txt; q git add seed.txt; q git commit -m seed
q git branch -M main; q git push -u origin main

# spawn a worker worktree exactly like spawn-worker.sh does
new_worker() { # $1 = slug
  rm -rf "$TMP/wt/$1"; mkdir -p "$TMP/wt"
  q git -C "$TMP/seed" fetch origin main
  q git -C "$TMP/seed" worktree add --force -B "worker/$1" "$TMP/wt/$1" origin/main
  echo "artifact-$1" > "$TMP/wt/$1/artifact-$1.md"
  q git -C "$TMP/wt/$1" add -A
  q git -C "$TMP/wt/$1" commit -m "worker: $1 — artifact"
}

run_gate() { # $1 = slug  → prints DELIVERY_STATUS
  ( export AGENTOS_WORKER_WORKTREE="$TMP/wt/$1" AGENTOS_WORKER_BRANCH="worker/$1" \
           AGENTOS_WORKER_MAIN_REPO="$TMP/stub" AGENTOS_WORKER_TASK_ID="TEST$1" \
           NOTIFY_LOG="$TMP/notify.log"
    cd "$TMP/wt/$1" || exit 1
    . "$TMP/gate.sh" >"$TMP/gate-$1.out" 2>&1
    echo "$DELIVERY_STATUS" )
}

# === (1) POSITIVE: the push lands → ok, no sentinel =========================
echo "[1] positive path — merge succeeds"
new_worker happy
STATUS="$(run_gate happy)"
[ "$STATUS" = "ok" ] || { cat "$TMP/gate-happy.out"; fail "expected DELIVERY_STATUS=ok, got '$STATUS'"; }
[ -f "$TMP/wt/happy/.agentos-undelivered" ] && fail "sentinel written on a SUCCESSFUL delivery"
q git -C "$TMP/seed" fetch origin main
git -C "$TMP/seed" ls-tree --name-only origin/main | grep -q 'artifact-happy.md' \
  || fail "gate said ok but the file is NOT in origin/main"
ok "DELIVERY_STATUS=ok, no sentinel, artifact-happy.md really is in origin/main"

# === (2) NEGATIVE: push rejected → FAILED, worktree+branch alive ============
echo "[2] negative path — ff-push rejected (simulates a lost race)"
cat > "$TMP/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/bash
while read -r _ _ ref; do
  [ "$ref" = "refs/heads/main" ] && { echo "remote: simulated rejection of $ref" >&2; exit 1; }
done
exit 0
EOF
chmod +x "$TMP/origin.git/hooks/pre-receive"

new_worker lost
LOST_SHA="$(git -C "$TMP/wt/lost" rev-parse HEAD)"
STATUS="$(run_gate lost)"

[ "$STATUS" = "FAILED" ] || { cat "$TMP/gate-lost.out"; fail "push was rejected but gate returned '$STATUS' (silent loss — the whole bug)"; }
ok "DELIVERY_STATUS=FAILED (not a green done)"
[ -d "$TMP/wt/lost" ] || fail "worktree was destroyed on gate failure — commits orphaned"
ok "worktree still alive"
[ -f "$TMP/wt/lost/.agentos-undelivered" ] || fail "no .agentos-undelivered sentinel written"
grep -q "$LOST_SHA" "$TMP/wt/lost/.agentos-undelivered" || fail "sentinel does not record the undelivered SHA"
ok "sentinel written and records SHA $(echo "$LOST_SHA" | cut -c1-8)"
q git -C "$TMP/seed" show-ref --verify "refs/heads/worker/lost" || fail "local branch gone — commits unreachable"
ok "local branch worker/lost still exists"
q git -C "$TMP/seed" fetch origin main
git -C "$TMP/seed" ls-tree --name-only origin/main | grep -q 'artifact-lost.md' \
  && fail "test is broken: the rejected file somehow reached origin/main"
ok "confirmed the work is genuinely NOT in origin/main"
grep -q 'NOTIFY' "$TMP/notify.log" 2>/dev/null || fail "operator was never alerted on delivery failure"
ok "operator alerted on delivery failure"

# === (3+4) GC honours the sentinel, and self-clears =========================
echo "[3] orphan GC — sentinel + dead session"
gc_keeps() { # replicates the shipped GC guard; asserted against the real script below
  local wt="$1" head
  [ -f "$wt/.agentos-undelivered" ] || return 1
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  [ -n "$head" ] && ! git -C "$TMP/seed" merge-base --is-ancestor "$head" origin/main 2>/dev/null
}
gc_keeps "$TMP/wt/lost" || fail "GC would reap the preserved worktree (undoing the gate)"
ok "GC keeps the undelivered worktree while its commits are missing from origin/main"

echo "[4] GC self-clears after a manual re-merge"
rm -f "$TMP/origin.git/hooks/pre-receive"          # whatever blocked the push is fixed
q git -C "$TMP/wt/lost" push origin HEAD:main      # ...and the work is re-merged
q git -C "$TMP/seed" fetch origin main
gc_keeps "$TMP/wt/lost" && fail "GC still refuses to reap after the commits landed (worktrees would pile up forever)"
ok "GC reaps it once the work is really in origin/main"

# === (5) guards present in the shipped scripts =============================
echo "[5] shipped-script guards"
grep -q 'agentos-undelivered' "$SPAWN_SH" || fail "spawn-worker.sh GC does not honour the sentinel"
grep -q 'KEEPING branch' "$SPAWN_SH"      || fail "spawn-worker.sh branch-reap lacks the not-in-origin/main invariant"
grep -q 'REFUSING cleanup' "$DONE_MD"     || fail "done.md cleanup step lacks the undelivered guard"
grep -q 'agentos-undelivered' "$REPO_ROOT/.claude/commands/blocked.md" \
  || fail "blocked.md cleanup would delete a preserved worktree"
bash -n "$SPAWN_SH" || fail "spawn-worker.sh syntax error"
bash -n "$CLICKUP_SH" || fail "clickup.sh syntax error"
bash -n "$GUARD_SH" || fail "delivery-guard.sh syntax error"
bash -n "$TASK_QUEUE_SH" || fail "task-queue.sh syntax error"
ok "sentinel guards present in spawn-worker.sh, done.md, blocked.md; libs are valid bash"

# === (6) exit-code contract of worker-deliver.sh ============================
# The bypass this closes was: read DELIVERY_STATUS=FAILED, go to /done anyway. Making the
# gate a separate process with a distinct non-zero exit turns "the agent should notice"
# into "the caller must handle rc".
echo "[6] worker-deliver.sh exit-code contract"
run_deliver() { # $1 = slug (or "" for the no-worktree case) → prints exit code
  ( export AGENTOS_WORKER_WORKTREE="${1:+$TMP/wt/$1}" AGENTOS_WORKER_BRANCH="worker/$1" \
           AGENTOS_WORKER_MAIN_REPO="$TMP/stub" NOTIFY_LOG="$TMP/notify.log"
    "$DELIVER_SH" >/dev/null 2>&1; echo $? )
}
[ "$(run_deliver '')" = 2 ] || fail "no worktree must exit 2 (n/a), not 0/3"
ok "no worktree → exit 2 (n/a)"
[ "$(run_deliver lost)" = 2 ] || fail "re-run after the manual re-merge must exit 2 (n/a — nothing left ahead of main)"
ok "already-delivered worktree → exit 2 (n/a)"
[ -f "$TMP/wt/lost/.agentos-undelivered" ] && fail "sentinel survived a successful re-delivery — worker would stay locked out forever"
ok "sentinel removed once the work landed (gate does not lock a worktree permanently)"

# a fresh FAILED delivery, to feed the comment guard below
cat > "$TMP/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/bash
while read -r _ _ ref; do
  [ "$ref" = "refs/heads/main" ] && { echo "remote: simulated rejection of $ref" >&2; exit 1; }
done
exit 0
EOF
chmod +x "$TMP/origin.git/hooks/pre-receive"
new_worker doomed
[ "$(run_deliver doomed)" = 3 ] || fail "rejected push must exit 3 (FAILED) — a zero exit is the silent-loss bug"
ok "rejected push → exit 3 (FAILED), sentinel written"

# === (7) comment guard: `outcome: done` is UNPUBLISHABLE ====================
# This is the step where the real bypass happened — the agent reached the task backend and
# posted a green done. The guard lives in the transport, so it cannot be argued past. It is
# backend-agnostic (scripts/lib/delivery-guard.sh) and wired into both the generic
# task-queue adapter and the ClickUp reference CLI.
echo "[7] comment-transport delivery guard"
guard_says() { # $1 = worktree, $2 = comment text → prints "ALLOW"/"REFUSE: ..."
  ( set +e
    export AGENTOS_WORKER_WORKTREE="$1"
    out="$(bash -c '. "$0"; delivery_guard_check "$1"' "$GUARD_SH" "$2" 2>&1)"
    if [ $? -eq 0 ]; then echo "ALLOW"; else echo "REFUSE: $out"; fi )
}
[ -f "$TMP/wt/doomed/.agentos-undelivered" ] || fail "precondition: doomed worktree has no sentinel"

R="$(guard_says "$TMP/wt/doomed" 'All finished.
outcome: done | score: 5/5 | note: smooth')"
case "$R" in REFUSE*) ok "green 'outcome: done' on an undelivered worktree → REFUSED";;
  *) fail "guard ALLOWED 'outcome: done' while commits are orphaned — the exact bypass";; esac
printf '%s\n' "$R" | grep -q 'agentos-undelivered' || fail "refusal does not point at the sentinel"

R="$(guard_says "$TMP/wt/doomed" 'outcome: blocked | score: 2/5 | note: merge failed')"
[ "$R" = ALLOW ] || fail "guard blocked the /blocked path too — worker would have NO way to finalize: $R"
ok "'outcome: blocked' still publishable (the /blocked escape hatch stays open)"

R="$(guard_says "$TMP/wt/happy" 'outcome: done | score: 5/5 | note: fine')"
[ "$R" = ALLOW ] || fail "guard refused a legitimately delivered worker: $R"
ok "'outcome: done' on a delivered worktree → ALLOWED (no false positives)"

grep -q 'delivery_guard_check' "$TASK_QUEUE_SH" || fail "task-queue.sh does not call delivery_guard_check"
grep -q 'delivery-guard.sh'    "$TASK_QUEUE_SH" || fail "task-queue.sh does not source the shared guard"
grep -q 'delivery_guard_check "\$text"' "$CLICKUP_SH" || fail "clickup.sh cmd_comment does not call delivery_guard_check"
ok "guard is wired into the generic task-queue adapter and the ClickUp CLI"

echo
echo "ALL CHECKS PASSED"
