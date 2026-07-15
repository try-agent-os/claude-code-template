#!/bin/bash
# check-fire.sh — turn a cron tick into ONE canonical task in the queue.
#
# The scheduling layer (Dagu, routines/*.yaml) decides WHEN; this script decides
# WHAT lands in the queue. Each per-check routine owns its own cron line and
# calls this with an id, a priority and a description; a worker later picks the
# task up off the queue and does the actual work.
#
# Why not have the routine create the task directly? Because a check that fires
# daily must not create a task daily. Firing is idempotent per check id via
# scripts/lib/clickup_upsert.py (identity `upsert:check-fire:<id>`): the same id
# always maps to the same task, so a check nobody has answered yet is refreshed
# and re-queued rather than duplicated. See that file for the identity-tag
# rationale.
#
# Usage: check-fire.sh [FLAGS] <check-id> <priority> "<description>"
#   <check-id>   stable slug, e.g. morning-brief. Identity key — never reuse.
#   <priority>   low|medium|high|critical (mapped to ClickUp's 4..1)
#   <description> task body; this is the prompt the worker will act on.
#
# Flags:
#   --list <id>
#       Destination list. Defaults to $CLICKUP_SCHEDULED_LIST_ID.
#
#   --require-dep <dep>
#       Skip firing if scripts/lib/dep-reachable.sh <dep> returns non-zero.
#       Use for a check whose SOLE purpose is that dependency: firing a worker
#       at a known-dead dependency just burns a token budget to reach the same
#       conclusion. The gate auto-reopens when the dep recovers — nothing to
#       reset by hand. Repeatable (all must pass).
#       Do NOT gate a check that merely uses the dep as one degradable input.
#
# Config (nothing is hardcoded — see .env.example):
#   CLICKUP_SCHEDULED_LIST_ID   destination list for scheduled tasks
#   CLICKUP_TEAM_ID             team id (used by the upsert's identity search)
#   CLICKUP_API_TOKEN | CLICKUP_PERSONAL_TOKEN
#   CHECK_FIRE_TAGS             comma-separated extra tags to put on every fired
#                               task. Default "scheduled,source:check-fire".
#                               Set to your worker-routing tag if your queue
#                               requires one (e.g. "scheduled,auto-worker").
#
# Exit: 0 fired or deliberately skipped by a gate; 1 misconfigured / upsert failed.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"

LIST_ID="${CLICKUP_SCHEDULED_LIST_ID:-}"
REQ_DEPS=()

while true; do
  case "${1:-}" in
    --list)        LIST_ID="${2:?--list needs a value}"; shift 2 ;;
    --require-dep) REQ_DEPS+=("${2:?--require-dep needs a value}"); shift 2 ;;
    --help|-h)     sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) break ;;
  esac
done

ID="${1:-}"
PRIO="${2:-low}"
DESC="${3:-}"

if [ -z "$ID" ]; then
  echo "check-fire: usage: check-fire.sh [--list <id>] [--require-dep <dep>] <check-id> <priority> \"<description>\"" >&2
  exit 1
fi

if [ -z "$LIST_ID" ]; then
  # Loud, not silent: a check that cannot reach the queue is doing nothing at
  # all, and a scheduled no-op is invisible until someone wonders why the check
  # never fires. Fail so the run goes red in the scheduler UI.
  echo "check-fire: refusing to fire '$ID' — no destination list. Set CLICKUP_SCHEDULED_LIST_ID in the environment (see .env.example) or pass --list <id>." >&2
  exit 1
fi

# Dependency gates run BEFORE the upsert: a skip must leave the queue untouched.
for _dep in "${REQ_DEPS[@]+"${REQ_DEPS[@]}"}"; do
  if ! "$REPO/scripts/lib/dep-reachable.sh" "$_dep" 2>/dev/null; then
    echo "check-fire: skip '$ID' — dep '$_dep' unreachable. Gate auto-reopens when it recovers." >&2
    exit 0
  fi
done

case "$PRIO" in
  critical) CU_PRIO=1 ;;
  high)     CU_PRIO=2 ;;
  medium)   CU_PRIO=3 ;;
  low)      CU_PRIO=4 ;;
  *)
    echo "check-fire: unknown priority '$PRIO' for '$ID' — falling back to low. Use low|medium|high|critical." >&2
    CU_PRIO=4
    ;;
esac

# Tags are configurable because queue routing is per-install: a worker layer that
# only picks up tagged tasks needs its tag here, and a queue without such a
# convention wants none of it.
TAG_ARGS=()
IFS=',' read -r -a _tags <<< "${CHECK_FIRE_TAGS:-scheduled,source:check-fire}"
for _tag in "${_tags[@]}"; do
  _tag="$(printf '%s' "$_tag" | tr -d '[:space:]')"
  [ -n "$_tag" ] && TAG_ARGS+=(--tag "$_tag")
done

exec python3 "$REPO/scripts/lib/clickup_upsert.py" upsert \
  --list-id "$LIST_ID" --gen check-fire --key "$ID" \
  --title "${CHECK_FIRE_TITLE_PREFIX:-Scheduled: }${ID}" \
  --desc "$DESC" --priority "$CU_PRIO" \
  "${TAG_ARGS[@]+"${TAG_ARGS[@]}"}"
