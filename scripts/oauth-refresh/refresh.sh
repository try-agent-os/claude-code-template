#!/usr/bin/env bash
#
# refresh.sh — proactively refresh the Claude CLI OAuth token so it NEVER
# expires silently (root cause of periodic operator/worker logouts:
# "org disabled Claude Code" == stale token).
#
# The Claude CLI app credential store lives in a single canonical file:
#   /home/agent-os/.claude/.credentials.json
# operator + heartbeat config dirs symlink to it; dispatcher should too
# (see setup.sh). The CLI watches this file's mtime and reloads creds when
# it changes, and it always re-reads the file before doing its own refresh —
# so an external single-writer refresher that atomically replaces the file is
# safe even for long-lived processes (the running operator picks up the new
# token automatically).
#
# Token life observed: ~8h from /login. We refresh proactively when the token
# has less than $OAUTH_REFRESH_SKEW_SEC left (default 2h), or always with
# --force. The systemd timer ticks hourly; threshold logic means we touch the
# token endpoint only near expiry (avoids needless refresh-token rotation and
# the IP rate-limit on platform.claude.com).
#
# Refresh contract reverse-engineered from cli.js 2.1.158:
#   POST https://platform.claude.com/v1/oauth/token
#   headers: Content-Type: application/json, anthropic-beta: oauth-2025-04-20
#   body:    {grant_type, refresh_token, client_id}
#   resp:    {access_token, refresh_token, expires_in, scope?}
#   expiresAt(ms) = now_ms + expires_in*1000   (refresh_token rotates)
#
# Usage:
#   refresh.sh            # refresh only if within SKEW of expiry (timer mode)
#   refresh.sh --force    # always refresh (manual / verification)
#
set -euo pipefail

CRED="${OAUTH_CRED_FILE:-/home/agent-os/.claude/.credentials.json}"
LOG="${OAUTH_REFRESH_LOG:-/var/log/agent-os/oauth-refresh.log}"
LOCK="${OAUTH_REFRESH_LOCK:-/home/agent-os/.claude/.oauth-refresh.lock}"
SKEW_SEC="${OAUTH_REFRESH_SKEW_SEC:-7200}"          # refresh when <2h to expiry
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
BETA="oauth-2025-04-20"

FORCE=0
[[ "${1:-}" == "--force" || "${1:-}" == "-f" ]] && FORCE=1

mkdir -p "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---- single writer -------------------------------------------------------
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another refresh is running (lock held); exiting"
  exit 0
fi

[[ -f "$CRED" ]] || die "credentials file not found: $CRED"
command -v jq  >/dev/null || die "jq not found"
command -v curl >/dev/null || die "curl not found"

now_ms=$(( $(date +%s) * 1000 ))

REFRESH_TOKEN=$(jq -r '.claudeAiOauth.refreshToken // empty' "$CRED")
OLD_EXP=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CRED")
[[ -n "$REFRESH_TOKEN" ]] || die "no claudeAiOauth.refreshToken in $CRED (needs manual /login)"

# ---- threshold gate ------------------------------------------------------
remaining_ms=$(( OLD_EXP - now_ms ))
if [[ "$FORCE" -ne 1 ]]; then
  if (( remaining_ms > SKEW_SEC * 1000 )); then
    log "token valid for $(( remaining_ms / 60000 ))m (> ${SKEW_SEC}s skew); skip (use --force to override)"
    exit 0
  fi
fi
log "refreshing (force=$FORCE, remaining=$(( remaining_ms / 60000 ))m, expiresAt=$OLD_EXP)"

# ---- call token endpoint -------------------------------------------------
REQ=$(jq -nc --arg rt "$REFRESH_TOKEN" --arg cid "$CLIENT_ID" \
  '{grant_type:"refresh_token", refresh_token:$rt, client_id:$cid}')

HTTP_BODY=$(mktemp)
trap 'rm -f "$HTTP_BODY"' EXIT
CODE=$(curl -s -o "$HTTP_BODY" -w '%{http_code}' --max-time 30 \
  -X POST "$TOKEN_URL" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: $BETA" \
  -H "User-Agent: agent-os-oauth-refresher/1.0" \
  -d "$REQ" || echo "000")

if [[ "$CODE" != "200" ]]; then
  ERR=$(jq -r '.error // .error_description // empty' "$HTTP_BODY" 2>/dev/null || true)
  die "token endpoint returned HTTP $CODE${ERR:+ ($ERR)} — credentials untouched"
fi

NEW_ACCESS=$(jq -r '.access_token // empty' "$HTTP_BODY")
NEW_REFRESH=$(jq -r '.refresh_token // empty' "$HTTP_BODY")
EXPIRES_IN=$(jq -r '.expires_in // empty' "$HTTP_BODY")
NEW_SCOPE=$(jq -r 'if (.scope|type=="string") then .scope else empty end' "$HTTP_BODY")

[[ -n "$NEW_ACCESS" ]] || die "response missing access_token — credentials untouched"
[[ "$EXPIRES_IN" =~ ^[0-9]+$ ]] || die "response expires_in not numeric ('$EXPIRES_IN') — credentials untouched"
# refresh_token may be absent on some grants; fall back to the one we sent
[[ -n "$NEW_REFRESH" ]] || NEW_REFRESH="$REFRESH_TOKEN"

NEW_EXP=$(( now_ms + EXPIRES_IN * 1000 ))

# ---- atomic write, preserving mcpOAuth & all other fields ----------------
TMP=$(mktemp "$(dirname "$CRED")/.cred.XXXXXX")
trap 'rm -f "$HTTP_BODY" "$TMP"' EXIT

JQ_ARGS=(--arg at "$NEW_ACCESS" --arg rt "$NEW_REFRESH" --argjson exp "$NEW_EXP")
JQ_FILTER='.claudeAiOauth.accessToken=$at | .claudeAiOauth.refreshToken=$rt | .claudeAiOauth.expiresAt=$exp'
if [[ -n "$NEW_SCOPE" ]]; then
  JQ_ARGS+=(--argjson scopes "$(jq -nc --arg s "$NEW_SCOPE" '$s|split(" ")')")
  JQ_FILTER+=' | .claudeAiOauth.scopes=$scopes'
fi

jq "${JQ_ARGS[@]}" "$JQ_FILTER" "$CRED" > "$TMP" || die "jq failed to build new credentials"
jq -e '.claudeAiOauth.accessToken and .claudeAiOauth.expiresAt' "$TMP" >/dev/null \
  || die "sanity check failed on new credentials — not installing"

chmod 600 "$TMP"
mv -f "$TMP" "$CRED"   # atomic: new inode + mtime -> running CLI reloads

log "OK: expiresAt $OLD_EXP -> $NEW_EXP ($(date -u -d "@$(( NEW_EXP / 1000 ))" +%Y-%m-%dT%H:%M:%SZ), +${EXPIRES_IN}s)"
exit 0
