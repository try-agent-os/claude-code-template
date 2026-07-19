#!/bin/bash
# operator-watchdog.sh — detect a dead/hung operator and restart it.
#
# Independent signals:
#   (A) messages.db gap: last incoming Telegram message is newer than the last
#       outgoing reply and the gap exceeds THRESHOLD_MIN. Catches "operator
#       took the message but never answered".
#   (B) tmux pane content: claude TUI is missing or showing a failure mode
#       (no session at all, bash prompt instead of TUI, "weekly limit" banner,
#       unhandled dev-channels dialog). Catches "operator crashed silently
#       and systemd's tmux-server-still-alive heuristic thinks it's fine".
#   (D) transcript inactivity: the live transcript hasn't been touched for
#       INACTIVITY_MIN (the session sat idle), AND the context is above a floor
#       so a restart actually buys a cheaper/cleaner window. Recycles a stale
#       warm session before it lingers into a bloated one.
#   (C) context-bloat: the live transcript's token-% or raw byte size crossed a
#       threshold (degraded tool-call emission) — restart for a fresh window.
#   (E) stuck-composer nudge: text sits in the TUI composer unsubmitted while
#       the session is idle — re-submit it instead of restarting.
#
# Order: crash signals (B) first (a dead pane needs a restart regardless of
# anything else), then the composer nudge (E), then the proactive transcript
# signals (D inactivity, then C bloat — both read from the same single
# context-usage.sh call), then the message-gap signal (A) last.
#
# Alerts go through scripts/notify-operator.sh (which itself falls back to
# the telegram-mcp /emergency endpoint, then api.telegram.org direct, so
# the path survives even if the operator pane is what's dead).
#
# Run periodically via a scheduler (systemd timer, cron, DAG). Cooldown
# prevents restart loops if the issue is structural.

set -uo pipefail

# Self-locating default: the script lives at <repo>/scripts/, the telegram
# plugin DB at <repo>/plugins/telegram/. A hardcoded install path silently
# breaks every non-default layout (alternative INSTALL_ROOT, worktrees).
_WD_REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DB="${OPERATOR_WATCHDOG_DB:-$_WD_REPO/plugins/telegram/messages.db}"
THRESHOLD_MIN="${OPERATOR_WATCHDOG_THRESHOLD_MIN:-15}"
COOLDOWN_MIN="${OPERATOR_WATCHDOG_COOLDOWN_MIN:-20}"
LOG_DIR="${OPERATOR_WATCHDOG_LOG_DIR:-/var/log/agent-os}"
LOG_FILE="${OPERATOR_WATCHDOG_LOG:-$LOG_DIR/operator-watchdog.log}"
STATE_FILE="${OPERATOR_WATCHDOG_STATE_FILE:-/var/lib/agent-os/operator-watchdog.last-restart}"
DEDUP_FLAG="${OPERATOR_DEDUP_FLAG:-/var/lib/agent-os/operator-restarted-since-last-msg.flag}"
# Optional: the Telegram chat id of the user this operator serves. No default —
# every code path that needs it degrades gracefully (skips, logs one line) when
# it is empty, so the watchdog is fully usable without configuring it.
CHAT_ID="${OPERATOR_CHAT_ID:-}"
# SERVICE / TMUX_SESSION are env-overridable so the SAME script drives
# per-instance watchdogs (per-instance operators). Override via the
# per-instance systemd unit rather than editing this file.
SERVICE="${OPERATOR_SERVICE:-agent-os-operator.service}"
TMUX_SESSION="${OPERATOR_TMUX_SESSION:-operator}"
# Derive the operator run user from the unit itself — installs differ in which
# unix user runs the operator. Hardcoding one user makes every tmux/pane check a
# silent no-op when the host diverges (observed failure: operator died, watchdog
# probed the wrong user's socket). Override: OPERATOR_AGENT_USER.
AGENT_USER="${OPERATOR_AGENT_USER:-$(systemctl show -p User --value "$SERVICE" 2>/dev/null)}"
[ -n "$AGENT_USER" ] || AGENT_USER=agent-os
AGENT_UID=$(id -u "$AGENT_USER" 2>/dev/null || echo 997)
AGENT_HOME=$(getent passwd "$AGENT_USER" 2>/dev/null | cut -d: -f6)
TMUX_SOCKET_DIR="${TMUX_TMPDIR:-${AGENT_HOME:-$HOME}/.tmux}"
TMUX_SOCKET="$TMUX_SOCKET_DIR/tmux-$AGENT_UID/default"

# Alert-once latch for the subscription-limit branch (see the block below).
# Keyed by SERVICE so per-instance watchdogs latch independently. Defined here —
# after SERVICE — so per-instance overrides land in the filename.
LIMIT_LATCH="${OPERATOR_WATCHDOG_LIMIT_LATCH:-/var/lib/agent-os/notify-dedup/limit-latched-$SERVICE}"
LIMIT_REMIND_MIN="${OPERATOR_WATCHDOG_LIMIT_REMIND_MIN:-180}"  # re-alert at most once per 3h while limited (0=never remind)

# (E) stuck-composer nudge knobs. State dir holds one small file per watched
# session ("<md5-of-text> <first-seen-epoch>") so we can measure how long the
# SAME composer text has been sitting unsubmitted across ticks.
NUDGE_STATE_DIR="${OPERATOR_WATCHDOG_NUDGE_STATE_DIR:-/var/lib/agent-os/operator-watchdog-nudge}"
STUCK_MIN="${OPERATOR_WATCHDOG_STUCK_MIN:-3}"                # minutes before we nudge
# Extra sessions to watch for stuck composers, as an ERE matched against
# `tmux list-sessions` names (e.g. '^myinstance-user-' on an isolated instance).
NUDGE_EXTRA_RE="${OPERATOR_WATCHDOG_NUDGE_EXTRA:-}"

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$LIMIT_LATCH")" "$NUDGE_STATE_DIR"

log() {
  printf '%s %s\n' "$(date -u -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

NOTIFY="${OPERATOR_NOTIFY_SCRIPT:-$_WD_REPO/scripts/notify-operator.sh}"
alert() {
  local sev="$1"; shift
  local msg="$*"
  if [ -x "$NOTIFY" ]; then
    if [ -n "$CHAT_ID" ]; then
      OPERATOR_CHAT_ID="$CHAT_ID" "$NOTIFY" --source operator-watchdog --severity "$sev" --msg "$msg" || true
    else
      "$NOTIFY" --source operator-watchdog --severity "$sev" --msg "$msg" || true
    fi
  fi
}

[ -n "$CHAT_ID" ] || log "note: OPERATOR_CHAT_ID is unset — alerts use notify-operator.sh defaults only"

# Returns 0 (true) if a restart is allowed right now (cooldown elapsed).
restart_allowed() {
  local now_epoch="$1"
  if [ ! -f "$STATE_FILE" ]; then return 0; fi
  local last_restart since_min
  last_restart=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  since_min=$(( (now_epoch - last_restart) / 60 ))
  [ "$since_min" -ge "$COOLDOWN_MIN" ]
}

do_restart() {
  local reason="$1" now_epoch="$2"
  log "RESTART triggered: $reason"
  if sudo systemctl restart "$SERVICE"; then
    echo "$now_epoch" > "$STATE_FILE"
    # Set the shared dedup flag after ANY restart so the next idle/gap tick is
    # gated until the user breaks silence (update-msg-epoch.sh clears it on a
    # fresh IN). Crash/bloat (B/C) restart unconditionally, but they too leave
    # the flag so they don't re-churn an idle session on the following ticks.
    # Only churn-by-idle signals (D inactivity, A gap) READ the flag to skip.
    : > "$DEDUP_FLAG" 2>/dev/null || true
    chown "$AGENT_USER":"$AGENT_USER" "$DEDUP_FLAG" 2>/dev/null || true
    chmod 644 "$DEDUP_FLAG" 2>/dev/null || true
    log "restarted $SERVICE successfully ($reason); dedup flag set at $DEDUP_FLAG"
    alert warn "operator restarted: $reason"
    return 0
  else
    local rc=$?
    log "ERROR: systemctl restart $SERVICE failed (exit $rc, reason=$reason)"
    alert error "operator restart FAILED (exit $rc, reason=$reason)"
    return 1
  fi
}

# operator_busy — true (0) if the operator has a live sub-agent in flight, so a
# proactive (non-crash) restart would kill real work. The Agent/Task tool forks
# a child `claude` (the operator's own MCP children are node/bun), so 2+ claude
# processes inside the service cgroup means a sub-agent is running. Host-agnostic
# (cgroup v2 procs are world-readable, whichever user the unit runs as).
# Unreadable cgroup → not busy (conservative: allow the restart).
operator_busy() {
  local procs="/sys/fs/cgroup/system.slice/${SERVICE}/cgroup.procs" pid n=0
  [ -r "$procs" ] || return 1
  while read -r pid; do
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "claude" ] && n=$((n + 1))
  done < "$procs"
  [ "$n" -ge 2 ]
}

NOW=$(date -u +%s)

# --- (E) stuck-composer helpers ----------------------------------------------
# A message injected into the claude TUI composer from outside Telegram (e.g. via
# a remote-control UI) can fail to auto-submit and sit for hours while the
# session idles. The pane then shows a non-empty composer line ("❯ <text>") with
# no active spinner. Root cause quirk: the rendered text can be a PHANTOM — the
# real input buffer is EMPTY, so a bare `send-keys Enter` no-ops. The reliable
# recovery is to RETYPE the visible text literally and send a separate Enter. We
# still try a bare Enter first: if the buffer is real, that alone submits and
# retyping would have duplicated the text.
_pane_composer_text() {  # stdin: pane capture → the current composer text ('' if empty)
  grep -a '^❯' | tail -1 | sed -e 's/^❯[[:space:]]*//' -e 's/[[:space:]]*$//'
}

_pane_is_busy() {  # stdin: pane capture → 0 if a live spinner is on screen
  # Busy spinner renders as "✽ Verbing…" or "✽ Verbing… (41s · ↓ 1.2k tokens)".
  # Idle summaries ("✻ Baked for 5m 55s") have no ellipsis and do NOT match.
  grep -qE '^[^[:space:]]+ [[:upper:]][[:alpha:]]+… *(\(|$)'
}

nudge_stuck_composer() {
  local sess="$1" pane txt sig state prev_sig="" first="" cur stuck_min
  pane=$(sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" capture-pane -t "$sess" -p 2>/dev/null) || return 0
  state="$NUDGE_STATE_DIR/${SERVICE}--${sess}.state"
  # Busy session: typed-but-unsubmitted text may be a legit queued draft and the
  # turn in flight will redraw anyway — reset tracking, check again when idle.
  if printf '%s\n' "$pane" | _pane_is_busy; then
    rm -f "$state" 2>/dev/null || true
    return 0
  fi
  txt=$(printf '%s\n' "$pane" | _pane_composer_text)
  if [ -z "$txt" ]; then
    rm -f "$state" 2>/dev/null || true
    return 0
  fi
  sig=$(printf '%s' "$txt" | md5sum | cut -d' ' -f1)
  [ -f "$state" ] && read -r prev_sig first < "$state" 2>/dev/null
  if [ "$prev_sig" != "$sig" ] || ! [[ "${first:-}" =~ ^[0-9]+$ ]]; then
    printf '%s %s\n' "$sig" "$NOW" > "$state" 2>/dev/null || true
    return 0
  fi
  stuck_min=$(( (NOW - first) / 60 ))
  [ "$stuck_min" -ge "$STUCK_MIN" ] || return 0
  log "STUCK-COMPOSER: $sess idle with unsubmitted composer ${stuck_min}min ('$(printf '%.60s' "$txt")') — nudging"
  # Step 1: bare Enter (submits a REAL buffer).
  sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" send-keys -t "$sess" Enter 2>/dev/null || true
  sleep 2
  cur=$(sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" capture-pane -t "$sess" -p 2>/dev/null | _pane_composer_text)
  if [ "$cur" = "$txt" ]; then
    # Step 2: composer unchanged → phantom render, buffer empty. Retype + Enter.
    sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" send-keys -t "$sess" -l "$txt" 2>/dev/null || true
    sleep 0.5
    sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" send-keys -t "$sess" Enter 2>/dev/null || true
    log "STUCK-COMPOSER: $sess bare Enter was a no-op (phantom buffer) — retyped text + Enter"
  else
    log "STUCK-COMPOSER: $sess submitted via bare Enter"
  fi
  rm -f "$state" 2>/dev/null || true
}

# --- (B) tmux pane content checks --------------------------------------------
# Capture the operator pane. Use explicit -S socket path because sudo env_reset
# strips TMUX_TMPDIR — without -S, tmux connects to /tmp default socket which
# may be a different server than where the operator session lives.
PANE_OUT=$(sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" capture-pane -t "$TMUX_SESSION" -p 2>&1 || true)

if echo "$PANE_OUT" | grep -qE "can't find session|can't find pane|no server running"; then
  log "PANE: no operator tmux session ($PANE_OUT)"
  if restart_allowed "$NOW"; then
    do_restart "no tmux session: $(printf '%s' "$PANE_OUT" | head -c 100)" "$NOW"
    exit 0
  else
    log "no-session detected but in cooldown — alert only"
    alert error "operator tmux session missing, in cooldown — manual check required"
    exit 0
  fi
fi

# Weekly limit hit — restart won't help, escalate and bail.
# Alert-ONCE via a latch: alert only on the TRANSITION into the limit state, then
# stay silent while it persists (a restart cannot help — quota must reset).
# Without the latch this branch re-alerted on every tick (observed: 19 identical
# messages over three hours). A soft reminder re-fires at most once per
# LIMIT_REMIND_MIN so a long outage still resurfaces without spamming. The latch
# is cleared right below once the pane no longer shows the limit, so the NEXT
# incident alerts afresh.
# Pattern requires "... limit reached" — the phrasing of the REAL blocked-state
# banner ("Weekly limit reached ∙ resets ...", "usage limit reached"). A bare
# "weekly limit" also matches the benign startup notice ("... is included in your
# weekly limit ...") shown at the TOP of every fresh session, which produced
# false alerts right after each restart. Only the BOTTOM of the pane is checked:
# the info notice sits at the top of the screen, while the real limit state
# renders next to the input box.
PANE_TAIL=$(printf '%s\n' "$PANE_OUT" | tail -n 15)
if echo "$PANE_TAIL" | grep -qiE "(weekly|usage|5-hour|session) limit reached"; then
  if [ ! -f "$LIMIT_LATCH" ]; then
    log "PANE: subscription limit reached (first detection) — alerting once, NOT restarting"
    alert error "operator hit subscription limit — message delivery is offline until quota resets (see pane)"
    : > "$LIMIT_LATCH" 2>/dev/null || true
  else
    LATCH_AGE_MIN=$(( (NOW - $(stat -c %Y "$LIMIT_LATCH" 2>/dev/null || echo "$NOW")) / 60 ))
    if [ "$LIMIT_REMIND_MIN" -gt 0 ] && [ "$LATCH_AGE_MIN" -ge "$LIMIT_REMIND_MIN" ]; then
      log "PANE: subscription limit still active after ${LATCH_AGE_MIN}min — periodic reminder"
      alert error "operator STILL at subscription limit (~${LATCH_AGE_MIN}min) — message delivery offline until quota resets"
      : > "$LIMIT_LATCH" 2>/dev/null || true  # refresh mtime → next reminder in another window
    else
      log "PANE: subscription limit still active (latch present, ~${LATCH_AGE_MIN}min) — staying silent"
    fi
  fi
  exit 0
fi

# Pane no longer shows the limit — reset the alert-once latch so a FUTURE incident
# re-alerts. Only logs when it actually removes a latch (avoids per-tick noise).
if [ -f "$LIMIT_LATCH" ]; then
  rm -f "$LIMIT_LATCH" 2>/dev/null || true
  log "subscription-limit latch cleared (operator no longer at limit)"
fi

# Dev-channels dialog still on screen — auto-dismiss (ExecStartPost) failed.
# Don't restart; instead try sending Enter via tmux send-keys to advance it.
if echo "$PANE_OUT" | grep -qE "Loading development channels|I am using this for local development"; then
  log "PANE: dev-channels dialog visible — re-sending Enter"
  sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" C-m 2>/dev/null || true
  # No restart; next cycle will verify it cleared.
  exit 0
fi

# Bash prompt instead of claude TUI — claude exited inside the session.
# Heuristic: last non-empty line of the pane looks like a shell prompt.
LAST_LINE=$(printf '%s' "$PANE_OUT" | awk 'NF' | tail -1)
if echo "$LAST_LINE" | grep -qE '[#$%>]\s*$' && ! echo "$PANE_OUT" | grep -q "Claude Code"; then
  log "PANE: looks like a shell prompt, claude TUI is gone (last_line='$LAST_LINE')"
  if restart_allowed "$NOW"; then
    do_restart "claude TUI exited (shell prompt visible)" "$NOW"
    exit 0
  else
    alert error "claude exited inside operator pane but in cooldown — manual check"
    exit 0
  fi
fi

# --- (E) stuck-composer nudge -------------------------------------------------
# TUI is confirmed alive at this point. Watch the operator session itself plus
# any extra sessions matching OPERATOR_WATCHDOG_NUDGE_EXTRA (per-user sessions on
# isolated instances). Nudging never restarts anything — worst case a no-op.
NUDGE_LIST="$TMUX_SESSION"
if [ -n "$NUDGE_EXTRA_RE" ]; then
  NUDGE_EXTRA_LIST=$(sudo -u "$AGENT_USER" tmux -S "$TMUX_SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -E "$NUDGE_EXTRA_RE" || true)
  [ -n "$NUDGE_EXTRA_LIST" ] && NUDGE_LIST="$NUDGE_LIST
$NUDGE_EXTRA_LIST"
fi
while IFS= read -r _nudge_sess; do
  [ -n "$_nudge_sess" ] && nudge_stuck_composer "$_nudge_sess"
done <<< "$NUDGE_LIST"

# --- transcript signals: read context-usage.sh ONCE, reuse for (D) and (C) ---
# context-usage.sh prints "<pct> <used> <window> <bytes> <mtime_epoch>" from the
# live transcript jsonl. Both proactive signals below derive from this one call.
CTX_USAGE="${OPERATOR_WATCHDOG_CTX_USAGE:-$_WD_REPO/scripts/operator-autocompact/context-usage.sh}"
CTX_RESTART_PCT="${OPERATOR_WATCHDOG_CTX_PCT:-55}"
CTX_MAX_BYTES="${OPERATOR_WATCHDOG_MAX_BYTES:-18874368}"  # 18 MiB
# Inactivity (D) knobs.
INACTIVITY_MIN="${OPERATOR_WATCHDOG_INACTIVITY_MIN:-90}"          # idle minutes to trip
INACTIVITY_MIN_PCT="${OPERATOR_WATCHDOG_INACTIVITY_MIN_PCT:-15}"  # ctx floor (token %)
INACTIVITY_MIN_BYTES="${OPERATOR_WATCHDOG_INACTIVITY_MIN_BYTES:-5242880}"  # 5 MiB floor
if [ -x "$CTX_USAGE" ]; then
  read -r CTX_PCT CTX_USED _CTX_WIN CTX_BYTES CTX_MTIME < <("$CTX_USAGE" 2>/dev/null || echo "0 0 0 0 0")
  [[ "$CTX_PCT" =~ ^[0-9]+$ ]] || CTX_PCT=0
  [[ "${CTX_BYTES:-}" =~ ^[0-9]+$ ]] || CTX_BYTES=0
  [[ "${CTX_MTIME:-}" =~ ^[0-9]+$ ]] || CTX_MTIME=0
  CTX_MB=$(( CTX_BYTES / 1048576 ))

  # --- (D) transcript-inactivity check ---------------------------------------
  # A warm session can sit idle for a long stretch (the user stepped away)
  # without ever tripping (A) gap, (B) crash or (C) bloat. We recycle it so the
  # next interaction starts on a fresh, cheap window instead of resuming a stale
  # one. IDLE is measured by the transcript's OWN mtime (every message/tool-call
  # rewrites the .jsonl), NOT the systemd unit timestamp — claude can relaunch
  # inside the tmux pane without cycling the unit, so unit-age lies. Transcript
  # mtime can't lie that way.
  # Two guards keep this from churning needlessly:
  #   - idle >= INACTIVITY_MIN (default 90min — long enough to be sure it's a real
  #     idle stretch and not a mid-conversation pause; a 5-15min lull between
  #     replies is normal and must NOT trip),
  #   - AND context above a floor (pct>=15% OR bytes>=5MiB) — restarting a fresh,
  #     cheap, low-context session just to churn it would only burn the warm cache
  #     for no gain, so we leave young sessions alone.
  # mtime==0 means "no transcript" → nothing to measure, skip the block.
  # Anti-loop: on restart, boot writes the .jsonl immediately (SessionStart hook +
  # peer registration), so mtime becomes fresh and INACTIVE resets to ~0 — the
  # block can't re-fire on the session it just spawned (same continuity guarantee
  # block C relies on).
  if [ "$CTX_MTIME" -gt 0 ]; then
    INACTIVE_MIN=$(( (NOW - CTX_MTIME) / 60 ))
    [ "$INACTIVE_MIN" -lt 0 ] && INACTIVE_MIN=0
    CTX_ABOVE_FLOOR=0
    if [ "$CTX_PCT" -ge "$INACTIVITY_MIN_PCT" ] || { [ "$INACTIVITY_MIN_BYTES" -gt 0 ] && [ "$CTX_BYTES" -ge "$INACTIVITY_MIN_BYTES" ]; }; then
      CTX_ABOVE_FLOOR=1
    fi
    if [ "$INACTIVE_MIN" -ge "$INACTIVITY_MIN" ] && [ "$CTX_ABOVE_FLOOR" -eq 1 ]; then
      IDLE="inactive=${INACTIVE_MIN}min ctx=${CTX_PCT}% size=${CTX_MB}MB (thr ${INACTIVITY_MIN}min, floor ${INACTIVITY_MIN_PCT}% / $(( INACTIVITY_MIN_BYTES / 1048576 ))MB)"
      if [ -f "$DEDUP_FLAG" ]; then
        log "INACTIVE: $IDLE — dedup flag present (already restarted since the last incoming message), skip until the user writes"
      elif operator_busy; then
        log "INACTIVE: $IDLE — operator busy (live sub-agent), skip this tick"
      elif ! restart_allowed "$NOW"; then
        log "INACTIVE: $IDLE — in cooldown (${COOLDOWN_MIN}min), skip"
      else
        log "INACTIVE: $IDLE — restarting for a fresh context"
        do_restart "$IDLE" "$NOW"
        exit 0
      fi
    else
      log "inactivity ok: idle=${INACTIVE_MIN}min ctx=${CTX_PCT}% size=${CTX_MB}MB (thr ${INACTIVITY_MIN}min, floor ${INACTIVITY_MIN_PCT}% / $(( INACTIVITY_MIN_BYTES / 1048576 ))MB)"
    fi
  fi

  # --- (C) context-bloat check -----------------------------------------------
  # A long ACTIVE session never trips the (A) gap or (B) crash signals, yet its
  # context still grows until tool-call emission degrades and replies get silently
  # dropped. Restart on context FILL, measured directly from the live transcript
  # (context-usage.sh) — wall-clock age is a poor proxy (claude can relaunch
  # inside the tmux pane without cycling the systemd unit, so unit-age may be
  # hours while the conversation is fresh).
  #
  # TWO transcript signals, OR'd: token-% ALONE proved insufficient — a 26MB
  # transcript at only ~61% token fill already degraded tool-call emission and
  # never reached a 70% threshold, so a pct-only cut never fired. Big tool
  # RESULTS (file reads, command output, JSON) bloat the on-disk/in-memory
  # transcript far beyond the prompt token count that `usage` reports. So we ALSO
  # trip on raw transcript bytes (>=18 MB by default). Both share the
  # operator_busy gate (never kill a live sub-agent) and the cooldown. Continuity
  # is restored on boot by the SessionStart hook.
  # Override: OPERATOR_WATCHDOG_CTX_PCT, OPERATOR_WATCHDOG_MAX_BYTES.
  if [ "$CTX_PCT" -ge "$CTX_RESTART_PCT" ] || { [ "$CTX_MAX_BYTES" -gt 0 ] && [ "$CTX_BYTES" -ge "$CTX_MAX_BYTES" ]; }; then
    BLOAT="context-bloat pct=${CTX_PCT}% used=${CTX_USED} size=${CTX_MB}MB (thr ${CTX_RESTART_PCT}% / $(( CTX_MAX_BYTES / 1048576 ))MB)"
    # Idle-churn guard: an IDLE session freezes its transcript, so CTX stays
    # pinned at the same bloated value tick after tick. Restarting unconditionally
    # here means the relaunch resumes the SAME conversation, % never drops, and it
    # loops every cooldown window all night (observed: identical pct/used logged
    # ~30 times overnight). Mirror blocks A/D: if we already restarted since the
    # last incoming message (flag present) AND the transcript is idle (frozen
    # mtime >= INACTIVITY_MIN), another restart surfaces nothing — skip until the
    # user writes (which clears the flag) so an active bloated session still
    # recycles, but an idle one stops churning.
    BLOAT_IDLE_MIN=0
    [ "$CTX_MTIME" -gt 0 ] && BLOAT_IDLE_MIN=$(( (NOW - CTX_MTIME) / 60 ))
    [ "$BLOAT_IDLE_MIN" -lt 0 ] && BLOAT_IDLE_MIN=0
    if operator_busy; then
      log "BLOAT: $BLOAT — operator busy (live sub-agent), skip this tick"
    elif [ -f "$DEDUP_FLAG" ] && [ "$BLOAT_IDLE_MIN" -ge "$INACTIVITY_MIN" ]; then
      log "BLOAT: $BLOAT — session idle ${BLOAT_IDLE_MIN}min & dedup flag set (already restarted since the last incoming message) — skip churn until the user writes"
    elif ! restart_allowed "$NOW"; then
      log "BLOAT: $BLOAT — in cooldown (${COOLDOWN_MIN}min), skip"
    else
      log "BLOAT: $BLOAT — restarting for a fresh context"
      do_restart "$BLOAT" "$NOW"
      exit 0
    fi
  else
    log "ctx ok: ${CTX_PCT}% size=${CTX_MB}MB (thr ${CTX_RESTART_PCT}% / $(( CTX_MAX_BYTES / 1048576 ))MB)"
  fi
fi

# --- (A) messages.db gap check -----------------------------------------------
if [ ! -r "$DB" ]; then
  log "ERROR: cannot read $DB"
  exit 1
fi

# DB read via python3's sqlite3 module — no sqlite3 CLI dependency required.
# One read-only open returns both extremes tab-separated; empty on any failure.
# We parse the tab explicitly (not `read`) because created_at contains a space
# ("YYYY-MM-DD HH:MM:SS").
_GAP_LINE=$(python3 - "$DB" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db_path = sys.argv[1]
try:
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=2)
    li = con.execute("SELECT MAX(created_at) FROM messages WHERE direction='in'").fetchone()
    lo = con.execute("SELECT MAX(created_at) FROM messages WHERE direction='out'").fetchone()
    con.close()
    sys.stdout.write("%s\t%s" % (li[0] if li and li[0] else "", lo[0] if lo and lo[0] else ""))
except Exception:
    pass
PYEOF
)
LAST_IN="${_GAP_LINE%%$'\t'*}"
LAST_OUT="${_GAP_LINE#*$'\t'}"
[ "$LAST_OUT" = "$_GAP_LINE" ] && LAST_OUT=""

if [ -z "$LAST_IN" ]; then
  log "no incoming messages yet, skip"
  exit 0
fi

LAST_IN_EPOCH=$(date -u -d "$LAST_IN" +%s 2>/dev/null || echo 0)
LAST_OUT_EPOCH=$(date -u -d "${LAST_OUT:-1970-01-01 00:00:00}" +%s 2>/dev/null || echo 0)

if [ "$LAST_OUT_EPOCH" -ge "$LAST_IN_EPOCH" ]; then
  log "ok: last_out=$LAST_OUT is current with last_in=$LAST_IN"
  exit 0
fi

AGE_MIN=$(( (NOW - LAST_IN_EPOCH) / 60 ))

if [ "$AGE_MIN" -lt "$THRESHOLD_MIN" ]; then
  log "ok: unanswered for ${AGE_MIN}min (threshold ${THRESHOLD_MIN}min)"
  exit 0
fi

# Dedup-flag gate (anti-churn): if we already restarted since the last incoming
# message, a fresh restart won't surface anything new — the SessionStart hook
# already injected this unanswered IN on boot. Wait for the user to write again
# (which clears the flag via update-msg-epoch.sh) before allowing another
# gap-restart. This stops A from looping every cooldown window while the user
# stays silent.
if [ -f "$DEDUP_FLAG" ]; then
  log "HUNG: unanswered ${AGE_MIN}min but dedup flag present (already restarted since last IN) — skip until the user writes"
  exit 0
fi

if ! restart_allowed "$NOW"; then
  SINCE_MIN=$(( (NOW - $(cat "$STATE_FILE" 2>/dev/null || echo 0)) / 60 ))
  log "HUNG: unanswered ${AGE_MIN}min but last restart was ${SINCE_MIN}min ago (cooldown ${COOLDOWN_MIN}min) — skip"
  exit 0
fi

log "HUNG: last_in='$LAST_IN' no reply for ${AGE_MIN}min — restarting $SERVICE"
do_restart "no reply for ${AGE_MIN}min, last_in=${LAST_IN}" "$NOW"
