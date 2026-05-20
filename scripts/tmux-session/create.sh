#!/bin/bash
# create.sh — spawn a new detached tmux session, optionally with `claude` inside.
#
# Usage:
#   create.sh <session_name> [--cwd <path>]
#                            [--claude]
#                            [--model <model>]
#                            [--workspace <slug>]
#
# Behavior:
#   --claude            Start `claude` CLI in the session. Defaults model to
#                       claude-opus-4-7[1m] (1M context Opus 4.7) — override with
#                       --model. Without --claude, session opens a plain shell.
#   --cwd <path>        Working directory for the session. Default: $HOME.
#   --workspace <slug>  Shorthand: cwd = workspaces/<slug>/claude/ if exists,
#                       else workspaces/<slug>/. Implies --claude. Pre-fills the
#                       claude prompt with a brief workspace context note.
#   --model <model>     Override claude --model. Default: claude-opus-4-7[1m].
#
# Refuses to clobber existing session of same name (exit 2).
# Refuses reserved names (operator/sysadmin/dispatcher/claude-login) (exit 3).
#
# Output on success:
#   created: <session_name> pid=<pid>

source "$(dirname "$0")/_common.sh"

usage() {
  sed -n '2,20p' "$0" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage

SESSION_NAME="$1"
shift

CWD=""
WANT_CLAUDE=0
MODEL="claude-opus-4-7[1m]"
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)        CWD="${2:?--cwd needs a path}"; shift 2 ;;
    --claude)     WANT_CLAUDE=1; shift ;;
    --model)      MODEL="${2:?--model needs a value}"; shift 2 ;;
    --workspace)  WORKSPACE="${2:?--workspace needs a slug}"; shift 2 ;;
    *)            die "unknown arg: $1" ;;
  esac
done

# Validation.
[[ -z "$SESSION_NAME" ]] && die "session name required"
[[ "$SESSION_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "session name must be [A-Za-z0-9._-]+"
is_reserved_name "$SESSION_NAME" && { echo "ERROR: '$SESSION_NAME' is reserved (operator/sysadmin/dispatcher/claude-login)" >&2; exit 3; }

if tx_has "$SESSION_NAME"; then
  echo "ERROR: session '$SESSION_NAME' already exists" >&2
  exit 2
fi

# Resolve workspace shortcut.
PREFILL=""
if [[ -n "$WORKSPACE" ]]; then
  WS_DIR="$INSTALL_ROOT/workspaces/$WORKSPACE"
  [[ -d "$WS_DIR" ]] || die "workspace not found: $WS_DIR"
  if [[ -d "$WS_DIR/claude" ]]; then
    CWD="${CWD:-$WS_DIR/claude}"
  else
    CWD="${CWD:-$WS_DIR}"
  fi
  WANT_CLAUDE=1
  PREFILL="Context: you are a worker session for workspace '${WORKSPACE}'. Cwd: ${CWD}. Read CLAUDE.md before acting. Awaiting task."
fi

CWD="${CWD:-$HOME}"
[[ -d "$CWD" ]] || die "cwd not a directory: $CWD"

# Build inner command.
if [[ "$WANT_CLAUDE" -eq 1 ]]; then
  # Pass --dangerously-skip-permissions so the session is non-interactive-safe;
  # operator already runs with this flag in production. --model "<value>"
  # quoted via single-quotes inside the shell command we hand to tmux.
  INNER_CMD="claude --dangerously-skip-permissions --model '$MODEL'"
else
  # Plain interactive shell — bash by default.
  INNER_CMD="${SHELL:-/bin/bash} -l"
fi

# Create the session. -x/-y match wide capture-friendly geometry so wrapped
# lines don't break `read.sh` output.
if ! tx new-session -d -s "$SESSION_NAME" -c "$CWD" -x 220 -y 50 "$INNER_CMD"; then
  die "tmux new-session failed"
fi

# Find pid of the inner process (best-effort; tmux reports the pid of the
# pane's child via list-panes).
PID=$(tx list-panes -t "$SESSION_NAME" -F '#{pane_pid}' 2>/dev/null | head -1 || echo "?")

# If --workspace prefill present and claude is running, give claude a moment to
# initialize, then send the prefill as a primer message.
if [[ -n "$PREFILL" ]] && [[ "$WANT_CLAUDE" -eq 1 ]]; then
  # Wait for claude TUI to be ready. Crude poll for the prompt indicator.
  for _ in $(seq 1 15); do
    sleep 1
    if tx capture-pane -p -t "$SESSION_NAME" 2>/dev/null | grep -qE '(Try .*"|>|Welcome)'; then
      break
    fi
  done
  # Send the prefill text + submit. Claude TUI submit is C-m (not Enter —
  # Enter alone would print the text but not submit it).
  tx send-keys -t "$SESSION_NAME" -l "$PREFILL"
  tx send-keys -t "$SESSION_NAME" C-m
fi

log_activity "create | $SESSION_NAME | cwd=$CWD claude=$WANT_CLAUDE model=$MODEL workspace=${WORKSPACE:--}"
echo "created: $SESSION_NAME pid=$PID"
