#!/bin/bash
# claude-cli-update.sh — safely keep the Claude Code CLI up to date on the hub.
#
# Install method assumed: NATIVE installer. `claude` is a symlink
#   ~/.local/bin/claude -> ~/.local/share/claude/versions/<VER>
# and the CLI ships its own updater: `claude update`. We use that STOCK
# mechanism (no npm, no manual download).
#
# Why this is safe for live sessions:
#   - `claude update` drops a NEW versions/<NEW> binary and flips the symlink.
#     Already-running processes (operator, workers) keep their OPEN inode and
#     are untouched; only NEW spawns pick up the new binary. We do NOT restart
#     any service here.
#
# CRITICAL post-update steps (only when the version actually changed):
#   1) Re-apply the DevChannelsDialog binary patch. A fresh CC build brings the
#      blocking "WARNING: Loading development channels … yes" prompt back; the
#      new binary is unpatched. Headless worker/operator spawns would hang on it.
#      We re-run the self-discovering idempotent patcher
#      scripts/ensure-dev-channels-patch.py (no-op if already patched).
#   2) Verify managed-settings (/etc/claude-code/managed-settings.json) is still
#      present + valid JSON (channels/plugins policy). Best-effort: the file is
#      root-owned, so a read failure is reported as a warning, not a hard fail.
#   3) Smoke-test slash-command injection (scripts/inject-smoke-test.sh) against
#      the NEW binary. A CLI update can silently break /clear + /model injection
#      into live tmux sessions; the daily update is where that regression is
#      cheapest to catch. Skipped (not fatal) if the smoke script is absent.
#
# Notifications: on a real update OR on any error -> optional notify hook
#   (AGENT_OS_NOTIFY_HOOK, called with --source claude-cli-update --severity
#   <info|error> --msg <text>). Unset/absent hook => log-only, no-op.
#   No notification on a clean no-op (already latest) to avoid daily noise.
#
# Always exit 0 — this is a scheduled maintenance routine and must never flap
# upstream (Dagu) or block. Failures are logged + surfaced via notify-operator.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${AGENT_OS_HUB:-$(dirname "$SCRIPT_DIR")}"
LOG_DIR="/var/log/agent-os"
LOG_FILE="$LOG_DIR/claude-cli-update.log"
# Optional alert hook. Set AGENT_OS_NOTIFY_HOOK to an executable accepting
# `--source <name> --severity <info|warn|error> --msg <text>`; unset => log-only.
NOTIFY="${AGENT_OS_NOTIFY_HOOK:-}"
PATCH_SCRIPT="$PROJECT_DIR/scripts/ensure-dev-channels-patch.py"
MANAGED_SETTINGS="/etc/claude-code/managed-settings.json"

# Resolve the claude launcher. Scheduled (Dagu) shells may lack ~/.local/bin on
# PATH, so fall back to the conventional location.
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date -u -Iseconds)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

notify() {
  # notify <severity> <msg>
  local sev="$1"; shift
  local msg="$*"
  [ -n "$NOTIFY" ] && [ -x "$NOTIFY" ] && "$NOTIFY" --source claude-cli-update --severity "$sev" --msg "$msg" >/dev/null 2>&1 || true
}

# Extract just the semver-ish token from `claude --version` ("2.1.168 (Claude Code)").
get_version() {
  "$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

if [ -z "$CLAUDE_BIN" ]; then
  log "ERROR: claude binary not found (PATH + ~/.local/bin/claude). Aborting."
  notify error "claude-cli-update: claude binary not found — update skipped"
  exit 0
fi

OLD_VER="$(get_version)"
log "start: claude=$CLAUDE_BIN current=${OLD_VER:-unknown}"

# --- Stock update --------------------------------------------------------------
UPDATE_OUT="$("$CLAUDE_BIN" update 2>&1)"
UPDATE_RC=$?
log "claude update rc=$UPDATE_RC out=$(printf '%s' "$UPDATE_OUT" | tr '\n' ' ' | head -c 500)"

NEW_VER="$(get_version)"

if [ -z "$NEW_VER" ]; then
  log "ERROR: claude --version returned nothing after update — possible broken binary"
  notify error "claude-cli-update: claude --version empty after update (possibly broken binary). old=${OLD_VER:-unknown}"
  exit 0
fi

# --- Version unchanged --------------------------------------------------------
# Check this FIRST so a successful "already latest" run is a silent no-op and
# never pings the operator. If the version did NOT change but the updater also
# errored (rc!=0), surface that once — it's a real install failure (e.g. EROFS,
# network) worth a look, distinct from the routine clean no-op.
if [ "$OLD_VER" = "$NEW_VER" ]; then
  if [ "$UPDATE_RC" -ne 0 ]; then
    log "WARN: no version change but claude update rc=$UPDATE_RC (install failed; still on $NEW_VER)"
    notify error "claude-cli-update: update did not apply (rc=$UPDATE_RC), staying on ${NEW_VER}. Log: $LOG_FILE"
  else
    log "no-op: already latest ($NEW_VER) — nothing to do"
  fi
  exit 0
fi

# --- Version changed → re-apply patch + verify settings ------------------------
log "UPDATED: $OLD_VER -> $NEW_VER"

PATCH_STATUS="ok"
if [ -f "$PATCH_SCRIPT" ]; then
  PATCH_OUT="$(/usr/bin/python3 "$PATCH_SCRIPT" 2>&1)"
  PATCH_RC=$?
  log "dev-channels patch rc=$PATCH_RC out=$(printf '%s' "$PATCH_OUT" | tr '\n' ' ' | head -c 400)"
  [ "$PATCH_RC" -ne 0 ] && PATCH_STATUS="FAILED (rc=$PATCH_RC)"
else
  PATCH_STATUS="SKIPPED (patcher missing: $PATCH_SCRIPT)"
  log "WARN: $PATCH_STATUS"
fi

# Verify the new binary actually runs.
RUN_OK="yes"
"$CLAUDE_BIN" --version >/dev/null 2>&1 || RUN_OK="NO"
log "post-update claude --version runs: $RUN_OK"

# Smoke-test the slash-command INJECT mechanism against the NEW binary. A CLI
# update can silently break /clear + /model injection (the 2.1.211 -> 2.1.212
# build started swallowing bulk send-keys as a paste). This spawns a throwaway
# session and confirms a char-by-char /clear still registers.
# ok / BROKEN / inconclusive / skipped (smoke script absent).
INJECT_STATUS="skipped"
SMOKE="$PROJECT_DIR/scripts/inject-smoke-test.sh"
if [ -x "$SMOKE" ]; then
  INJECT_OUT="$(/bin/bash "$SMOKE" 2>&1)"; INJECT_RC=$?
  log "inject-smoke rc=$INJECT_RC out=$(printf '%s' "$INJECT_OUT" | tr '\n' ' ' | head -c 200)"
  case "$INJECT_RC" in
    0) INJECT_STATUS="ok" ;;
    1) INJECT_STATUS="BROKEN (/clear inject regressed — verify /clear and /model!)" ;;
    *) INJECT_STATUS="inconclusive" ;;
  esac
else
  log "WARN: inject-smoke-test.sh missing/not-exec: $SMOKE"
fi

# Verify managed-settings present + valid JSON (best-effort; root-owned file).
MS_STATUS=""
if [ -r "$MANAGED_SETTINGS" ]; then
  if jq -e . "$MANAGED_SETTINGS" >/dev/null 2>&1; then
    MS_STATUS="ok (valid JSON)"
  else
    MS_STATUS="INVALID JSON"
  fi
elif [ -e "$MANAGED_SETTINGS" ]; then
  MS_STATUS="present (not readable as $(id -un) — root-owned)"
else
  MS_STATUS="MISSING ($MANAGED_SETTINGS)"
fi
log "managed-settings: $MS_STATUS"

# --- Notify operator -----------------------------------------------------------
SEV="info"
case "$PATCH_STATUS$RUN_OK$MS_STATUS$INJECT_STATUS" in
  *FAILED*|*NO*|*INVALID*|*MISSING*|*BROKEN*) SEV="error" ;;
esac

notify "$SEV" "claude-cli-update: $OLD_VER -> $NEW_VER. dev-channels patch: $PATCH_STATUS. claude runs: $RUN_OK. managed-settings: $MS_STATUS. slash-inject (/clear): $INJECT_STATUS. Log: $LOG_FILE"

log "done: $OLD_VER -> $NEW_VER (patch=$PATCH_STATUS run=$RUN_OK ms=$MS_STATUS inject=$INJECT_STATUS)"
exit 0
