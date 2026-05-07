#!/usr/bin/env bash
# AgentOS uninstaller — reverses install.sh.
#
# Usage:
#   sudo ./uninstall.sh             # stops + disables units, removes unit files,
#                                   # KEEPS data (state, logs, env file, agent-os user).
#                                   # Also cleans plugin cache + agentos marketplace
#                                   # entry from ~/.claude/settings.json.
#   sudo ./uninstall.sh --purge     # additionally removes /var/lib/agent-os,
#                                   # /var/log/agent-os, /var/log/agentos-hooks,
#                                   # /etc/agent-os, /opt/agent-os, /etc/claude-code,
#                                   # the agent-os user, and the apt source.
#   sudo ./uninstall.sh --purge --keep-data
#                                   # like --purge but preserves /var/lib/agent-os
#                                   # and ~/.claude/projects/ (state, transcripts,
#                                   # audit logs). Use this for in-place upgrades.
#   sudo ./uninstall.sh --purge --purge-credentials
#                                   # also delete ~/.claude/.credentials.json after
#                                   # interactive confirmation. Affects the agent-os
#                                   # user only — your personal Claude creds are safe.
#   sudo ./uninstall.sh --reset-state
#                                   # ONLY deletes /etc/agent-os/install.state.json
#                                   # so install.sh re-prompts the wizard. Services
#                                   # and data remain intact.
#
# Idempotent — running twice on a clean system is a no-op.

set -euo pipefail

readonly AGENT_USER="agent-os"
readonly AGENT_HOME="/home/${AGENT_USER}"
readonly INSTALL_ROOT="/opt/agent-os"
readonly LOG_DIR="/var/log/agent-os"
readonly HOOKS_LOG_DIR="/var/log/agentos-hooks"
readonly STATE_DIR="/var/lib/agent-os"
readonly ETC_DIR="/etc/agent-os"
readonly CLAUDE_MANAGED_DIR="/etc/claude-code"

PURGE=0
RESET_STATE_ONLY=0
KEEP_DATA=0
PURGE_CREDS=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --reset-state) RESET_STATE_ONLY=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    --purge-credentials) PURGE_CREDS=1 ;;
    -h|--help) sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root (use sudo)." >&2; exit 1; }

log() { printf '\033[1;32m[uninstall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[uninstall]\033[0m %s\n' "$*"; }

# --reset-state: delete only the wizard state file. Services + data stay.
if [[ "$RESET_STATE_ONLY" == 1 ]]; then
  STATE_FILE="${ETC_DIR}/install.state.json"
  if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    log "removed wizard state: $STATE_FILE"
  else
    log "no wizard state file at $STATE_FILE — nothing to do"
  fi
  log "Services left running. Re-run install.sh to re-enter wizard answers."
  exit 0
fi

UNITS=(
  agent-os-dispatcher.timer
  agent-os-dispatcher.service
  agent-os-operator.service
  agent-os-saga.service
)
# Legacy units (pre-plugin-migration). Kept here for cleanup on upgrade.
LEGACY_UNITS=(
  agent-os-telegram.service
  agent-os-claude-peers.service
)

log "stopping + disabling units"
for u in "${UNITS[@]}" "${LEGACY_UNITS[@]}"; do
  if systemctl list-unit-files "$u" >/dev/null 2>&1; then
    systemctl stop    "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
  fi
done

log "removing unit files"
for u in "${UNITS[@]}" "${LEGACY_UNITS[@]}"; do
  rm -f "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

log "killing leftover tmux sessions owned by ${AGENT_USER}"
if id "$AGENT_USER" >/dev/null 2>&1; then
  sudo -u "$AGENT_USER" tmux kill-server 2>/dev/null || true
fi

###############################################################################
# Plugin cache cleanup (always — these are template-managed, not user data)
###############################################################################
log "cleaning agentos plugin cache"
for plugin_cache in \
    "${AGENT_HOME}/.claude/plugins/cache/agentos" \
    "${AGENT_HOME}/.claude/plugins/repos/agentos" ; do
  if [[ -d "$plugin_cache" ]]; then
    rm -rf "$plugin_cache"
    log "  removed $plugin_cache"
  fi
done

###############################################################################
# Surgically remove "agentos" entry from ${AGENT_HOME}/.claude/settings.json
###############################################################################
remove_agentos_marketplace() {
  local settings_file="$1"
  [[ -f "$settings_file" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    warn "  jq not installed — skipping marketplace cleanup in $settings_file"
    return 0
  fi
  # Only touch the file if it actually has an agentos entry.
  if jq -e '.extraKnownMarketplaces.agentos // .extraKnownMarketplaces["agentos"]' \
        "$settings_file" >/dev/null 2>&1; then
    local tmpf
    tmpf="$(mktemp)"
    jq 'if .extraKnownMarketplaces?.agentos then del(.extraKnownMarketplaces.agentos) else . end
        | if .extraKnownMarketplaces == {} then del(.extraKnownMarketplaces) else . end' \
        "$settings_file" > "$tmpf" && mv "$tmpf" "$settings_file"
    log "  scrubbed extraKnownMarketplaces.agentos from $settings_file"
  fi
}
remove_agentos_marketplace "${AGENT_HOME}/.claude/settings.json"

###############################################################################
# PURGE
###############################################################################
if [[ "$PURGE" == 1 ]]; then
  if [[ "$KEEP_DATA" == 1 ]]; then
    log "PURGE --keep-data: removing config + apt + user but preserving state/logs/transcripts"
    rm -rf "$ETC_DIR" "$CLAUDE_MANAGED_DIR" "$INSTALL_ROOT"
    # Preserve: $STATE_DIR, $LOG_DIR, $HOOKS_LOG_DIR, $AGENT_HOME/.claude/projects/
    log "  preserved: $STATE_DIR, $LOG_DIR, $HOOKS_LOG_DIR, ${AGENT_HOME}/.claude/projects/"
  else
    log "PURGE: removing data + agent-os user + apt source"
    rm -rf "$INSTALL_ROOT" "$LOG_DIR" "$HOOKS_LOG_DIR" "$STATE_DIR" "$ETC_DIR"
    rm -rf "$CLAUDE_MANAGED_DIR"
  fi

  # Remove apt repo + key
  rm -f /etc/apt/sources.list.d/claude-code.list
  rm -f /usr/share/keyrings/anthropic.gpg

  # Optional: remove the claude-code package itself.
  # We keep it by default since the user may still want claude-code on the box.
  if [[ "${PURGE_CLAUDE_CODE:-0}" == 1 ]]; then
    apt-get purge -y claude-code 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
  fi

  # Optional: delete agent-os user's Claude credentials (Keychain on macOS,
  # file-based on Linux). Confirmed interactively to avoid wiping creds shared
  # with other Claude workspaces.
  if [[ "$PURGE_CREDS" == 1 ]] && id "$AGENT_USER" >/dev/null 2>&1; then
    creds="${AGENT_HOME}/.claude/.credentials.json"
    if [[ -f "$creds" ]]; then
      if [[ -t 0 ]]; then
        warn "About to delete: $creds"
        warn "This is the OAuth token for the ${AGENT_USER} user. If you re-install, you'll need to run 'claude setup-token' again."
        printf "  Type 'yes' to confirm: " >&2
        read -r yn
        if [[ "$yn" == "yes" ]]; then
          rm -f "$creds"
          log "  deleted $creds"
        else
          log "  skipped credentials deletion"
        fi
      else
        # non-tty: refuse silent deletion
        warn "  --purge-credentials given but stdin is not a TTY — refusing silent delete of $creds"
      fi
    fi
  fi

  if id "$AGENT_USER" >/dev/null 2>&1; then
    if [[ "$KEEP_DATA" == 1 ]]; then
      log "  preserving ${AGENT_USER} user (--keep-data)"
    else
      pkill -u "$AGENT_USER" 2>/dev/null || true
      userdel -r "$AGENT_USER" 2>/dev/null || \
        log "  (could not auto-remove ${AGENT_USER} home — clean up manually)"
    fi
  fi

  log "PURGE complete."
else
  log "data preserved at: ${INSTALL_ROOT}, ${STATE_DIR}, ${LOG_DIR}, ${ETC_DIR}"
  log "user '${AGENT_USER}' preserved. Run with --purge to also remove these."
fi

cat <<EOF

========================================================================
  AgentOS units removed.
========================================================================
  Re-install:    sudo ./install.sh
$( [[ "$PURGE" == 1 ]] && [[ "$KEEP_DATA" == 0 ]] && echo "  Data fully purged. agent-os user removed (if present)." \
   || ([[ "$PURGE" == 1 ]] && echo "  Config purged, data preserved (--keep-data).") \
   || echo "  Data preserved. Re-run install.sh for an in-place upgrade." )
========================================================================
EOF
