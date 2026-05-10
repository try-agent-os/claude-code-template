#!/usr/bin/env bash
# sync-workspace-submodule.sh <slug>
#
# Generic sync for a workspace AgentOS submodule (category A):
#   workspaces/<slug>/claude/
#
# What it does:
#   1. If the submodule has uncommitted changes — commit + push them.
#   2. If the submodule pointer in the hub has changed — bump + commit + push the hub.
#
# Idempotent. Does nothing if there's nothing to sync.
# Non-blocking — exits 0 even on push failure (failures are logged so the
# heartbeat loop can keep going). The next cycle will retry.

set -uo pipefail

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "usage: $0 <workspace-slug>" >&2
  exit 1
fi

HUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_PATH="workspaces/${SLUG}/claude"
SUBMODULE_FULL="${HUB_ROOT}/${SUBMODULE_PATH}"

if [[ ! -d "$SUBMODULE_FULL" ]]; then
  echo "ERROR: submodule path not found: $SUBMODULE_FULL" >&2
  exit 1
fi

if [[ ! -d "${SUBMODULE_FULL}/.git" ]] && [[ ! -f "${SUBMODULE_FULL}/.git" ]]; then
  echo "ERROR: not a git submodule: $SUBMODULE_FULL" >&2
  exit 1
fi

LOG_FILE="${HUB_ROOT}/memory/worker-activity.log"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
  echo "${TIMESTAMP} | sync-workspace-submodule | ${SLUG} | $*" >> "$LOG_FILE"
}

push_with_retry() {
  local repo_dir="$1"
  local label="$2"
  local attempt=0
  local max_attempts=3
  local delay=2

  while (( attempt < max_attempts )); do
    if git -C "$repo_dir" push origin main 2>&1; then
      return 0
    fi
    attempt=$(( attempt + 1 ))
    if (( attempt < max_attempts )); then
      echo "push attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep "$delay"
      delay=$(( delay * 2 ))
      git -C "$repo_dir" pull --rebase origin main 2>&1 || true
    fi
  done
  return 1
}

# === Submodule side: commit + push uncommitted changes ===
cd "$SUBMODULE_FULL"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "[sync] uncommitted changes in submodule ${SLUG}, committing..."
  git add -A
  if git commit -m "auto-sync from hub workers ($(date -Iseconds))"; then
    log "submodule commit created"
    if push_with_retry "$SUBMODULE_FULL" "submodule"; then
      log "submodule push OK"
    else
      log "ERROR submodule push failed after retries"
      echo "ERROR: submodule push failed" >&2
      cd "$HUB_ROOT"
      exit 0
    fi
  else
    log "submodule commit failed (probably no changes after add)"
  fi
else
  echo "[sync] submodule ${SLUG} clean, no commit needed"
fi

# === Hub side: bump pointer + push if changed ===
cd "$HUB_ROOT"
if ! git diff --quiet "$SUBMODULE_PATH" 2>/dev/null || ! git diff --cached --quiet "$SUBMODULE_PATH" 2>/dev/null; then
  echo "[sync] submodule pointer changed, bumping in hub..."
  git add "$SUBMODULE_PATH"
  if git commit -m "submodule bump: ${SLUG} auto-sync"; then
    log "hub pointer bumped"
    git pull --rebase origin main 2>&1 || {
      log "ERROR hub pull --rebase failed"
      echo "ERROR: hub pull --rebase failed" >&2
      exit 0
    }
    if push_with_retry "$HUB_ROOT" "hub"; then
      log "hub push OK"
    else
      log "ERROR hub push failed after retries"
      echo "ERROR: hub push failed" >&2
      exit 0
    fi
  else
    log "hub commit failed (no changes after add)"
  fi
else
  echo "[sync] submodule pointer unchanged, no hub bump needed"
fi

log "done"
exit 0
