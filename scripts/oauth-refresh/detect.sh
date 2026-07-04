#!/usr/bin/env bash
#
# detect.sh — OAuth Phase 2 safety-net: drift detector + auto-fixer + actionable /login alert.
#
# Phase 1 (refresh.sh + agent-os-oauth-refresh.timer) keeps the *canonical* token
# alive by refreshing it before expiry. But it cannot see — and cannot fix — two
# failure modes that still take the whole worker layer down:
#
#   (A) DRIFT. The worker/operator config dirs
#         /var/lib/agent-os/claude-config/{operator,heartbeat,dispatcher}/.credentials.json
#       are supposed to be SYMLINKS to the canonical file
#         /home/agent-os/.claude/.credentials.json
#       If one becomes a *real file* (a stale copy), it pins an old access token.
#       When the refresher rotates the canonical token, the server invalidates the
#       old one, and that config dir starts returning 401 / "org disabled Claude
#       Code" — workers thrash every ~45 min. (This is exactly the 2026-05-31
#       incident: dispatcher had drifted to a real file.)  <- AUTO-FIXED here.
#
#   (B) DEAD CANONICAL. The canonical token is expired AND the refresher can't
#       renew it (refresh_token rejected / missing) — only a human `/login` fixes
#       it.  <- ALERT the admin here, with an actionable message.
#
# Design choices:
#   * Runs as a systemd timer next to the refresher (every ~7 min).
#   * Drift is repaired SILENTLY (relink to canonical) — no human needed for 90%
#     of incidents. The drifted file is backed up for forensics, then replaced.
#   * The alert is sent by a DIRECT Telegram Bot API call (TELEGRAM_BOT_TOKEN),
#     NOT via the operator peer relay. Rationale: the failure mode we alert on is
#     "the Claude OAuth token is dead" — in which the operator's own LLM session
#     is likely 401'd too and can't relay anything. The bot token is a separate
#     credential, unaffected by the OAuth outage, so the alert always lands.
#   * Alerts are deduped (cooldown + condition fingerprint) so a persistent dead
#     token nags at most once per OAUTH_ALERT_COOLDOWN_SEC, and a fresh /login
#     (which changes expiresAt) re-arms alerting automatically.
#
# Env overrides (used for testing against a sandbox; defaults are production):
#   OAUTH_CRED_FILE         canonical credentials file
#   OAUTH_CONFIG_BASE       base dir holding the per-agent config dirs
#   OAUTH_CONFIG_DIRS       space-separated list of config-dir names
#   OAUTH_REFRESH_SCRIPT    path to refresh.sh (called with --force on dead token)
#   OAUTH_DETECT_LOG        log file
#   OAUTH_DETECT_STATE      alert-dedup state file
#   OAUTH_WORKER_LOG_DIR    logs/workers root (for the 401-signature scan)
#   OAUTH_LOGIN_PIPE_LOG    /login pipe log (informational)
#   OAUTH_ALERT_CHAT_ID     Telegram chat id for the direct alert (unset => no
#                           direct alert; the condition is still logged)
#   OAUTH_ALERT_COOLDOWN_SEC  min seconds between repeat alerts for same condition
#   OAUTH_EXP_GRACE_SEC     treat token as dead this many secs before real expiry
#   OAUTH_DETECT_NO_ALERT=1 dry-run: log "[DRYRUN] would alert" instead of sending
#   AGENT_OS_ENV            env file holding TELEGRAM_BOT_TOKEN
#
# Usage:
#   detect.sh            # one tick (timer mode)
#
set -uo pipefail   # NOT -e: one sub-check failing must never abort the whole tick

CANON="${OAUTH_CRED_FILE:-/home/agent-os/.claude/.credentials.json}"
CONFIG_BASE="${OAUTH_CONFIG_BASE:-/var/lib/agent-os/claude-config}"
CONFIG_DIRS="${OAUTH_CONFIG_DIRS:-operator heartbeat dispatcher}"
REFRESH="${OAUTH_REFRESH_SCRIPT:-/opt/agent-os/claude/scripts/oauth-refresh/refresh.sh}"
LOG="${OAUTH_DETECT_LOG:-/var/log/agent-os/oauth-detect.log}"
STATE="${OAUTH_DETECT_STATE:-/home/agent-os/.claude/.oauth-detect.state}"
WORKER_LOG_DIR="${OAUTH_WORKER_LOG_DIR:-/opt/agent-os/claude/logs/workers}"
LOGIN_PIPE_LOG="${OAUTH_LOGIN_PIPE_LOG:-/var/log/agent-os/claude-login-pipe.log}"
ENV_FILE="${AGENT_OS_ENV:-/etc/agent-os/agent-os.env}"
ALERT_CHAT_ID="${OAUTH_ALERT_CHAT_ID:-}"
ALERT_COOLDOWN_SEC="${OAUTH_ALERT_COOLDOWN_SEC:-7200}"   # at most one nag / 2h per condition
EXP_GRACE_SEC="${OAUTH_EXP_GRACE_SEC:-300}"
WORKER_SCAN_WINDOW_MIN="${OAUTH_WORKER_SCAN_WINDOW_MIN:-20}"
NO_ALERT="${OAUTH_DETECT_NO_ALERT:-0}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }

now_s=$(date +%s)
now_ms=$(( now_s * 1000 ))

DRIFT_FIXED=0
ALERT_REASON=""        # non-empty => an alert condition was found
ALERT_KEY=""           # condition fingerprint for dedup

# Read the accessToken prefix (first 16 chars) at a path, resolving symlinks.
token_prefix() {
  local f="$1"
  [[ -e "$f" ]] || { echo ""; return; }
  jq -r '.claudeAiOauth.accessToken // empty' "$f" 2>/dev/null | cut -c1-16
}

# ---------------------------------------------------------------------------
# (A) DRIFT: ensure every config dir's .credentials.json is a symlink -> canonical
# ---------------------------------------------------------------------------
CANON_REAL="$(readlink -f "$CANON" 2>/dev/null || echo "$CANON")"
CANON_PREFIX="$(token_prefix "$CANON")"

for d in $CONFIG_DIRS; do
  link="$CONFIG_BASE/$d/.credentials.json"
  dir="$CONFIG_BASE/$d"
  [[ -d "$dir" ]] || { log "skip $d: config dir $dir does not exist"; continue; }

  # Guard: if this config-dir's credentials file resolves to the SAME path as the
  # canonical file, it IS the canonical — not a drifted copy. This is the hub
  # model (single real credentials file living inside the `server` config dir, no
  # symlink fan-out): CANON and link are literally the same path. Without this
  # guard the loop sees a "real-file, not symlink", backs it up (.drift-*.bak) and
  # tries `ln -sfn "$CANON" "$link"` onto itself, which fails every tick — an
  # infinite drift loop that filled the dir with ~200 .bak files (2026-06-04/05).
  link_real="$(readlink -f "$link" 2>/dev/null || echo "$link")"
  if [[ -n "$link_real" && "$link_real" == "$CANON_REAL" ]]; then
    continue
  fi

  target_real="$(readlink -f "$link" 2>/dev/null || echo "")"
  drifted=0
  why=""

  if [[ ! -e "$link" && ! -L "$link" ]]; then
    drifted=1; why="missing"
  elif [[ ! -L "$link" ]]; then
    # real file, not a symlink — the classic drift
    drifted=1; why="real-file (token=$(token_prefix "$link")…)"
  elif [[ "$target_real" != "$CANON_REAL" ]]; then
    # symlink, but to the wrong place
    drifted=1; why="symlink->$target_real (expected $CANON_REAL)"
  else
    # symlink resolves to canonical — but belt-and-suspenders: confirm the
    # effective token actually matches canonical (catches an exotic case where
    # the resolved file content somehow diverged).
    p="$(token_prefix "$link")"
    if [[ -n "$CANON_PREFIX" && -n "$p" && "$p" != "$CANON_PREFIX" ]]; then
      drifted=1; why="token-mismatch ($p… != $CANON_PREFIX…)"
    fi
  fi

  if [[ "$drifted" -eq 1 ]]; then
    # Back up any real file for forensics, then relink to canonical.
    if [[ -f "$link" && ! -L "$link" ]]; then
      bak="${link}.drift-$(date -u +%Y%m%dT%H%M%SZ).bak"
      cp -p "$link" "$bak" 2>/dev/null && log "AUTOFIX $d: backed up drifted file -> $bak"
    fi
    if ln -sfn "$CANON" "$link" 2>/dev/null; then
      DRIFT_FIXED=$(( DRIFT_FIXED + 1 ))
      log "AUTOFIX $d: relinked $link -> $CANON (was: $why)"
    else
      log "ERROR $d: failed to relink $link -> $CANON (was: $why)"
    fi
  fi
done

# ---------------------------------------------------------------------------
# (B) CANONICAL HEALTH: expired + un-refreshable => alert
# ---------------------------------------------------------------------------
if [[ ! -f "$CANON" ]]; then
  ALERT_REASON="canonical credentials file missing ($CANON)"
  ALERT_KEY="missing-canon"
else
  exp_ms="$(jq -r '.claudeAiOauth.expiresAt // 0' "$CANON" 2>/dev/null || echo 0)"
  has_refresh="$(jq -r '.claudeAiOauth.refreshToken // empty' "$CANON" 2>/dev/null)"
  [[ "$exp_ms" =~ ^[0-9]+$ ]] || exp_ms=0
  remaining_ms=$(( exp_ms - now_ms ))
  exp_human="$(date -u -d "@$(( exp_ms / 1000 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')"

  if [[ -z "$has_refresh" ]]; then
    ALERT_REASON="no refresh_token in canonical credentials — only a manual login can restore it"
    ALERT_KEY="no-refresh-token"
  elif (( remaining_ms < EXP_GRACE_SEC * 1000 )); then
    # Token is dead / about to die and the hourly refresher should already have
    # handled it. It didn't — try once more, hard. If that fails, the
    # refresh_token itself is rejected => human /login required.
    log "canonical token dead/near-dead (expiresAt=$exp_human, remaining=$(( remaining_ms / 1000 ))s) — forcing refresh"
    if OAUTH_CRED_FILE="$CANON" "$REFRESH" --force >>"$LOG" 2>&1; then
      new_exp="$(jq -r '.claudeAiOauth.expiresAt // 0' "$CANON" 2>/dev/null || echo 0)"
      if (( new_exp > now_ms )); then
        log "RECOVERED: forced refresh renewed token (expiresAt now $(date -u -d "@$(( new_exp / 1000 ))" +%Y-%m-%dT%H:%M:%SZ))"
        # Re-point CANON_REAL not needed; symlinks already correct.
      else
        ALERT_REASON="token expired ($exp_human) and forced refresh did not move expiry — refresh_token likely rejected"
        ALERT_KEY="refresh-failed-$exp_ms"
      fi
    else
      ALERT_REASON="token expired ($exp_human) and refresh.sh --force failed (endpoint rejected refresh_token)"
      ALERT_KEY="refresh-failed-$exp_ms"
    fi
  else
    log "canonical token healthy (expiresAt=$exp_human, $(( remaining_ms / 60000 ))m left)"
  fi
fi

# ---------------------------------------------------------------------------
# Corroborating signal (informational): recent worker 401 / "org disabled"
# ---------------------------------------------------------------------------
WORKER_401=0
if [[ -d "$WORKER_LOG_DIR" ]]; then
  # Only files touched recently, to avoid false positives from stale logs.
  while IFS= read -r f; do
    # Match the genuine API refusal ("your organization has disabled Claude
    # subscription access for Claude Code"), NOT casual incident-note mentions
    # like "org disabled Claude Code" that appear in worker discussion text.
    if grep -qiE 'organization has disabled|disabled .{0,40}subscription access' "$f" 2>/dev/null; then
      WORKER_401=$(( WORKER_401 + 1 ))
    fi
  done < <(find "$WORKER_LOG_DIR" -maxdepth 2 -name output.txt -mmin "-${WORKER_SCAN_WINDOW_MIN}" 2>/dev/null)
  [[ "$WORKER_401" -gt 0 ]] && log "signal: $WORKER_401 worker output(s) in last ${WORKER_SCAN_WINDOW_MIN}min show an auth-disabled refusal"
fi
[[ -n "$ALERT_REASON" && "$WORKER_401" -gt 0 ]] && ALERT_REASON="$ALERT_REASON; $WORKER_401 recent worker(s) hit 401"

# ---------------------------------------------------------------------------
# /login pipe — informational context only (last login)
# ---------------------------------------------------------------------------
if [[ -f "$LOGIN_PIPE_LOG" ]]; then
  last_login="$(grep 'submit: OK' "$LOGIN_PIPE_LOG" 2>/dev/null | tail -1 | awk '{print $1}')"
  [[ -n "$last_login" ]] && log "last successful /login: $last_login"
fi

# ---------------------------------------------------------------------------
# ALERT (deduped) — only when a human /login is actually required
# ---------------------------------------------------------------------------
send_alert() {
  local reason="$1" key="$2"

  # Dedup: same condition key within cooldown => suppress.
  if [[ -f "$STATE" ]]; then
    local prev_key prev_ts
    prev_key="$(sed -n '1p' "$STATE" 2>/dev/null)"
    prev_ts="$(sed -n '2p' "$STATE" 2>/dev/null)"
    [[ "$prev_ts" =~ ^[0-9]+$ ]] || prev_ts=0
    if [[ "$prev_key" == "$key" ]] && (( now_s - prev_ts < ALERT_COOLDOWN_SEC )); then
      log "alert suppressed (cooldown, $(( (ALERT_COOLDOWN_SEC - (now_s - prev_ts)) / 60 ))m left): $reason"
      return 0
    fi
  fi

  local text="⚠️ Claude CLI OAuth token dead/expiring: ${reason}. Run /login in this chat to re-authenticate — once the code is entered the operator and all workers recover."

  # No direct-alert target configured (OAUTH_ALERT_CHAT_ID unset) — the condition
  # is already logged above; just record state so the dedup window still applies.
  if [[ -z "$ALERT_CHAT_ID" ]]; then
    log "no OAUTH_ALERT_CHAT_ID set — condition logged only (reason: $reason)"
    printf '%s\n%s\n%s\n' "$key" "$now_s" "$reason" > "$STATE"
    return 0
  fi

  if [[ "$NO_ALERT" == "1" ]]; then
    log "[DRYRUN] would alert chat $ALERT_CHAT_ID: $reason"
  else
    local tok=""
    [[ -f "$ENV_FILE" ]] && tok="$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"')"
    if [[ -z "$tok" ]]; then
      log "ERROR: cannot alert — no TELEGRAM_BOT_TOKEN in $ENV_FILE (reason was: $reason)"
      return 1
    fi
    if curl -s --max-time 10 "https://api.telegram.org/bot${tok}/sendMessage" \
         -d chat_id="$ALERT_CHAT_ID" \
         --data-urlencode text="$text" >/dev/null 2>&1; then
      log "ALERT sent to chat $ALERT_CHAT_ID: $reason"
    else
      log "ERROR: Telegram sendMessage failed (reason was: $reason)"
      return 1
    fi
  fi
  printf '%s\n%s\n%s\n' "$key" "$now_s" "$reason" > "$STATE"
}

if [[ -n "$ALERT_REASON" ]]; then
  send_alert "$ALERT_REASON" "$ALERT_KEY"
else
  # Condition is clear — drop any stale alert state so the next real outage
  # alerts immediately (and a /login that fixed things re-arms cleanly).
  [[ -f "$STATE" ]] && { rm -f "$STATE"; log "alert state cleared (token healthy)"; }
fi

log "tick done (drift_fixed=$DRIFT_FIXED, worker_401=$WORKER_401, alert=$([[ -n "$ALERT_REASON" ]] && echo yes || echo no))"
exit 0
