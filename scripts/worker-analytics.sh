#!/bin/bash
# Worker status aggregator — AgentOS health dashboard.
# Usage: ./scripts/worker-analytics.sh [--blocked] [--month YYYY-MM]
#
# The interactive worker model has no per-worker result.md — each worker's
# terminal state is recorded as one line in memory/worker-activity/YYYY-MM.log
# by the /done and /blocked commands:
#   <iso> finished <slug> duration=<N>m clickup=<id>
#   <iso> blocked  <slug> duration=<N>m clickup=<id>
# (spawn-worker.sh also appends a "worker <slug> started …" line.)
# This script aggregates those lines.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ACTIVITY_DIR="$REPO/memory/worker-activity"

FILTER=""
MONTH="$(date -u +%Y-%m)"
while [ $# -gt 0 ]; do
  case "$1" in
    --blocked) FILTER="blocked" ;;
    --month) shift; MONTH="${1:-$MONTH}" ;;
  esac
  shift
done

LOG="$ACTIVITY_DIR/$MONTH.log"
if [ ! -f "$LOG" ]; then
  echo "no worker-activity log for $MONTH ($LOG)"
  exit 0
fi

echo "=== Worker Status Distribution ($MONTH) ==="
finished=$(grep -c ' finished ' "$LOG" 2>/dev/null || echo 0)
blocked=$(grep -c ' blocked ' "$LOG" 2>/dev/null || echo 0)
started=$(grep -c ' started ' "$LOG" 2>/dev/null || echo 0)
total=$(( finished + blocked ))

echo "Started:  $started"
echo "Finished: $finished"
echo "Blocked:  $blocked"
[ "$total" -gt 0 ] && echo "Finish rate: $(( finished * 100 / total ))% (of terminal outcomes)"

if [ "$FILTER" = "blocked" ] || [ -z "$FILTER" ]; then
  echo ""
  echo "=== Blocked workers ==="
  grep ' blocked ' "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
fi
