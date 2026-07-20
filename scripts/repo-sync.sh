#!/bin/bash
# repo-sync.sh — keep the instance's checkout in sync with origin/main.
#
# This is the DEPLOY PLANE of an always-on instance: every fix you push from
# another machine (a dev laptop, a worker's branch merged to main) reaches the
# running fleet ONLY through this script. When it wedges, nothing deploys — and
# because a wedge is silent, the usual symptom is "the repo just stopped
# updating and nobody knows why".
#
# Three failure modes are handled explicitly below:
#   1. tracked dirty state          -> `--autostash`
#   2. untracked collision          -> quarantine the colliding paths, retry
#   3. swallowed conflict / wedge   -> staleness guard, exit non-zero
#
# Env:
#   REPO_ROOT                 repo root (default: parent dir of this script)
#   REPO_SYNC_QUARANTINE      quarantine base dir
#                             (default: /var/lib/agent-os/repo-sync-quarantine)
#
# Pair it with a routine on a short schedule (see routines/repo-sync.yaml).

set -uo pipefail

REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" || exit 0

# --autostash handles any uncommitted churn from concurrent DAGs.
git pull --rebase --autostash origin main >/dev/null 2>&1 || true

# --- Untracked-collision self-heal -------------------------------------------
# --autostash stashes TRACKED modifications only. If an agent wrote an artifact
# into the LIVE tree (leaving it untracked) and then committed the SAME path
# from its own worktree, the pull aborts with "untracked working tree files
# would be overwritten by checkout" — permanently, on every run, until a human
# intervenes. One such collision is enough to freeze the whole deploy plane for
# as long as it takes somebody to notice.
#
# Fix: compute the collision set deterministically (incoming paths ∩ untracked),
# MOVE those files to a timestamped quarantine dir (never delete — the agent's
# artifact survives and is recoverable), then retry the pull. Unrelated
# untracked files and tracked dirty state are left untouched. With no collision
# this block is a no-op.
git fetch origin main --quiet 2>/dev/null || true
if [ "$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)" -gt 0 ] \
   && [ ! -d "$REPO/.git/rebase-merge" ] && [ ! -d "$REPO/.git/rebase-apply" ]; then
  mapfile -t collisions < <(comm -12 \
    <(git diff --name-only HEAD origin/main 2>/dev/null | sort) \
    <(git ls-files --others --exclude-standard 2>/dev/null | sort))
  if [ "${#collisions[@]}" -gt 0 ]; then
    qdir="${REPO_SYNC_QUARANTINE:-/var/lib/agent-os/repo-sync-quarantine}/$(date -u +%Y%m%dT%H%M%SZ)"
    for f in "${collisions[@]}"; do
      mkdir -p "$qdir/$(dirname "$f")" 2>/dev/null || continue
      mv "$f" "$qdir/$f" 2>/dev/null \
        && echo "repo-sync: quarantined untracked collision $f -> $qdir/$f" >&2
    done
    git pull --rebase --autostash origin main >/dev/null 2>&1 || true
  fi
fi

# Push local commits that agents couldn't push (headless = no permission prompt).
if [ "$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)" -gt 0 ]; then
  git push origin main >/dev/null 2>&1 || true
fi

# --- Staleness guard ----------------------------------------------------------
# The pull above is `... || true` + `>/dev/null` — a rebase CONFLICT is swallowed
# and the DAG still reports "Succeeded" while the checkout freezes at a stale
# commit. When that happens EVERY fix pushed upstream silently fails to deploy,
# and the fleet keeps running old code while the dashboard stays green. This
# block is purely additive & read-only (no network write, no mutation) — it
# refreshes the remote ref, measures drift, drops a manifest, and — critically —
# exits non-zero when wedged so supervision turns the run RED instead of
# green-lying.
git fetch origin main --quiet 2>/dev/null || true
behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
rebase_wedged=0
if [ -d "$REPO/.git/rebase-merge" ] || [ -d "$REPO/.git/rebase-apply" ]; then
  rebase_wedged=1
fi
head_sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
origin_sha="$(git rev-parse --short origin/main 2>/dev/null || echo unknown)"
stale=0
reason="in-sync"
if [ "$rebase_wedged" -eq 1 ]; then
  stale=1; reason="rebase-wedged (.git/rebase-* present; needs manual abort/resolve)"
elif [ "${behind:-0}" -gt 0 ]; then
  stale=1; reason="behind origin/main by ${behind} commit(s) after pull attempt (conflict swallowed by || true)"
fi

manifest="/var/lib/agent-os/repo-sync-stale.json"
printf '{"stale":%s,"reason":"%s","behind":%s,"rebase_wedged":%s,"head":"%s","origin_head":"%s","repo":"%s"}\n' \
  "$([ "$stale" -eq 1 ] && echo true || echo false)" \
  "$reason" "${behind:-0}" "$rebase_wedged" "$head_sha" "$origin_sha" "$REPO" \
  > "$manifest" 2>/dev/null || true

if [ "$stale" -eq 1 ]; then
  echo "repo-sync STALE: $reason (HEAD=$head_sha origin/main=$origin_sha) — this checkout is NOT deploying upstream fixes" >&2
  exit 1
fi

exit 0
