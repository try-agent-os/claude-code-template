#!/bin/bash
# Strategist launcher — runs independently of dispatcher via launchd
# Launches strategist worker via tmux (same as dispatcher Step 6)

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

cd "$HEARTBEAT_DIR"

# Launch via worker-launcher (idempotent — skips if tmux session exists)
# Opus: strategist performs deep analysis and strategic reasoning
bash worker-launcher.sh "strategist" strategist-prompt.md 30 45 "" "${STRATEGIST_MODEL:-claude-opus-4-6}" 2>>"$LOG_DIR/strategist.log"

echo "=== Strategist launched at $(date) ===" >> "$LOG_DIR/strategist.log"
exit 0
