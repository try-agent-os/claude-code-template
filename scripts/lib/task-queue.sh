#!/usr/bin/env bash
# task-queue.sh — generic task-backend adapter for the worker orchestration layer.
#
# The worker lifecycle scripts (launcher, collector, janitor, watchdog) need only
# four operations against whatever system holds the task queue. This file is the
# single seam between those scripts and the backend, so swapping ClickUp for
# Linear/Jira/GitHub Issues/a JSON file means implementing one adapter here
# instead of editing every lifecycle script.
#
# Interface — every adapter MUST provide these four functions:
#
#   tq_get_status   <task_id>              -> prints current status slug, "" on failure
#   tq_set_status   <task_id> <status>     -> exit 0 on success
#   tq_comment      <task_id> <text>       -> exit 0 on success
#   tq_get_comments <task_id>              -> prints comment bodies, newest first,
#                                             one JSON string per line ("" on failure)
#
# Status slugs are backend-agnostic and normalized by the adapter:
#   todo | in_progress | in_review | blocked | on_hold | done
#
# Derived helpers — built on the four primitives, so every adapter (including a
# custom one) gets them for free without implementing anything extra:
#
#   tq_fetch_status        <task_id>  -> normalized slug (lowercase, spaces→_), ""
#   tq_fetch_comments_json <task_id>  -> JSON array of comment bodies, oldest
#                                        first, "[]" on failure
#
# Selecting a backend:
#   AGENTOS_TASK_BACKEND=clickup   (default — reference implementation, below)
#   AGENTOS_TASK_BACKEND=custom    -> sources $AGENTOS_TASK_BACKEND_SCRIPT, which
#                                     must define the four tq_* functions above.
#
# Usage:
#   source "$REPO/scripts/lib/task-queue.sh"
#   tq_set_status "$task_id" in_review

set -o pipefail

TQ_REPO="${TQ_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
AGENTOS_TASK_BACKEND="${AGENTOS_TASK_BACKEND:-clickup}"

# Delivery gate — applies to EVERY backend, which is why it lives here and not in an
# adapter: a worker whose commits never reached origin/main must not be able to publish
# `outcome: done` through any transport. See scripts/lib/delivery-guard.sh.
# shellcheck source=./delivery-guard.sh
if [ -r "${TQ_REPO}/scripts/lib/delivery-guard.sh" ]; then
  . "${TQ_REPO}/scripts/lib/delivery-guard.sh"
else
  delivery_guard_check() { :; }
fi

# ---------------------------------------------------------------------------
# Reference adapter: ClickUp (API v2)
# ---------------------------------------------------------------------------
# Kept deliberately thin — it shells out to scripts/clickup/clickup.sh for the
# write path (which owns token resolution, markdown conversion and retries) and
# uses curl only where the CLI has no subcommand.

_tq_clickup_token() {
  # Prefer the agent identity, fall back to the personal token. Both are read
  # from the environment; never echo the value itself.
  echo "${CLICKUP_AGENT_TOKEN:-${CLICKUP_PERSONAL_TOKEN:-}}"
}

_tq_clickup_cli() { echo "${TQ_REPO}/scripts/clickup/clickup.sh"; }

tq_clickup_get_status() {
  local task_id="$1"
  "$(_tq_clickup_cli)" get --task "$task_id" 2>/dev/null \
    | jq -r '.status.status // ""' 2>/dev/null || echo ""
}

tq_clickup_set_status() {
  local task_id="$1" status="$2"
  "$(_tq_clickup_cli)" update --task "$task_id" --status "$status" >/dev/null 2>&1
}

tq_clickup_comment() {
  local task_id="$1" text="$2"
  "$(_tq_clickup_cli)" comment --task "$task_id" --text "$text" >/dev/null 2>&1
}

tq_clickup_get_comments() {
  local task_id="$1" token
  token="$(_tq_clickup_token)"
  [ -z "$token" ] && { echo ""; return 1; }
  # `-c`, not `-r`: the documented contract is one JSON *string* per line. A raw
  # dump splits a multi-line comment body across lines, and every consumer that
  # reads this line-by-line then sees one comment as several.
  curl -sS -H "Authorization: ${token}" \
    "https://api.clickup.com/api/v2/task/${task_id}/comment" 2>/dev/null \
    | jq -c '[.comments[]? | .comment_text] | reverse | .[]' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$AGENTOS_TASK_BACKEND" in
  clickup)
    tq_get_status()   { tq_clickup_get_status "$@"; }
    tq_set_status()   { tq_clickup_set_status "$@"; }
    tq_comment()      { delivery_guard_check "${2:-}" || return 1; tq_clickup_comment "$@"; }
    tq_get_comments() { tq_clickup_get_comments "$@"; }
    ;;
  custom)
    if [ -z "${AGENTOS_TASK_BACKEND_SCRIPT:-}" ] || [ ! -r "${AGENTOS_TASK_BACKEND_SCRIPT}" ]; then
      echo "[task-queue] AGENTOS_TASK_BACKEND=custom but AGENTOS_TASK_BACKEND_SCRIPT is unset/unreadable" >&2
      return 1 2>/dev/null || exit 1
    fi
    # shellcheck disable=SC1090
    source "${AGENTOS_TASK_BACKEND_SCRIPT}"
    for _fn in tq_get_status tq_set_status tq_comment tq_get_comments; do
      if ! declare -F "$_fn" >/dev/null; then
        echo "[task-queue] custom backend does not define ${_fn}()" >&2
        return 1 2>/dev/null || exit 1
      fi
    done
    unset _fn
    # Wrap the custom adapter's comment path in the delivery gate as well — a backend
    # swap must not silently drop the `outcome: done` protection.
    eval "$(declare -f tq_comment | sed '1s/^tq_comment/_tq_custom_comment/')"
    tq_comment() { delivery_guard_check "${2:-}" || return 1; _tq_custom_comment "$@"; }
    ;;
  *)
    echo "[task-queue] unknown AGENTOS_TASK_BACKEND='${AGENTOS_TASK_BACKEND}' (expected: clickup|custom)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Derived read helpers (backend-agnostic — defined once, after dispatch)
# ---------------------------------------------------------------------------
# The supervisor family needs two shapes on top of the raw primitives: a
# normalized status slug and the comment history as a single JSON array. Every
# per-instance supervisor used to carry its own curl+parse copy of both, so a
# fix (curl timeout, a status-schema change, an auth-header change) landed in
# one copy and silently stayed broken in the rest. Defined here, they follow
# whatever backend is selected above.
#
# Neither helper ever fails: a supervisor tick must degrade to "I know nothing
# about this task" rather than die halfway through its session loop.

# tq_fetch_status <task_id> -> lowercase slug, spaces→underscores, "" on failure.
tq_fetch_status() {
  local task_id="${1:-}"
  [ -z "$task_id" ] && { echo ""; return 0; }
  tq_get_status "$task_id" 2>/dev/null \
    | head -n 1 | tr '[:upper:]' '[:lower:]' | tr ' ' '_' || echo ""
}

# tq_fetch_comments_json <task_id> -> JSON array of comment bodies, OLDEST first
# (tq_get_comments yields newest first), "[]" on failure or no comments.
tq_fetch_comments_json() {
  local task_id="${1:-}" out
  [ -z "$task_id" ] && { echo "[]"; return 0; }
  out="$(tq_get_comments "$task_id" 2>/dev/null | jq -sc 'reverse' 2>/dev/null)"
  [ -z "$out" ] && out="[]"
  echo "$out"
}
