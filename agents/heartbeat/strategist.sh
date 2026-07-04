#!/bin/bash
# Strategist launcher — runs independently via its Dagu DAG (routines/strategist.yaml).
# Launches the strategist worker in a tmux session via spawn-worker.sh.
#
# The strategist has no real backend task id — "strategist" is passed as a
# placeholder slug so spawn-worker.sh can create its bookkeeping directory
# (logs/workers/strategist/). It runs in the shared main tree (WORKER_NO_WORKTREE)
# because it edits memory/ in place and is a singleton — no cross-task contention.
#
# The strategist session self-terminates after writing its output. The Dagu DAG
# timeout_sec only governs this launcher script, not the worker itself.

HOME="${HOME}"
export USER="${USER}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export MCP_CONNECTION_NONBLOCKING=true

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
REPO="$REPO_ROOT"
HEARTBEAT_DIR="$REPO/agents/heartbeat"
LOG_DIR="$REPO/logs"
LOCK="/tmp/agentOS-strategist.lock"

# One strategist at a time
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M') | strategist already running or lock exists, skip" >> "$LOG_DIR/strategist.log"
  exit 0
fi
trap 'rm -rf "$LOCK"' EXIT INT TERM HUP

mkdir -p "$LOG_DIR"
echo "=== Strategist started at $(date) ===" >> "$LOG_DIR/strategist.log"

# Preflight gate — settings.json valid, tmux accessible, optional dep hook.
if [ -x "$REPO/scripts/worker-preflight.sh" ]; then
  if ! bash "$REPO/scripts/worker-preflight.sh" >> "$LOG_DIR/strategist.log" 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M') | preflight failed — aborting strategist launch" >> "$LOG_DIR/strategist.log"
    exit 1
  fi
fi

# Launch via spawn-worker.sh (interactive tmux session). "strategist" is both the
# session slug and the placeholder backend id.
PROMPT_FILE="$HEARTBEAT_DIR/strategist-prompt.md"
WORKER_NO_WORKTREE=1 bash "$REPO/scripts/spawn-worker.sh" \
  "strategist" "strategist" "$PROMPT_FILE" 45 \
  "${STRATEGIST_MODEL:-${DEFAULT_MODEL:-claude-sonnet-4-6}}" \
  >> "$LOG_DIR/strategist.log" 2>&1

echo "=== Strategist launched at $(date) ===" >> "$LOG_DIR/strategist.log"
exit 0
