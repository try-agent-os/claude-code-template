#!/bin/bash
# spawn-worker.sh — Launch an interactive Claude worker in a tmux session.
#
# Usage: ./spawn-worker.sh <task-id> <clickup-task-id> <prompt-file> [timeout-minutes] [model]
#
# The interactive-worker model: a real `claude` session runs in a detached tmux
# session with the prompt passed as a positional arg. The prompt ends with a
# /goal directive that drives completion — the goal evaluator decides each turn
# whether the worker is done. The worker self-terminates by calling /done or
# /blocked (see .claude/commands/{done,blocked}.md), which finalize the task in
# the task backend, notify the operator, and kill the worker's own tmux session.
#
# A hard wall-clock timeout is enforced EXTERNALLY by scripts/worker-supervisor.sh
# (Dagu routine, every minute): if a worker session outlives its cap the
# supervisor flips the task to a terminal state and kills the session.
#
# Why interactive (not `-p` / `--print`)?
#   1. Inbound claude-peers messages only surface in an interactive TTY session.
#   2. The owner can `tmux attach` and watch / inject input live.
#   3. `/goal` works the same way in interactive mode.

set -uo pipefail

TASK_ID="${1:?Usage: $0 <task-id> <clickup-task-id> <prompt-file> [timeout-minutes] [model]}"
CLICKUP_TASK_ID="${2:?Usage: $0 <task-id> <clickup-task-id> <prompt-file> [timeout-minutes] [model]}"
PROMPT_FILE="${3:?Usage: $0 <task-id> <clickup-task-id> <prompt-file> [timeout-minutes] [model]}"
TIMEOUT_MIN="${4:-45}"
MODEL="${5:-${DEFAULT_MODEL:-claude-sonnet-4-6}}"

# Shared tmux server across all AgentOS entry points (operator unit, Dagu
# routines, interactive shells). Without this, when spawned under Dagu/cron
# where TMUX_TMPDIR is unset, tmux defaults to /tmp/tmux-{uid}/default and the
# worker session lands on a separate server invisible to supervisor/operator.
export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# Bookkeeping (logs, activity log, git pull) always stays on the main repo.
WORK_DIR="$REPO_ROOT"
# Claude's launch cwd. Project-scoped slash commands and CLAUDE.md are only
# loaded from the cwd at startup. WORKER_WORK_DIR lets a launcher start the
# worker inside a submodule so those are available; default is the main repo.
LAUNCH_CWD="${WORKER_WORK_DIR:-$REPO_ROOT}"
CLAUDE="${CLAUDE:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
WORKER_DIR="${WORK_DIR}/logs/workers/${TASK_ID}"
SESSION_NAME="worker-${TASK_ID}"
# Per-spawn epoch — makes each worker's git branch unique (worker/<slug>-<epoch>)
# so parallel/sequential respawns of the SAME slug never share one remote branch
# and lose commits to a push-race / `-B` reset. The tmux SESSION_NAME and the
# worktree PATH stay slug-based (idempotency + the orphan GC maps
# session⇄worktree by slug); only the branch carries the epoch.
WORKER_EPOCH="$(date +%s)"
ACTIVITY_LOG_DIR="${WORK_DIR}/memory/worker-activity"
CLAUDE_CONFIG_BASE="${CLAUDE_CONFIG_BASE:-/var/lib/agent-os/claude-config}"
NOTIFY="${WORK_DIR}/scripts/notify-operator.sh"

# Optional extra environment threaded into the worker session. A worker's tmux
# session inherits ONLY the vars explicitly passed with `tmux -e` below, not a
# full env-file source — so any MCP server that reads a token from the process
# env (e.g. "${SOME_API_TOKEN}" expansion in .claude.json mcpServers) would
# start with an empty token unless the token is threaded in here. To pass extra
# vars, set WORKER_ENV_PASSTHROUGH to a space-separated list of var NAMES that
# are present in this launcher's environment; each is forwarded to the worker.
WORKER_ENV_PASSTHROUGH="${WORKER_ENV_PASSTHROUGH:-}"

# Idempotency: skip if a worker with this slug is already running.
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "SKIP: worker $SESSION_NAME already running" >&2
  exit 0
fi

# Apply the dev-channels patch idempotently. Without it, the FIRST start after a
# Claude Code auto-update blocks on a "Loading development channels" prompt that
# needs an Enter key — no good for a headless launcher.
[ -f "${WORK_DIR}/scripts/ensure-dev-channels-patch.py" ] && \
  python3 "${WORK_DIR}/scripts/ensure-dev-channels-patch.py" 2>&1 | tail -1 >&2 || true

# Ensure the claude-peers plugin's deps are present (its node_modules is
# .gitignored and can be wiped by `git clean -fdx`). Optional — safe no-op if the
# helper is absent (a template checkout without the peers plugin still spawns).
[ -x "${WORK_DIR}/scripts/ensure-claude-peers-deps.sh" ] && \
  bash "${WORK_DIR}/scripts/ensure-claude-peers-deps.sh" 2>&1 | tail -1 >&2 || true

# Create worker directory (clean previous run).
rm -rf "$WORKER_DIR"
mkdir -p "$WORKER_DIR"
mkdir -p "$ACTIVITY_LOG_DIR"

# Copy prompt into worker dir (audit trail + visible from tmux pane via cat).
cp "$PROMPT_FILE" "$WORKER_DIR/prompt.md"
echo "$CLICKUP_TASK_ID" > "$WORKER_DIR/clickup-task-id"
echo "$MODEL" > "$WORKER_DIR/model"
date +%s > "$WORKER_DIR/started-at"
# Per-worker wall-clock cap (minutes) — worker-supervisor.sh reads this instead
# of its global default, so a "Timeout: NN" line in the task desc is honored.
echo "$TIMEOUT_MIN" > "$WORKER_DIR/timeout-min"

# Best-effort git pull to pick up changes from other workers/machines.
cd "$WORK_DIR"
if [ -d "$WORK_DIR/.git/rebase-merge" ] || [ -d "$WORK_DIR/.git/rebase-apply" ]; then
  git rebase --abort 2>/dev/null || true
fi
if [ -f "$WORK_DIR/.git/MERGE_HEAD" ]; then
  git merge --abort 2>/dev/null || true
fi
git fetch origin main 2>/dev/null || true
git rebase --autostash origin/main 2>&1 >/dev/null || true

# --- Isolated git worktree per worker -------------------------------------
# Why: workers + operator sharing ONE working tree caused (a) staging races,
# (b) branch-stranding, (c) cross-task contamination. Fix: each worker that
# runs in the MAIN repo (not a routed submodule) gets its own `git worktree`
# on branch worker/<slug>-<epoch> cut from origin/main. The worker commits only inside
# its worktree; the merge back to main (rebase onto origin/main + atomic ff
# `git push origin HEAD:main`) and the cleanup happen in the /done and /blocked
# commands. The main tree (operator) is never checked out to a worker branch,
# so operator commits always land on main. Submodule-routed workers
# (WORKER_WORK_DIR set) operate in a separate repo with their own flow → left
# untouched.
WORKER_BRANCH=""
WORKER_WORKTREE=""
# WORKER_NO_WORKTREE=1 opts a launch out of the isolated worktree and runs it in
# the shared main tree (e.g. the strategist, which edits memory/ in place and is
# a singleton — no cross-task contention to isolate against).
if [ "$LAUNCH_CWD" = "$REPO_ROOT" ] && [ "${WORKER_NO_WORKTREE:-0}" != "1" ]; then
  WORKTREE_BASE="$(cd "$REPO_ROOT/.." && pwd)/.worktrees"
  WORKER_WORKTREE="${WORKTREE_BASE}/${TASK_ID}"
  # Branch carries the per-spawn epoch → a unique remote ref per worker, so the
  # /done ff-push and the `git push -u origin <branch>` backup never collide with
  # a sibling/prior worker sharing the slug. The worktree path stays slug-based
  # (reused each spawn; same-slug concurrency is already blocked by the tmux
  # idempotency check above), which keeps the GC's session⇄worktree map simple.
  WORKER_BRANCH="worker/${TASK_ID}-${WORKER_EPOCH}"
  mkdir -p "$WORKTREE_BASE"
  # Orphan GC: reap any worktree whose worker-<slug> tmux session is dead (a hard
  # kill by the supervisor skips the /done cleanup). Bounded, safe (only touches
  # worktrees with no live worker).
  #
  # EXCEPT worktrees marked `.agentos-undelivered`: /done's verify-gate writes that
  # sentinel when the commits did NOT reach origin/main, then leaves via /blocked —
  # which kills the session, i.e. exactly the "dead session" this GC keys on.
  # Reaping there would delete the branch and orphan the commits — the very loss
  # the gate exists to prevent. The skip self-clears: once the work lands in
  # origin/main the sentinel no longer protects it and the next tick reaps normally.
  if [ -d "$WORKTREE_BASE" ]; then
    for wt in "$WORKTREE_BASE"/*; do
      [ -d "$wt" ] || continue
      orphan_slug="$(basename "$wt")"
      tmux has-session -t "worker-${orphan_slug}" 2>/dev/null && continue
      if [ -f "$wt/.agentos-undelivered" ]; then
        wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
        if [ -n "$wt_head" ] && ! git merge-base --is-ancestor "$wt_head" origin/main 2>/dev/null; then
          echo "spawn-worker: KEEPING $wt — undelivered commits not in origin/main (needs manual re-merge)" >&2
          continue
        fi
        echo "spawn-worker: $wt was undelivered but its commits are now in origin/main — reaping" >&2
      fi
      git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
      # Branches are epoch-suffixed (worker/<slug>-<epoch>); reap every local branch
      # for this slug plus the legacy bare name for back-compat.
      # HARD INVARIANT: never delete a branch whose tip is not yet in origin/main —
      # the local ref is the last handle on those commits, and the glob below spans
      # epochs, so reaping a LATER run on this slug would otherwise orphan an
      # EARLIER preserved run's work.
      for b in $(git branch --list "worker/${orphan_slug}" "worker/${orphan_slug}-*" \
                   --format '%(refname:short)' 2>/dev/null); do
        if git merge-base --is-ancestor "$b" origin/main 2>/dev/null; then
          git branch -D "$b" 2>/dev/null || true
        else
          echo "spawn-worker: KEEPING branch $b — commits not in origin/main" >&2
        fi
      done
      echo "spawn-worker: reaped orphan worktree $wt (no live session)" >&2
    done
    git worktree prune 2>/dev/null || true
  fi
  # A preserved undelivered worktree on this slug's path: a requeue of the SAME task
  # must not bulldoze the prior run's unmerged commits. Move it aside (`git worktree
  # move` keeps the metadata + branch intact) so the work survives AND the path frees
  # up for the new spawn. Only the path is sacrificed, never the commits.
  if [ -f "${WORKER_WORKTREE}/.agentos-undelivered" ]; then
    KEEP="${WORKER_WORKTREE}.undelivered-${WORKER_EPOCH}"
    if git worktree move "$WORKER_WORKTREE" "$KEEP" 2>/dev/null; then
      echo "spawn-worker: preserved undelivered worktree → $KEEP (branch kept for re-merge)" >&2
    else
      # Path stays occupied → the prune below skips it (sentinel still there) and the
      # `worktree add` falls into the existing shared-tree fallback.
      echo "spawn-worker: WARN could not move undelivered worktree $WORKER_WORKTREE — keeping it, worker falls back to shared tree" >&2
    fi
  fi
  # Idempotent prune of any stale worktree/branch for this slug.
  # Guarded: never prune a path still holding undelivered commits.
  if [ ! -f "${WORKER_WORKTREE}/.agentos-undelivered" ]; then
    if git worktree list --porcelain 2>/dev/null | grep -qx "worktree ${WORKER_WORKTREE}"; then
      git worktree remove --force "$WORKER_WORKTREE" 2>/dev/null || true
    fi
    git worktree prune 2>/dev/null || true
    rm -rf "$WORKER_WORKTREE" 2>/dev/null || true
  fi
  # -B (re)creates worker/<slug>-<epoch> at origin/main; the epoch makes it fresh.
  # --force tolerates a reused path. Fall back to the shared tree only if worktree
  # add genuinely fails — better a working worker than a dead queue.
  if git worktree add --force -B "$WORKER_BRANCH" "$WORKER_WORKTREE" origin/main >/dev/null 2>&1; then
    LAUNCH_CWD="$WORKER_WORKTREE"
    echo "spawn-worker: isolated worktree $WORKER_WORKTREE on $WORKER_BRANCH" >&2
  else
    echo "spawn-worker: WARN worktree add failed for ${TASK_ID}; falling back to shared tree" >&2
    WORKER_BRANCH=""
    WORKER_WORKTREE=""
  fi
fi

# When launching inside a submodule, grant read access to the main repo too.
ADD_DIR_FLAG=""
if [ "$LAUNCH_CWD" != "$WORK_DIR" ]; then
  ADD_DIR_FLAG="--add-dir '$WORK_DIR'"
fi

# Resolve CLAUDE_CONFIG_DIR with a defensive probe. Preferred source is the
# parent env (Dagu process env, operator unit env, etc.). If unset, probe the
# canonical AgentOS state-dir config dirs that actually contain a .claude.json,
# falling back to $HOME/.claude only as a last resort — a config dir without
# .claude.json lands the CLI on the theme picker and the worker hangs.
RESOLVED_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"
if [ -z "$RESOLVED_CONFIG_DIR" ]; then
  for candidate in \
      "$CLAUDE_CONFIG_BASE/server" \
      "$CLAUDE_CONFIG_BASE/dispatcher" \
      "$CLAUDE_CONFIG_BASE/heartbeat" \
      "$HOME/.claude"; do
    if [ -f "$candidate/.claude.json" ]; then
      RESOLVED_CONFIG_DIR="$candidate"
      echo "spawn-worker: CLAUDE_CONFIG_DIR unset, auto-resolved to $candidate" >&2
      break
    fi
  done
fi
if [ -z "$RESOLVED_CONFIG_DIR" ] || [ ! -f "$RESOLVED_CONFIG_DIR/.claude.json" ]; then
  echo "ERROR: no usable CLAUDE_CONFIG_DIR (no .claude.json in env/probed dirs)." >&2
  echo "  Tried env, $CLAUDE_CONFIG_BASE/{server,dispatcher,heartbeat}, \$HOME/.claude." >&2
  echo "  Worker would hang on the theme picker; aborting before tmux launch." >&2
  exit 2
fi

# Pre-flight: validate the rendered settings.json BEFORE spawning. An invalid
# rule (e.g. a wildcard-scope "mcp__*" allow rule, or broken JSON) makes Claude
# Code show a blocking "Settings Warning … Enter to confirm" dialog on startup;
# in a headless tmux worker nobody presses Enter, so the worker hangs empty
# until the supervisor kills it. Catch it here, loudly, and refuse to spawn.
if [ -f "${WORK_DIR}/scripts/validate-worker-settings.py" ]; then
  if ! python3 "${WORK_DIR}/scripts/validate-worker-settings.py" "$RESOLVED_CONFIG_DIR" >&2; then
    detail="invalid settings.json in ${RESOLVED_CONFIG_DIR} (wildcard-scope MCP rule / broken JSON)"
    echo "ERROR: pre-flight settings validation failed — NOT spawning worker ${TASK_ID}." >&2
    echo "  $detail" >&2
    [ -x "$NOTIFY" ] && "$NOTIFY" \
      --source "spawn-worker" --severity "error" \
      --msg "settings invalid: ${detail}; workers not launched (task ${CLICKUP_TASK_ID})" \
      2>/dev/null || true
    exit 3
  fi
fi

# Assemble the tmux -e env flags. Static ones first, then any WORKER_ENV_PASSTHROUGH.
#
# Auth: use the config dir's OAuth credential store (CLAUDE_CONFIG_DIR), NOT a
# static CLAUDE_CODE_OAUTH_TOKEN inherited from the env — reset it to empty.
# CLAUDECODE=1 — programmatic-invocation signal. MCP_CONNECTION_NONBLOCKING —
# workers are ephemeral, don't block on MCP init. CLAUDE_CODE_FORK_SUBAGENT —
# allow Agent-tool subagents in this session.
TMUX_ENV_FLAGS=(
  -e "CLAUDE_CONFIG_DIR=${RESOLVED_CONFIG_DIR}"
  -e "WORKER_MODEL=${MODEL}"
  -e "CLAUDE_CODE_OAUTH_TOKEN="
  -e "CLAUDECODE=1"
  -e "MCP_CONNECTION_NONBLOCKING=true"
  -e "CLAUDE_CODE_FORK_SUBAGENT=1"
  -e "AGENTOS_WORKER_MODE=1"
  -e "AGENTOS_WORKER_TASK_ID=${TASK_ID}"
  -e "AGENTOS_WORKER_CLICKUP_TASK_ID=${CLICKUP_TASK_ID}"
  -e "AGENTOS_WORKER_WORKTREE=${WORKER_WORKTREE}"
  -e "AGENTOS_WORKER_BRANCH=${WORKER_BRANCH}"
  -e "AGENTOS_WORKER_MAIN_REPO=${REPO_ROOT}"
)
for var in $WORKER_ENV_PASSTHROUGH; do
  TMUX_ENV_FLAGS+=(-e "${var}=${!var:-}")
done

# Launch interactive claude in tmux.
tmux new-session -d -s "$SESSION_NAME" -c "$LAUNCH_CWD" \
  "${TMUX_ENV_FLAGS[@]}" \
  "$CLAUDE \
    --dangerously-skip-permissions \
    ${ADD_DIR_FLAG} \
    --dangerously-load-development-channels server:claude-peers \
    --model '$MODEL' \
    \"\$(cat '${WORKER_DIR}/prompt.md')\""

# "session launched" marker — written the instant `tmux new-session` returns,
# i.e. only after pre-flight passed and the session was created. The supervisor's
# orphan sweep reads this to classify a crashed worker:
#   present ⇒ "died mid-run (booted, session lost)";
#   absent  ⇒ "spawn-failed: claude never booted".
date +%s > "${WORKER_DIR}/session-launched" 2>/dev/null || true

echo "[$(date '+%Y-%m-%d %H:%M')] worker ${TASK_ID} started (backend=${CLICKUP_TASK_ID}, model=${MODEL}, timeout=${TIMEOUT_MIN}min)" \
  >> "${ACTIVITY_LOG_DIR}/$(date +%Y-%m).log"

# Background heartbeat loop: touch logs/workers/<slug>/heartbeat while the tmux
# session lives, so the supervisor can tell a live worker from an orphan. setsid
# detaches it from the spawner's process group so it survives the launcher exit.
setsid bash -c "
  while tmux has-session -t '$SESSION_NAME' 2>/dev/null; do
    touch '$WORKER_DIR/heartbeat'
    sleep 60
  done
" </dev/null >>"${WORKER_DIR}/heartbeat.log" 2>&1 &

echo "LAUNCHED: $SESSION_NAME (interactive, model=${MODEL}, backend=${CLICKUP_TASK_ID})" >&2
exit 0
