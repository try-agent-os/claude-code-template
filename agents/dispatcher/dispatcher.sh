#!/bin/bash
# Dispatcher entry point — запускается launchd/cron, делает один цикл, завершается.
#
# Что нужно настроить перед запуском:
#   AGENTOS_ROOT — корень AgentOS-репозитория (по умолчанию $HOME/Workspaces/agentos)
#   CLAUDE       — путь к claude CLI (по умолчанию $HOME/.local/bin/claude)
#   TZ           — таймзона для day/night throttle (по умолчанию UTC)
#
# Throttle:
#   - Day   (07:00-00:00 локального времени): skip if last_run < 55 min ago → effective ~90 min
#   - Night (00:00-07:00): run every cycle → ~9-10 cycles per night

set -uo pipefail
# No set -e: script must always reach cleanup (trap) even if commands fail

HOME="${HOME:-$HOME}"
export USER="${USER:-$(whoami)}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Skip MCP connection wait on startup — especially important for ephemeral -p sessions
export MCP_CONNECTION_NONBLOCKING=true

AGENTOS_ROOT="${AGENTOS_ROOT:-$HOME/Workspaces/agentos}"
LOCK="/tmp/agentOS-dispatcher.lock"
LOG_DIR="$AGENTOS_ROOT/logs"
CLAUDE="${CLAUDE:-$HOME/.local/bin/claude}"
THROTTLE_TZ="${THROTTLE_TZ:-UTC}"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# One dispatcher at a time (mkdir is atomic on all POSIX systems)
if ! mkdir "$LOCK" 2>/dev/null; then
  # Check if lock is stale (older than 15 min = stuck dispatcher)
  if [ "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT INT TERM HUP

cd "$AGENTOS_ROOT/agents/dispatcher"

# Time-based throttle (plist runs every 45 min = 2700s by default):
THROTTLE_FILE="/tmp/agentOS-dispatcher-throttle"
DAYTIME_MIN_INTERVAL=3300  # 55 min in seconds
CURRENT_HOUR=$((10#$(TZ="$THROTTLE_TZ" date '+%H')))

if [ "$CURRENT_HOUR" -ge 7 ]; then
  # Daytime: throttle to ~90 min effective cycles (45 min plist × 2 skipped firings)
  if [ -f "$THROTTLE_FILE" ]; then
    LAST_RUN=$(cat "$THROTTLE_FILE")
    NOW=$(date '+%s')
    ELAPSED=$((NOW - LAST_RUN))
    if [ "$ELAPSED" -lt "$DAYTIME_MIN_INTERVAL" ]; then
      echo "=== Daytime throttle: last run ${ELAPSED}s ago (<${DAYTIME_MIN_INTERVAL}s), skipping ===" >> "$LOG_DIR/dispatcher.log"
      sleep 15  # prevent launchd minimum_runtime throttle blocking periodic job
      exit 0
    fi
  fi
fi
date '+%s' > "$THROTTLE_FILE"

# Per-session logs: logs/dispatcher/{date}/{HH-MM-SS}.{log,jsonl}
DATE_DIR=$(date '+%Y-%m-%d')
TIME_STAMP=$(date '+%H-%M-%S')
SESSION_DIR="$LOG_DIR/dispatcher/$DATE_DIR"
mkdir -p "$SESSION_DIR"
SESSION_JSONL="$SESSION_DIR/${TIME_STAMP}.jsonl"
SESSION_LOG="$SESSION_DIR/${TIME_STAMP}.log"

echo "=== Cycle started at $(date) ===" | tee "$SESSION_LOG" >> "$LOG_DIR/dispatcher.log"

# Git pull before cycle — ensures fresh memory/*.md before dispatcher reads context
cd "$AGENTOS_ROOT"
git diff --quiet && git diff --cached --quiet || git stash
GIT_PULL_OUT=$(git pull --rebase origin main 2>&1) || {
  echo "[$(date)] git pull failed: $GIT_PULL_OUT" >> "$AGENTOS_ROOT/memory/worker-errors.log"
}
git stash pop 2>/dev/null || true
cd "$AGENTOS_ROOT/agents/dispatcher"

# Log dispatcher start for health watchdog
echo "$(date +'%Y-%m-%d %H:%M') | dispatcher_start | cycle_$(grep -o 'heartbeat_count: [0-9]*' "$AGENTOS_ROOT/memory/context.md" 2>/dev/null | grep -o '[0-9]*' || echo '?')" >> "$AGENTOS_ROOT/memory/worker-activity.log"

# Real-time pipe: claude → tee(JSONL) → parser → tee(session.log) → dispatcher.log
$CLAUDE -p "$(cat dispatcher-prompt.md)" \
  --dangerously-skip-permissions \
  --add-dir "$AGENTOS_ROOT/memory" \
  --add-dir "$AGENTOS_ROOT/agents" \
  --model sonnet \
  --output-format stream-json --verbose \
  2>>"$LOG_DIR/dispatcher-errors.log" \
  | tee "$SESSION_JSONL" \
  | python3 "$AGENTOS_ROOT/agents/dispatcher/parse-stream.py" \
  | tee -a "$SESSION_LOG" >> "$LOG_DIR/dispatcher.log" \
  || true

# Cleanup: remove day folders older than 7 days
find "$LOG_DIR/dispatcher" -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null

exit 0
