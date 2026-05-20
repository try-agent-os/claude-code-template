#!/bin/bash
# _common.sh — shared helpers for tmux-session/*.sh scripts.
# Source this file at the top of each script:
#   source "$(dirname "$0")/_common.sh"
#
# Provides:
#   - TMUX_TMPDIR convention (shared socket via $HOME/.tmux)
#   - PATH augmentation (~/.local/bin for `claude`, ~/.bun/bin for `bun`)
#   - tx()           — `tmux` wrapper that uses the shared socket
#   - tx_has()       — does a session exist? (returns 0/1)
#   - log_activity() — append a line to memory/worker-activity.log
#   - INSTALL_ROOT   — resolved repo root (parent of scripts/)
#
# Convention: never call `tmux` directly in these scripts — always via tx().

set -euo pipefail

# Resolve install root (parent of scripts/tmux-session/).
INSTALL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export INSTALL_ROOT

# Optional env file (matches existing scripts/ convention).
ENV_FILE="${AGENT_OS_ENV_FILE:-/etc/agent-os/agent-os.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

# Shared tmux socket — same path the operator unit uses (Environment=
# TMUX_TMPDIR=... in agent-os-operator.service). Without this, sessions land
# on /tmp/tmux-{uid}/default which is PrivateTmp-isolated for systemd units,
# and worker sessions become invisible to operator pane lookups.
export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
mkdir -p "$TMUX_TMPDIR" 2>/dev/null || true

# PATH for new shells spawned inside tmux — `claude` CLI lives at ~/.local/bin
# after `claude migrate-installer` (the recommended install path); ~/.bun/bin
# covers any bun-installed binaries shared across agents.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

# Activity log (append-only).
ACTIVITY_LOG="${ACTIVITY_LOG:-$INSTALL_ROOT/memory/worker-activity.log}"

tx() {
  TMUX_TMPDIR="$TMUX_TMPDIR" tmux "$@"
}

tx_has() {
  tx has-session -t "$1" 2>/dev/null
}

log_activity() {
  local msg="$*"
  printf '%s | tmux-session | %s\n' "$(date '+%Y-%m-%d %H:%M')" "$msg" \
    >> "$ACTIVITY_LOG" 2>/dev/null || true
}

# Refuse names that would collide with system sessions.
RESERVED_SESSION_NAMES=(operator sysadmin dispatcher claude-login)

is_reserved_name() {
  local name="$1"
  for r in "${RESERVED_SESSION_NAMES[@]}"; do
    [[ "$name" == "$r" ]] && return 0
  done
  return 1
}

# Print error to stderr and exit non-zero.
die() {
  echo "ERROR: $*" >&2
  exit 1
}
