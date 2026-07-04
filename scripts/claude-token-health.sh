#!/usr/bin/env bash
# claude-token-health.sh — read-only sanity check on the canonical Claude OAuth
# token. Backs the /relogin skill's "do we even need a /login?" decision so the
# operator never blindly kicks off an OAuth flow when the token is fine.
#
# It ONLY inspects the canonical credentials store; it NEVER drives a login and
# NEVER prints the token itself. Safe to run any time, by anyone.
#
# Usage:
#   claude-token-health.sh            # human line + exit code
#   claude-token-health.sh --json     # machine-readable JSON
#
# Exit codes: 0 = healthy, 1 = expired/expiring, 2 = missing/unreadable/parse-fail.
#
# Canonical store: $CLAUDE_CONFIG_DIR/.credentials.json, defaulting to the hub's
# server config-dir. Override CRED to point elsewhere (e.g. a worker child dir
# when chasing the "canonical token valid but a worker still 401s" edge case).
set -uo pipefail

CRED="${CRED:-${CLAUDE_CONFIG_DIR:-/var/lib/agent-os/claude-config/server}/.credentials.json}"

# Grace window: treat a token that expires within this many seconds as "expiring"
# so we surface it BEFORE it dies mid-request. Env-overridable, NOT a login-flow
# timeout (those live in claude-login-pipe.sh and are deliberately not hardcoded
# here). Default 0 = report dead only once actually past expiry.
GRACE_SEC="${TOKEN_GRACE_SEC:-0}"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

emit() {
  local status="$1" mins="$2" msg="$3" code="$4"
  if [ "$JSON" -eq 1 ]; then
    printf '{"status":"%s","minutes_left":%s,"cred":"%s","message":"%s"}\n' \
      "$status" "$mins" "$CRED" "$msg"
  else
    printf '%s\n' "$msg"
  fi
  exit "$code"
}

# `sudo -n cat` because the canonical store is mode 0600 owned by the install
# user; the
# operator/worker may not be that uid. Falls back to a plain read if sudo fails.
read_cred() {
  if [ -r "$CRED" ]; then cat "$CRED"; return 0; fi
  sudo -n cat "$CRED" 2>/dev/null
}

raw="$(read_cred 2>/dev/null || true)"
if [ -z "$raw" ]; then
  emit "missing" "null" "❌ Canonical token unreadable ($CRED) — file missing or no permission." 2
fi

expires_ms="$(printf '%s' "$raw" | jq -r 'try (.claudeAiOauth.expiresAt // empty) catch empty' 2>/dev/null)"
if [ -z "$expires_ms" ] || ! [[ "$expires_ms" =~ ^[0-9]+$ ]]; then
  emit "parse_fail" "null" "❌ Could not parse expiresAt from $CRED (corrupt?)." 2
fi

now_ms=$(( $(date +%s) * 1000 ))
left_ms=$(( expires_ms - now_ms ))
left_min=$(( left_ms / 60000 ))

if [ "$left_ms" -le $(( GRACE_SEC * 1000 )) ]; then
  emit "expired" "$left_min" "🔴 Token expired (or about to): ${left_min} min left. /login REQUIRED." 1
fi

emit "healthy" "$left_min" "🟢 Token healthy: ${left_min} min left. /login NOT needed." 0
