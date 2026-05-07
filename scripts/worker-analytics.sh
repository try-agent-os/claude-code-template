#!/bin/bash
# Worker status aggregator — AgentOS health dashboard
# Usage: ./scripts/worker-analytics.sh [--blocked] [--partial]
# Created: 2026-04-13 (spike PASS, saga #417)

WORKERS_DIR="$(dirname "$0")/../logs/workers"
FILTER=""

for arg in "$@"; do
  case "$arg" in
    --blocked) FILTER="blocked" ;;
    --partial) FILTER="partial" ;;
  esac
done

echo "=== Worker Status Distribution ==="
total=0; done_count=0; blocked_count=0; partial_count=0

for result in "$WORKERS_DIR"/*/result.md; do
  [ -f "$result" ] || continue
  status=$(grep -m1 "^status:" "$result" | sed 's/status: *//' | tr -d '\r\n')
  case "$status" in
    done) ((done_count++));;
    blocked) ((blocked_count++));;
    partial) ((partial_count++));;
  esac
  ((total++))
done

echo "Total: $total"
[ $total -gt 0 ] && echo "Done: $done_count ($(( done_count * 100 / total ))%)"
[ $total -gt 0 ] && echo "Blocked: $blocked_count ($(( blocked_count * 100 / total ))%)"
[ $total -gt 0 ] && echo "Partial: $partial_count ($(( partial_count * 100 / total ))%)"

if [[ -n "$FILTER" ]]; then
  echo ""
  echo "=== ${FILTER^} Workers ==="
  for result in "$WORKERS_DIR"/*/result.md; do
    [ -f "$result" ] || continue
    status=$(grep -m1 "^status:" "$result" | sed 's/status: *//' | tr -d '\r\n')
    if [[ "$status" == "$FILTER" ]]; then
      dir=$(dirname "$result")
      slug=$(basename "$dir")
      summary=$(grep -m1 "^summary:" "$result" | sed 's/summary: *//')
      echo "  [$slug] $summary"
    fi
  done
else
  echo ""
  echo "=== Blocked Workers (slug + summary) ==="
  for result in "$WORKERS_DIR"/*/result.md; do
    [ -f "$result" ] || continue
    status=$(grep -m1 "^status:" "$result" | sed 's/status: *//' | tr -d '\r\n')
    if [[ "$status" == "blocked" ]]; then
      dir=$(dirname "$result")
      slug=$(basename "$dir")
      summary=$(grep -m1 "^summary:" "$result" | sed 's/summary: *//')
      echo "  [$slug] $summary"
    fi
  done
fi
