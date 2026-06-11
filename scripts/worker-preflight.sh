#!/bin/bash
# worker-preflight.sh — global preflight gate before any worker spawn.
#
# Call this FIRST in any launcher/dispatcher tick, before picking a task.
# It checks basic infra availability — if something critical is dead, the
# whole tick should be skipped (exit 1) without spawning a worker, instead
# of spawning N workers that all hang or crash on the same dead dependency.
#
# Checks:
#   (a) settings.json is valid for every resolvable Claude config dir —
#       an invalid permission rule shows a blocking "Settings Warning"
#       dialog and EVERY headless worker hangs (see
#       scripts/validate-worker-settings.py for the exact failure mode).
#   (b) tmux is reachable (has-server or can create a session) — without
#       tmux no worker session can spawn.
#   (c) optional task-backend reachability hook: if WORKER_PREFLIGHT_CHECK_CMD
#       is set, it is run via `bash -c`; non-zero exit fails the preflight.
#       Example: WORKER_PREFLIGHT_CHECK_CMD='curl -fsS -m 10 http://127.0.0.1:3851/health'
#
# Any failure: stderr "preflight: skip tick — <reason>", exit 1.
# Caller semantics: a scheduled caller (cron/Dagu/systemd timer) should treat
# exit 1 as "skip this tick" and itself exit 0 — an infra blip must not paint
# the scheduler red; the next tick retries naturally. A manual/interactive
# caller may propagate the failure.
set -uo pipefail

REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VALIDATE_SETTINGS="$REPO/scripts/validate-worker-settings.py"
CONFIG_BASE="${CLAUDE_CONFIG_BASE:-/var/lib/agent-os/claude-config}"

_fail() {
  echo "preflight: skip tick — $*" >&2
  exit 1
}

# (a) settings.json valid — same probe order the launchers use.
if [ -f "$VALIDATE_SETTINGS" ]; then
  _candidates=""
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    _candidates="$CLAUDE_CONFIG_DIR"
  else
    for _c in "$CONFIG_BASE/heartbeat" "$CONFIG_BASE/dispatcher" \
              "$CONFIG_BASE/operator" "$HOME/.claude"; do
      [ -f "$_c/.claude.json" ] || [ -f "$_c/settings.json" ] || continue
      _candidates="$_candidates $_c"
    done
  fi
  for _dir in $_candidates; do
    if ! python3 "$VALIDATE_SETTINGS" "$_dir" 2>/dev/null; then
      _fail "invalid settings.json in ${_dir} (wildcard MCP rule / broken JSON) — all workers would hang"
    fi
  done
fi

# (b) tmux reachable
export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
if ! tmux ls >/dev/null 2>&1 && ! tmux new-session -d -s __preflight_probe__ >/dev/null 2>&1; then
  _fail "tmux server not accessible (TMUX_TMPDIR=$TMUX_TMPDIR)"
fi
# Remove the probe session if it was created.
tmux kill-session -t __preflight_probe__ 2>/dev/null || true

# (c) optional task-backend / dependency hook
if [ -n "${WORKER_PREFLIGHT_CHECK_CMD:-}" ]; then
  if ! bash -c "$WORKER_PREFLIGHT_CHECK_CMD" >/dev/null 2>&1; then
    _fail "WORKER_PREFLIGHT_CHECK_CMD failed (${WORKER_PREFLIGHT_CHECK_CMD}) — task backend unreachable, no point picking tasks"
  fi
fi

exit 0
