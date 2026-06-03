#!/usr/bin/env bash
# smoke-test.sh — end-to-end test of the operator silence-restart detector.
#
# Verifies the documented invariants without actually restarting the operator:
# the dry-run sentinel keeps systemctl untouched.
#
# Scenarios (each prints OK / FAIL):
#   1. Idle 20 min, no flag, dry-run → "DRY-RUN: would restart" logged.
#   2. Idle 20 min, flag present     → "DEDUP: flag present ... skip" logged.
#   3. Hook (update-msg-epoch.sh) on user IN → flag cleared, epoch updated.
#   4. Idle but user fresh           → "ok: silence=Xmin" logged.
#   5. Idle again (epoch backdated)  → "DRY-RUN: would restart" again.
#   6. Idle + BUSY (worker tmux)     → "BUSY: ... skip" logged, flag/cooldown
#                                      untouched.
#   7. Idle + NOT busy               → "DRY-RUN: would restart" (busy-guard
#                                      lets the restart path through).
#
# Restart-path scenarios (1, 5, 7) pass a non-matching WORKER_GLOB + a pane pid
# with no claude descendants ($$), so they stay deterministic even while real
# worker-* sessions / sub-agents are alive on the host during the test.
#
# Side effects (restored at exit):
#   - Forces the dry-run sentinel ON for the duration so systemctl is never
#     touched, then RESTORES the sentinel to its prior state on exit. If the
#     detector was live (sentinel absent) before the run, it is live again
#     after — running this test no longer silently disables production restart.
#   - Resets the dedup flag, epoch file, last-restart file.
#
# Config: requires OPERATOR_CHAT_ID, OPERATOR_AGENT_USER (default agent-os),
# and the agent user's tmux socket dir (TMUX_DIR below).

set -euo pipefail

REPO="${REPO_ROOT:-/opt/agent-os/claude}"
AGENT_USER="${OPERATOR_AGENT_USER:-agent-os}"
STATE_DIR=/var/lib/agent-os
EPOCH=$STATE_DIR/operator-last-user-msg-epoch
FLAG=$STATE_DIR/operator-restarted-since-last-msg.flag
LASTR=$STATE_DIR/operator-autocompact.last-compact
SENTINEL=$STATE_DIR/operator-autocompact.dry-run
LOG=/var/log/agent-os/operator-autocompact.log
SCRIPT="$REPO/scripts/operator-autocompact/detect-and-restart.sh"
HOOK="$REPO/agents/operator/.claude/hooks/update-msg-epoch.sh"
TG_DB="${OPERATOR_AUTOCOMPACT_TG_DB:-$REPO/plugins/telegram/messages.db}"
CHAT_ID="${OPERATOR_CHAT_ID:-}"

[[ $EUID -eq 0 ]] || { echo "must be root (sudo)"; exit 2; }
[[ -n "$CHAT_ID" ]] || { echo "set OPERATOR_CHAT_ID to run the smoke test"; exit 2; }

pass() { printf '  \e[32mOK\e[0m  %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; exit 1; }

last_log_line() { tail -1 "$LOG" 2>/dev/null; }

# Not-busy override env for restart-path scenarios: a glob that matches no real
# session + a pane pid ($$ = this test shell) whose descendant tree contains no
# `claude` process. Keeps scenarios 1/5/7 deterministic regardless of ambient
# worker-* sessions or operator sub-agents.
NOTBUSY=(AUTOCOMPACT_WORKER_GLOB='worker-smoke-nomatch-zzz-*' AUTOCOMPACT_OPERATOR_PANE_PID="$$")

TMUX_DIR="${OPERATOR_TMUX_TMPDIR:-/home/agent-os/.tmux}"

echo "== smoke-test start =="

# Remember the detector's live/dry-run posture so we can restore it. The test
# forces dry-run ON (so systemctl is never invoked); if the detector was LIVE
# (sentinel absent) we must remove the sentinel again on exit, otherwise this
# test would silently disable production restart.
SENTINEL_WAS_PRESENT=0
[[ -f "$SENTINEL" ]] && SENTINEL_WAS_PRESENT=1

restore_sentinel() {
  if [[ "$SENTINEL_WAS_PRESENT" -eq 0 ]]; then
    rm -f "$SENTINEL"
    echo "  (restored detector to LIVE mode — dry-run sentinel removed)"
  fi
}
trap restore_sentinel EXIT

# Setup: clean state + force dry-run for the test
rm -f "$EPOCH" "$FLAG" "$LASTR"
touch "$SENTINEL"

NOW=$(date -u +%s)
OLD=$(( NOW - 20 * 60 ))   # 20 min ago

echo
echo "Scenario 1: epoch 20min stale, dry-run, no flag, not busy → expect DRY-RUN log"
echo "$OLD" > "$EPOCH"
env AUTOCOMPACT_QUIET_START=0 AUTOCOMPACT_QUIET_END=0 "${NOTBUSY[@]}" "$SCRIPT" >/dev/null
L="$(last_log_line)"
[[ "$L" == *"DRY-RUN: would restart"* ]] && pass "log: $L" || fail "expected DRY-RUN, got: $L"

echo
echo "Scenario 2: dedup flag set → expect DEDUP skip"
touch "$FLAG"; chown "$AGENT_USER":"$AGENT_USER" "$FLAG" 2>/dev/null || true
AUTOCOMPACT_QUIET_START=0 AUTOCOMPACT_QUIET_END=0 "$SCRIPT" >/dev/null
L="$(last_log_line)"
[[ "$L" == *"DEDUP: flag present"* ]] && pass "log: $L" || fail "expected DEDUP, got: $L"

echo
echo "Scenario 3: UserPromptSubmit hook on fresh user IN → flag cleared + epoch updated"
LAST_DB="$(sqlite3 "$TG_DB" \
  "SELECT MAX(created_at) FROM messages WHERE chat_id=$CHAT_ID AND direction='in';" 2>/dev/null)"
LAST_DB_EPOCH="$(date -u -d "$LAST_DB" +%s 2>/dev/null || echo 0)"
AGE_SEC=$(( NOW - LAST_DB_EPOCH ))
# Expand fresh window so a stale db IN still counts (test fixture)
OPERATOR_USER_FRESH_SEC=$(( AGE_SEC + 120 )) \
  bash -c 'echo "{\"prompt\":\"test\"}" | '"$HOOK"
[[ ! -f "$FLAG" ]] && pass "flag cleared" || fail "flag still present"
[[ -s "$EPOCH" ]] && pass "epoch file written ($(cat "$EPOCH"))" || fail "epoch file empty/missing"

echo
echo "Scenario 4: fresh epoch (now) → expect 'ok: silence=Xmin'"
# Write a guaranteed-fresh epoch so silence < threshold and the detector exits
# at the threshold check. Deterministic regardless of the real messages.db IN
# age (scenario 3 already verified the hook writes a non-empty epoch) — and the
# threshold check returns before the busy guard, so ambient workers don't flake
# this assertion.
date -u +%s > "$EPOCH"
AUTOCOMPACT_QUIET_START=0 AUTOCOMPACT_QUIET_END=0 "$SCRIPT" >/dev/null
L="$(last_log_line)"
[[ "$L" == *"ok: silence="* ]] && pass "log: $L" || fail "expected ok-silence, got: $L"

echo
echo "Scenario 5: backdate epoch, not busy → expect another DRY-RUN: would restart"
echo "$OLD" > "$EPOCH"
env AUTOCOMPACT_QUIET_START=0 AUTOCOMPACT_QUIET_END=0 "${NOTBUSY[@]}" "$SCRIPT" >/dev/null
L="$(last_log_line)"
[[ "$L" == *"DRY-RUN: would restart"* ]] && pass "log: $L" || fail "expected DRY-RUN, got: $L"

echo
echo "Scenario 6: idle + BUSY (worker tmux session) → expect BUSY skip, flag/cooldown untouched"
rm -f "$FLAG" "$LASTR"
echo "$OLD" > "$EPOCH"
WSESS="worker-smoke-$$"
sudo -u "$AGENT_USER" env TMUX_TMPDIR="$TMUX_DIR" tmux new-session -d -s "$WSESS" 'sleep 120' 2>/dev/null || true
# WORKER_GLOB scoped to the fake session only (won't match real worker-* names).
# Pane pid forced to $$ so the busy verdict can only come from the worker path.
AUTOCOMPACT_QUIET_START=0 AUTOCOMPACT_QUIET_END=0 \
  AUTOCOMPACT_WORKER_GLOB='worker-smoke-*' AUTOCOMPACT_OPERATOR_PANE_PID="$$" \
  "$SCRIPT" >/dev/null
L="$(last_log_line)"
[[ "$L" == *"BUSY:"*"skip"* ]] && pass "log: $L" || fail "expected BUSY skip, got: $L"
[[ ! -f "$FLAG" ]]  && pass "dedup flag NOT created on busy skip" || fail "dedup flag was created on busy skip"
[[ ! -s "$LASTR" ]] && pass "last-restart NOT written on busy skip" || fail "last-restart written on busy skip"
sudo -u "$AGENT_USER" env TMUX_TMPDIR="$TMUX_DIR" tmux kill-session -t "$WSESS" 2>/dev/null || true

echo
echo "Scenario 7: idle + NOT busy → expect DRY-RUN: would restart (busy-guard passes through)"
rm -f "$FLAG" "$LASTR"
echo "$OLD" > "$EPOCH"
env AUTOCOMPACT_QUIET_START=0 AUTOCOMPACT_QUIET_END=0 "${NOTBUSY[@]}" "$SCRIPT" >/dev/null
L="$(last_log_line)"
[[ "$L" == *"DRY-RUN: would restart"* ]] && pass "log: $L" || fail "expected DRY-RUN, got: $L"

# Leave dry-run sentinel in place. Clean test artifacts.
rm -f "$EPOCH" "$FLAG" "$LASTR"
echo
echo "== smoke-test done — all scenarios passed =="
