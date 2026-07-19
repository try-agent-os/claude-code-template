#!/usr/bin/env bash
# worker-analytics.sh — AgentOS worker health dashboard / status aggregator
#
# Aggregates the local worker artifact tree (logs/workers/<slug>/) into a fast
# health summary: inventory, liveness (heartbeat freshness), model split,
# recency, and task-type breakdown (outreach/research/scan/infra/other).
#
# The authoritative done/blocked status lives in ClickUp, not on disk (workers
# have no local result.md — only clickup-task-id/model/started-at/heartbeat).
# So --blocked / --partial cross-reference the local task-ids against a single
# ClickUp dashboard call (best-effort, open tasks in the configured scope,
# capped at 100).
#
# Usage:
#   scripts/worker-analytics.sh                 # local health summary (<1s, offline)
#   scripts/worker-analytics.sh --last-N-days 7 # only workers started in last N days
#   scripts/worker-analytics.sh --clickup       # + ClickUp status distribution
#   scripts/worker-analytics.sh --blocked       # list workers whose task is blocked in ClickUp
#   scripts/worker-analytics.sh --partial       # list workers whose task is on_hold (awaiting)
#
# Environment:
#   WORKER_LOGS_DIR=/path       override the worker artifact dir
#   WORKER_LIVE_THRESHOLD=180   seconds of heartbeat freshness that count as "live"
#   WORKER_TYPE_<TYPE>_EXTRA    extra shell globs for the task-type classifier,
#                               '|'-separated, e.g.
#                                 WORKER_TYPE_INFRA_EXTRA='*billing*|*myproject*'
#                               <TYPE> is one of OUTREACH RESEARCH SCAN INFRA.
#                               Use this to teach the classifier your own project
#                               and workspace names without editing this file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- resolve worker artifact dir: env override > repo-relative ---
WORKERS_DIR="${WORKER_LOGS_DIR:-$SCRIPT_DIR/../logs/workers}"

# --- flags ---
FILTER=""            # blocked | partial
LAST_N_DAYS=""
USE_CLICKUP=0
LIVE_THRESHOLD="${WORKER_LIVE_THRESHOLD:-180}"   # seconds: fresher heartbeat => live

while [[ $# -gt 0 ]]; do
  case "$1" in
    --blocked)      FILTER="blocked"; USE_CLICKUP=1; shift ;;
    --partial)      FILTER="partial"; USE_CLICKUP=1; shift ;;
    --clickup)      USE_CLICKUP=1; shift ;;
    --last-N-days|--last-n-days|--days)
                    # NB: `shift 2` with only one arg left fails without shifting
                    # (no `set -e`), so the loop would spin forever on a trailing
                    # `--days` with no value. Require the value explicitly.
                    if [[ $# -lt 2 ]]; then
                      echo "worker-analytics: $1 requires a value (number of days)" >&2; exit 2
                    fi
                    LAST_N_DAYS="$2"; shift 2 ;;
    --last-N-days=*|--last-n-days=*|--days=*)
                    LAST_N_DAYS="${1#*=}"; shift ;;
    -h|--help)
      grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "worker-analytics: unknown flag '$1' (see --help)" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$WORKERS_DIR" ]]; then
  echo "worker-analytics: worker dir not found: $WORKERS_DIR" >&2
  echo "  (set WORKER_LOGS_DIR=/path/to/logs/workers to point elsewhere)" >&2
  exit 1
fi

NOW=$(date +%s)
CUTOFF=0
if [[ -n "$LAST_N_DAYS" ]]; then
  if ! [[ "$LAST_N_DAYS" =~ ^[0-9]+$ ]]; then
    echo "worker-analytics: --last-N-days needs an integer, got '$LAST_N_DAYS'" >&2; exit 2
  fi
  CUTOFF=$(( NOW - LAST_N_DAYS * 86400 ))
fi

# --- task-type classifier: slug + optional name -> outreach|research|scan|infra|other ---
# Generic keyword sets only. Instance-specific vocabulary (your own workspace,
# client, or vendor names) belongs in WORKER_TYPE_<TYPE>_EXTRA, not in this file.
TYPE_OUTREACH='*outreach*|*sdr*|*cold-email*|*lead*|*prospect*|*sequence*|*sales*|*campaign*|*crm*'
TYPE_RESEARCH='*research*|*spike*|*investigat*|*eval*|*explore*|*benchmark*|*prototype*'
TYPE_SCAN='*scan*|*health*|*audit*|*monitor*|*watchdog*|*dashboard*|*analy*|*check*|*verify*|*supervis*|*report*'
TYPE_INFRA='*infra*|*fix*|*dagu*|*systemd*|*tmux*|*mcp*|*hook*|*deploy*|*migrat*|*cutover*|*harden*|*route*|*router*|*worker*|*pipeline*|*oauth*|*install*|*provision*|*dispatch*|*receiver*|*docs*|*git-*|*ci-*|*build*|*schema*|*backup*|*upgrade*|*refactor*|*heartbeat*|*spawn*'

# per-instance extension: WORKER_TYPE_INFRA_EXTRA='*acme*|*billing*'
append_extra() {
  local var="TYPE_$1" extra_var="WORKER_TYPE_$1_EXTRA" extra
  extra="${!extra_var:-}"
  [[ -n "$extra" ]] && printf -v "$var" '%s|%s' "${!var}" "$extra"
  return 0
}
for t in OUTREACH RESEARCH SCAN INFRA; do append_extra "$t"; done

# NB: a `case` pattern coming from a variable is one literal string — bash only
# splits '|' alternatives at parse time — so match each glob explicitly here.
# `set -f` is essential: splitting $2 on '|' leaves each glob subject to pathname
# expansion, so a file named e.g. "research-notes" in cwd would silently replace
# the '*research*' pattern and break classification.
match_any() {   # $1 = haystack, $2 = '|'-separated globs
  local s="$1" p rc=1
  local IFS='|'
  set -f
  for p in $2; do
    if [[ -n "$p" && "$s" == $p ]]; then rc=0; break; fi
  done
  set +f
  return $rc
}

classify() {
  local s; s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  match_any "$s" "$TYPE_OUTREACH" && { echo outreach; return; }
  match_any "$s" "$TYPE_RESEARCH" && { echo research; return; }
  match_any "$s" "$TYPE_SCAN"     && { echo scan;     return; }
  match_any "$s" "$TYPE_INFRA"    && { echo infra;    return; }
  echo other
}

# --- single pass over worker dirs ---
declare -A TYPE_COUNT MODEL_COUNT
declare -A TYPE_EX          # type -> newline-joined "started_at\tslug"
total=0; live=0; finished=0; recent=0
declare -a TASKIDS SLUGS

for dir in "$WORKERS_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  slug=$(basename "$dir")
  [[ "$slug" == "strategist" ]] && continue   # engine dir, not a task worker

  started=0
  [[ -r "$dir/started-at" ]] && started=$(tr -dc '0-9' < "$dir/started-at")
  [[ -z "$started" ]] && started=0

  # --last-N-days filter
  if [[ $CUTOFF -gt 0 && $started -lt $CUTOFF ]]; then
    continue
  fi

  ((total++))

  # liveness via heartbeat mtime
  if [[ -f "$dir/heartbeat" ]]; then
    hb=$(stat -c %Y "$dir/heartbeat" 2>/dev/null || echo 0)
    if [[ $(( NOW - hb )) -le $LIVE_THRESHOLD ]]; then
      ((live++))
    else
      ((finished++))
    fi
  else
    ((finished++))
  fi

  [[ $started -gt $(( NOW - 7*86400 )) ]] && ((recent++))

  # model split
  model="unknown"
  if [[ -r "$dir/model" ]]; then
    m=$(tr -d '\r\n' < "$dir/model")
    case "$m" in
      *opus*)   model="opus" ;;
      *sonnet*) model="sonnet" ;;
      *haiku*)  model="haiku" ;;
      "" )      model="unknown" ;;
      *)        model="$m" ;;
    esac
  fi
  MODEL_COUNT[$model]=$(( ${MODEL_COUNT[$model]:-0} + 1 ))

  # task type — classify on the full task title (from prompt.md) + slug for accuracy
  name=""
  [[ -r "$dir/prompt.md" ]] && name=$(grep -m1 -E '^# Worker Task:|^# Task:' "$dir/prompt.md" 2>/dev/null)
  tt=$(classify "$name $slug")
  TYPE_COUNT[$tt]=$(( ${TYPE_COUNT[$tt]:-0} + 1 ))
  TYPE_EX[$tt]="${TYPE_EX[$tt]:-}${started}	${slug}"$'\n'

  tid=""
  [[ -r "$dir/clickup-task-id" ]] && tid=$(tr -dc '0-9a-z' < "$dir/clickup-task-id")
  TASKIDS+=("$tid")
  SLUGS+=("$slug")
done

pct() { [[ $2 -gt 0 ]] && echo " ($(( $1 * 100 / $2 ))%)" || echo ""; }

echo "=== Worker Health Dashboard ==="
echo "Data: $WORKERS_DIR"
[[ -n "$LAST_N_DAYS" ]] && echo "Window: last ${LAST_N_DAYS}d (started-at)"
echo "Total workers: $total"
echo "  Live now:     $live$(pct $live $total)   (heartbeat < ${LIVE_THRESHOLD}s)"
echo "  Finished:     $finished$(pct $finished $total)"
[[ -z "$LAST_N_DAYS" ]] && echo "  Started <=7d: $recent$(pct $recent $total)"

echo ""
echo "=== By model ==="
for m in "${!MODEL_COUNT[@]}"; do printf '%s\t%s\n' "${MODEL_COUNT[$m]}" "$m"; done \
  | sort -rn | awk -F'\t' '{printf "  %-8s %s\n", $2, $1}'

echo ""
echo "=== By task type (top-5 examples each) ==="
for tt in outreach research scan infra other; do
  c=${TYPE_COUNT[$tt]:-0}
  [[ $c -eq 0 ]] && continue
  printf "  %-9s %3d%s\n" "$tt" "$c" "$(pct $c $total)"
  # newest 5 examples by started-at
  printf '%s' "${TYPE_EX[$tt]:-}" | grep -v '^$' | sort -rn -t'	' -k1 | head -5 \
    | while IFS=$'\t' read -r _ slug; do echo "      - $slug"; done
done

# ----- optional ClickUp status enrichment -----
if [[ $USE_CLICKUP -eq 1 ]]; then
  echo ""
  echo "=== ClickUp status (best-effort: open tasks in configured scope, cap 100) ==="
  CU="$SCRIPT_DIR/clickup/clickup.sh"
  declare -A STATUS_MAP
  if [[ -x "$CU" ]]; then
    while IFS='|' read -r tid st _rest; do
      tid=$(printf '%s' "$tid" | tr -dc '0-9a-z')
      st=$(printf '%s' "$st" | tr -d ' ')
      [[ -n "$tid" ]] && STATUS_MAP[$tid]="$st"
    done < <(timeout 8 "$CU" dashboard --statuses todo,in_progress,blocked,in_review,on_hold 2>/dev/null | tr -d ' ' | sed 's/|/ | /')
  fi

  if [[ ${#STATUS_MAP[@]} -eq 0 ]]; then
    echo "  (no ClickUp data — token missing, offline, or nothing open in scope)"
  else
    declare -A DIST
    resolved=0
    for i in "${!TASKIDS[@]}"; do
      tid="${TASKIDS[$i]}"
      [[ -z "$tid" ]] && continue
      st="${STATUS_MAP[$tid]:-}"
      [[ -z "$st" ]] && continue
      DIST[$st]=$(( ${DIST[$st]:-0} + 1 ))
      ((resolved++))
    done
    echo "  Resolved $resolved/$total worker tasks against open ClickUp tasks:"
    for st in "${!DIST[@]}"; do printf '%s\t%s\n' "${DIST[$st]}" "$st"; done \
      | sort -rn | awk -F'\t' '{printf "    %-12s %s\n", $2, $1}'
    echo "  (unresolved = closed/done or outside the configured scope)"
  fi

  # --blocked / --partial listing
  if [[ -n "$FILTER" ]]; then
    want="$FILTER"; [[ "$FILTER" == "partial" ]] && want="on_hold"
    echo ""
    echo "=== Workers with ClickUp status '$want' ==="
    any=0
    for i in "${!TASKIDS[@]}"; do
      tid="${TASKIDS[$i]}"
      [[ -z "$tid" ]] && continue
      if [[ "${STATUS_MAP[$tid]:-}" == "$want" ]]; then
        echo "  [${SLUGS[$i]}] https://app.clickup.com/t/$tid"
        any=1
      fi
    done
    [[ $any -eq 0 ]] && echo "  (none)"
  fi
fi
