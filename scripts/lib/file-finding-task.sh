#!/bin/bash
# file-finding-task.sh — a monitor files ONE deduplicated task per finding.
#
# This is the core primitive of the self-healing loop: monitoring routines
# (system reviews, divergence checks, liveness probes, ...) do NOT just report
# to the operator — for every concrete problem they find they FILE a task that
# the worker launcher picks up, routes to the right folder, fixes, and closes
# (or parks for a human). This wrapper makes that one call, with the dedup +
# routing guardrails baked in, so a monitor prompt stays trivial and
# deterministic.
#
# DEDUP (the #1 guardrail — without it every run spams the queue): identity is a
# composite tag `upsert:<monitor>:<signature>` handled by scripts/lib/clickup_upsert.py.
# Same (monitor, signature) -> the SAME task forever: found again -> body
# refreshed in place (and reopened if it had been closed and the problem
# recurs), NOT a duplicate. The signature is YOUR stable problem-id — derive it
# from the problem itself (e.g. "worker-crashloop", "push-up:md2phone-skill"),
# never from a timestamp/run-id, or dedup breaks and you get one task per tick.
#
# ROUTING (task -> right folder): pass --cwd <abs path>. The launched worker is
# started with that as its launch cwd (WORKER_WORK_DIR in worker-launcher-tick.sh),
# so project-scoped slash commands / CLAUDE.md load correctly. The cwd is ALSO
# written into the task body as a human-visible "Working dir (cwd): <path>" line
# — that exact spelling is what worker-launcher-tick.sh greps for, so keep the
# two in sync if you ever reword it.
#
# DEPENDENCIES (task -> right host): pass --requires-cmd <bin> and/or
# --requires-dep <name> (both repeatable). They are written into the body as
# "Requires (host cmd): ..." / "Requires (dep): ..." lines, which
# worker-launcher-tick.sh parses: a host missing the binary, or a dep that
# scripts/lib/dep-reachable.sh reports unreachable, SKIPS the task this tick
# (with a reason on stderr) instead of picking it up and failing. One shared
# queue therefore self-routes across heterogeneous hosts — e.g. a task needing
# `tdl` is only ever picked up by a host that has it — with no launcher change
# per new dependency. Same spelling caveat as the cwd line above.
#
# PRIORITY = blast radius (the auto-fix vs queue-for-bump gate):
#   2 (high)  -> safe, reversible, repo-internal fix. The launcher auto-picks it
#                (tasks need priority 1-2 AND tag auto-worker) -> the loop fixes
#                it with no human in the path.
#   3 (normal -> DEFAULT) -> has external blast radius (upstream PR, pulling
#                code, touching another project's prod) OR just not urgent. Sits
#                in the queue tagged auto-worker; a human or a follow-up task
#                bumps it to 2 when ready. A lightweight "needs a look first".
#   1 (urgent) -> reserve for active breakage.
# A monitor that is unsure picks 3. Spam-of-fixes is worse than a one-day delay.
#
# Usage:
#   file-finding-task.sh --monitor <id> --key <signature> \
#       --title "..." --desc "..." \
#       [--priority 2|3] [--cwd /abs/path] [--list <list_id>] [--tag extra]... \
#       [--requires-cmd <bin>]... [--requires-dep <name>]...
#
# Config (env, same convention as clickup_upsert.py):
#   REPO_ROOT        repo checkout (default: parent dir of this script's dir)
#   CLICKUP_LIST_ID  destination list when --list is not passed
#
# Emits one line to stdout: "<created|updated> <task_id> <https url>".
# Idempotent: safe to call every run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
UPSERT="$REPO/scripts/lib/clickup_upsert.py"
NEEDS_HUMAN="$REPO/scripts/lib/needs_human.py"

MONITOR="" KEY="" TITLE="" DESC="" PRIO=3 CWD="" LIST="${CLICKUP_LIST_ID:-}"
EXTRA_TAGS=()
REQ_CMDS=() REQ_DEPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --monitor)  MONITOR="$2"; shift 2 ;;
    --key)      KEY="$2"; shift 2 ;;
    --title)    TITLE="$2"; shift 2 ;;
    --desc)     DESC="$2"; shift 2 ;;
    --priority) PRIO="$2"; shift 2 ;;
    --cwd)      CWD="$2"; shift 2 ;;
    --list)     LIST="$2"; shift 2 ;;
    --tag)      EXTRA_TAGS+=("$2"); shift 2 ;;
    --requires-cmd) REQ_CMDS+=("$2"); shift 2 ;;
    --requires-dep) REQ_DEPS+=("$2"); shift 2 ;;
    *) echo "file-finding-task: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
: "${MONITOR:?--monitor required}"
: "${KEY:?--key (stable signature) required}"
: "${TITLE:?--title required}"
: "${LIST:?--list required (or set CLICKUP_LIST_ID)}"

# Append routing cwd into the body (human-visible fallback to the env path).
# Exact wording is load-bearing: worker-launcher-tick.sh regexes for it.
if [ -n "$CWD" ]; then
  DESC="${DESC}

Working dir (cwd): ${CWD}"
fi
# Declare host/dep requirements into the body. Exact wording is load-bearing:
# worker-launcher-tick.sh regexes for it (parse_task_deps).
_join() { local out=""; local x; for x in "$@"; do out="${out:+$out, }$x"; done; echo "$out"; }
if [ "${#REQ_CMDS[@]}" -gt 0 ]; then
  DESC="${DESC}

Requires (host cmd): $(_join "${REQ_CMDS[@]}")"
fi
if [ "${#REQ_DEPS[@]}" -gt 0 ]; then
  DESC="${DESC}

Requires (dep): $(_join "${REQ_DEPS[@]}")"
fi
# Provenance footer so a human sees this came from a monitor, with the dedup key.
DESC="${DESC}

---
_Filed by monitor \`${MONITOR}\` (self-healing loop). Dedup signature: \`${KEY}\`. If the problem recurs this same task is updated — no duplicate is created._"

# Always carry the loop tag; callers may add more (project slug, kind, etc).
TAG_ARGS=(--tag auto-worker)
for t in "${EXTRA_TAGS[@]:-}"; do
  [ -n "$t" ] && TAG_ARGS+=(--tag "$t")
done

# HUMAN SAFETY-GATE: if this finding falls in a risk class (`operator-lifeline`,
# `reminder`, or already-`tagged`), stamp `needs-human` so the launcher skips it —
# the operator surfaces it and it runs on an explicit go. Single classifier in
# scripts/lib/needs_human.py, shared with the launcher-side gate. Optional: if
# the classifier is absent the task is filed ungated.
if [ -f "$NEEDS_HUMAN" ]; then
  RISK_CLASS=$(python3 "$NEEDS_HUMAN" \
    --name "$TITLE" --desc "$DESC" \
    --tags "$(printf '%s ' "${EXTRA_TAGS[@]:-}")" --mode classify 2>/dev/null || true)
  if [ -n "$RISK_CLASS" ]; then
    case " ${TAG_ARGS[*]} " in
      *" needs-human "*) : ;;            # already present
      *) TAG_ARGS+=(--tag needs-human) ;;
    esac
    echo "needs-human: stamped (risk class: ${RISK_CLASS})" >&2
  fi
fi

TID=$(python3 "$UPSERT" find --gen "$MONITOR" --key "$KEY" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["id"])
except Exception: pass' || true)
ACTION="updated"
[ -z "$TID" ] && ACTION="created"

NEWID=$(python3 "$UPSERT" upsert \
  --list-id "$LIST" --gen "$MONITOR" --key "$KEY" \
  --title "$TITLE" --desc "$DESC" --priority "$PRIO" \
  "${TAG_ARGS[@]}")

echo "${ACTION} ${NEWID} https://app.clickup.com/t/${NEWID}"
