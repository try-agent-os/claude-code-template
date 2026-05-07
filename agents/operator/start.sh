#!/usr/bin/env bash
# AgentOS operator bootstrap.
#
# Cross-platform: detects mac (launchd) vs linux (systemd). On both platforms
# the script ensures dependent MCP daemons are up, then launches Claude Code
# inside a detached tmux session named "operator".
#
# Required env (typically exported by the caller or sourced from the env file):
#   INSTALL_ROOT  — repo root (default: dirname of this file's parents)
#   PROJECT_SLUG  — used for launchd label namespacing on mac (default: agent-os)
#
# On Linux this script is invoked by `agent-os-operator.service` (Type=forking)
# OR can be run interactively for debugging. On macOS it's invoked manually or
# via the corresponding launchd plist.

set -euo pipefail

# Resolve INSTALL_ROOT — assume this script lives at $INSTALL_ROOT/agents/operator/start.sh
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
PROJECT_SLUG="${PROJECT_SLUG:-agent-os}"
SESSION="operator"

PLATFORM="$(uname -s)"

is_linux_systemd() {
  [ "$PLATFORM" = "Linux" ] && command -v systemctl >/dev/null 2>&1
}

is_macos() {
  [ "$PLATFORM" = "Darwin" ]
}

log() {
  echo "[operator] $*"
}

# ---------------------------------------------------------------------------
# Pre-flight: kill stale tmux session
# ---------------------------------------------------------------------------
if tmux has-session -t "$SESSION" 2>/dev/null; then
  log "Killing existing tmux session..."
  tmux kill-session -t "$SESSION"
  sleep 1
fi

# ---------------------------------------------------------------------------
# Ensure dependent services are running
# ---------------------------------------------------------------------------
if is_linux_systemd; then
  log "Linux/systemd detected. Verifying claude-peers + telegram services..."

  # Sanity: warn if launchd plists somehow snuck onto a Linux box
  if [ -d "$HOME/Library/LaunchAgents" ] && \
     ls "$HOME/Library/LaunchAgents/com.${PROJECT_SLUG}."*.plist >/dev/null 2>&1; then
    log "WARNING: launchd plists found on Linux — they are inert here, but should be removed."
  fi

  for unit in agent-os-claude-peers agent-os-telegram; do
    if ! systemctl is-active --quiet "$unit"; then
      log "Service $unit not active — attempting to start..."
      sudo systemctl start "$unit" || log "Failed to start $unit (continuing — may be running under different name)"
    fi
  done

elif is_macos; then
  log "macOS/launchd detected. Verifying claude-peers + telegram plists..."
  for svc in claude-peers-broker telegram-mcp; do
    if ! launchctl list "com.${PROJECT_SLUG}.$svc" &>/dev/null; then
      plist="$HOME/Library/LaunchAgents/com.${PROJECT_SLUG}.$svc.plist"
      if [ -f "$plist" ]; then
        log "Loading $svc..."
        launchctl load "$plist"
        sleep 2
      else
        log "WARNING: plist not found at $plist"
      fi
    fi
  done
else
  log "Unsupported platform: $PLATFORM (expected Linux or Darwin)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Wait for HTTP health endpoints
# ---------------------------------------------------------------------------
for url in "http://127.0.0.1:7899/health" "http://127.0.0.1:3848/health"; do
  for _ in $(seq 1 10); do
    if curl -sf "$url" &>/dev/null; then
      log "OK: $url"
      break
    fi
    log "Waiting for $url..."
    sleep 1
  done
done

# ---------------------------------------------------------------------------
# Launch Claude in tmux
# ---------------------------------------------------------------------------
log "Starting tmux session '$SESSION' under $INSTALL_ROOT..."

ADD_DIRS=()
for d in memory agents studio research resources; do
  if [ -d "$INSTALL_ROOT/$d" ]; then
    ADD_DIRS+=(--add-dir "$INSTALL_ROOT/$d")
  fi
done

tmux new-session -d -s "$SESSION" -c "$INSTALL_ROOT/agents/operator" \
  "claude --dangerously-skip-permissions ${ADD_DIRS[*]} \
   --dangerously-load-development-channels server:claude-peers \
   --dangerously-load-development-channels server:telegram"

sleep 5
tmux send-keys -t "$SESSION" Enter
sleep 8
tmux send-keys -t "$SESSION" "boot" Enter

log "Started. Verifying peer registration..."
sleep 15

PEERS=$(curl -s http://127.0.0.1:7899/list-peers \
  -H 'Content-Type: application/json' \
  -d '{"scope":"machine","cwd":"/","git_root":null}' 2>/dev/null | \
  grep -c operator 2>/dev/null || echo 0)

if [ "$PEERS" -gt 0 ]; then
  log "OK — operator registered as peer"
else
  log "WARNING — not registered as peer yet (may need more time, or channel push misconfigured)"
fi
