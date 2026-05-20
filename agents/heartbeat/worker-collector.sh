#!/bin/bash
# Check all running workers, collect results from finished ones
# Usage: ./worker-collector.sh
#
# Scans logs/workers/*/result.md for completed workers
# Output: JSON array of completed workers
# [{"task_id": "xxx", "status": "done", "summary": "..."}]

set -euo pipefail

# Shared tmux server (see worker-launcher.sh for rationale).
export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"

HOME="${HOME}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WORK_DIR="$REPO_ROOT"
WORKERS_DIR="${WORK_DIR}/logs/workers"
RESULTS="[]"

# Exit early if no workers directory
if [[ ! -d "$WORKERS_DIR" ]]; then
  echo "$RESULTS"
  exit 0
fi

for WORKER_DIR in "$WORKERS_DIR"/*/; do
  [[ -d "$WORKER_DIR" ]] || continue

  TASK_ID=$(basename "$WORKER_DIR")
  RESULT_FILE="${WORKER_DIR}/result.md"
  SESSION_NAME="worker-${TASK_ID}"

  # Check if tmux session is still running
  SESSION_ALIVE=false
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    SESSION_ALIVE=true
  fi

  # If result exists — worker completed
  if [[ -f "$RESULT_FILE" ]] && [[ -s "$RESULT_FILE" ]]; then
    # Parse frontmatter status (python3: BSD sed range syntax broken on macOS)
    STATUS=$(python3 -c "
content = open('$RESULT_FILE').read()
for line in content.split('\n'):
    if line.startswith('status:'):
        print(line.split(':', 1)[1].strip())
        break
" 2>/dev/null || echo "unknown")
    SUMMARY=$(python3 -c "
content = open('$RESULT_FILE').read()
for line in content.split('\n'):
    if line.startswith('summary:'):
        print(line.split(':', 1)[1].strip())
        break
" 2>/dev/null || echo "")

    # Normalize: timeout and unknown are NOT successful completions
    # Dispatcher must return these tasks to todo, not mark done
    if [[ "$STATUS" == "timeout" ]] || [[ "$STATUS" == "unknown" ]] || [[ -z "$STATUS" ]]; then
      STATUS="timeout"
      [[ -z "$SUMMARY" ]] && SUMMARY="Worker finished without valid result"
    fi

    # Add to results
    RESULTS=$(echo "$RESULTS" | jq --arg id "$TASK_ID" --arg status "$STATUS" --arg summary "$SUMMARY" \
      '. + [{"task_id": $id, "status": $status, "summary": $summary}]')

    # Kill tmux session if still alive
    if $SESSION_ALIVE; then
      tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    fi

  # If session dead but no result — worker crashed
  # Only report crash if heartbeat is recent (<3h): old heartbeats = already-processed crashes
  # Prevents infinite re-reporting of stale PAUSE/blocked workers on every dispatcher cycle
  elif ! $SESSION_ALIVE && [[ -f "${WORKER_DIR}/heartbeat" ]]; then
    HEARTBEAT_AGE=$(( $(date +%s) - $(stat -f '%m' "${WORKER_DIR}/heartbeat" 2>/dev/null || echo 0) ))
    if [[ $HEARTBEAT_AGE -lt 10800 ]]; then
      RESULTS=$(echo "$RESULTS" | jq --arg id "$TASK_ID" \
        '. + [{"task_id": $id, "status": "crashed", "summary": "Worker session died without result"}]')
    fi
  fi
  # If session alive and no result — still working, skip
done

echo "$RESULTS"
exit 0
