#!/bin/bash
# Launch a worker in an isolated tmux session
# Usage: ./worker-launcher.sh <task-id> <prompt-file> [max-iterations] [timeout-minutes] [agent-type] [model]
#
# agent-type: (empty by default = generic worker). Если в твоей системе появятся специализированные
#   агенты (researcher, outreacher и т.п.) — добавь их директории в agents/ и передавай имя сюда.
#   Worker подхватит agents/{agent-type}/CLAUDE.md + SOUL.md.
# model: claude-sonnet-4-6 (default) | claude-opus-4-6 (для сложных/стратегических задач)
#
# Создает tmux сессию: worker-<task-id>
# Worker dir: logs/workers/<task-id>/
# Worker пишет результат в: logs/workers/<task-id>/result.md
# Worker крутится пока result.md не появится или не будет достигнут лимит итераций/таймаут
#
# Перед запуском настрой переменную AGENTOS_ROOT.

set -euo pipefail

TASK_ID="${1:?Usage: $0 <task-id> <prompt-file> [max-iterations] [timeout-minutes] [agent-type] [model]}"
PROMPT_FILE="${2:?Usage: $0 <task-id> <prompt-file> [max-iterations] [timeout-minutes] [agent-type] [model]}"
MAX_ITERATIONS="${3:-20}"
TIMEOUT_MIN="${4:-30}"
AGENT_TYPE="${5:-}"
MODEL="${6:-claude-sonnet-4-6}"
HOME="${HOME:-$HOME}"
AGENTOS_ROOT="${AGENTOS_ROOT:-$HOME/Workspaces/agentos}"
CLAUDE="${CLAUDE:-$HOME/.local/bin/claude}"
WORKER_DIR="${AGENTOS_ROOT}/logs/workers/${TASK_ID}"
SESSION_NAME="worker-${TASK_ID}"

# Idempotency: skip if worker already running
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "SKIP: worker $SESSION_NAME already running" >&2
  exit 0
fi

# Create worker directory (clean previous run)
rm -rf "$WORKER_DIR"
mkdir -p "$WORKER_DIR"

# Copy prompt
cp "$PROMPT_FILE" "$WORKER_DIR/prompt.md"

# Write worker loop script
cat > "$WORKER_DIR/run.sh" << 'WORKER_EOF'
#!/bin/bash
set -uo pipefail
# No set -e: must reach cleanup even if commands fail

# Skip MCP connection wait — workers are ephemeral, speed matters
export MCP_CONNECTION_NONBLOCKING=true

# Enable PostToolUse output compression for context efficiency
export AGENTOS_WORKER_MODE=1

# Enable subagent spawning via Agent tool in non-interactive sessions (CC v2.1.121+)
export CLAUDE_CODE_FORK_SUBAGENT=1

TASK_ID="$1"
MAX_ITERATIONS="$2"
TIMEOUT_MIN="$3"
AGENTOS_ROOT="$4"
CLAUDE="$5"
AGENT_TYPE="${6:-}"
MODEL="${7:-claude-sonnet-4-6}"
WORKER_DIR="${AGENTOS_ROOT}/logs/workers/${TASK_ID}"
RESULT_FILE="${WORKER_DIR}/result.md"
PROMPT=$(cat "${WORKER_DIR}/prompt.md")
START_TIME=$(date +%s)
ITERATION=0

while true; do
  ITERATION=$((ITERATION + 1))

  # Check max iterations
  if [[ $ITERATION -gt $MAX_ITERATIONS ]]; then
    cat > "$RESULT_FILE" << TIMEOUT_EOF
---
status: timeout
summary: "MAX_ITERATIONS ($MAX_ITERATIONS) reached without completing task"
---
Worker exhausted $MAX_ITERATIONS iterations without writing result.
TIMEOUT_EOF
    break
  fi

  # Check timeout
  ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
  if [[ $ELAPSED -ge $TIMEOUT_MIN ]]; then
    cat > "$RESULT_FILE" << TIMEOUT_EOF
---
status: timeout
summary: "TIMEOUT (${TIMEOUT_MIN}min) reached at iteration $ITERATION"
---
Worker timed out after ${TIMEOUT_MIN} minutes at iteration $ITERATION.
TIMEOUT_EOF
    break
  fi

  # Check if result already written (by Claude itself)
  if [[ -f "$RESULT_FILE" ]] && [[ -s "$RESULT_FILE" ]]; then
    break
  fi

  # Build iteration prompt — include previous iteration context on retry
  PREV_CONTEXT=""
  if [[ $ITERATION -gt 1 ]]; then
    PREV_ITER=$((ITERATION - 1))
    PREV_OUTPUT="${WORKER_DIR}/iter-${PREV_ITER}-output.txt"
    if [[ -s "$PREV_OUTPUT" ]]; then
      PREV_TAIL=$(tail -40 "$PREV_OUTPUT")
      PREV_CONTEXT="
## Контекст предыдущей итерации (итерация ${PREV_ITER})
Предыдущая попытка не завершилась успехом. Последний вывод:
\`\`\`
${PREV_TAIL}
\`\`\`
Проанализируй что пошло не так и попробуй другой подход. Если заблокирован — запиши FAILURE в memory/learnings.md и укажи status: blocked в result.md.
"
    fi
  fi

  ITER_PROMPT="[Worker iteration ${ITERATION}/${MAX_ITERATIONS}, elapsed ${ELAPSED}min/${TIMEOUT_MIN}min]

${PROMPT}
${PREV_CONTEXT}
ВАЖНО: когда задача выполнена, запиши результат в файл ${RESULT_FILE} и заверши работу.
Формат результата:
---
status: done|blocked|partial
summary: краткое описание результата
---
Детальный результат..."

  # Write prompt to file (avoid shell escaping issues with large prompts)
  printf '%s' "$ITER_PROMPT" > "${WORKER_DIR}/iter-prompt.md"

  # Touch heartbeat so watchdog knows we're alive
  touch "${WORKER_DIR}/heartbeat"

  # Git pull before each iteration — pick up changes from other devs/machines
  cd "$AGENTOS_ROOT"
  git diff --quiet && git diff --cached --quiet || git stash
  GIT_PULL_OUT=$(git pull --rebase origin main 2>&1)
  GIT_EXIT=$?
  if [ $GIT_EXIT -ne 0 ]; then
    echo "[$(date)] [worker-${TASK_ID}] git pull failed (exit $GIT_EXIT): $GIT_PULL_OUT" >> "${AGENTOS_ROOT}/memory/worker-errors.log"
    # Check for merge conflict markers
    if echo "$GIT_PULL_OUT" | grep -q -E "CONFLICT|conflict"; then
      CONFLICT_MSG="[GIT CONFLICT] Merge conflict в worker-${TASK_ID}. Подробности: memory/worker-errors.log. Требуется ручное разрешение."
      echo "[$(date)] $CONFLICT_MSG" >> "${AGENTOS_ROOT}/memory/worker-errors.log"
      # Notify operator via claude-peers if available
      PEERS_URL="http://localhost:7899"
      OPERATOR_ID=$(curl -sf "${PEERS_URL}/peers" 2>/dev/null | python3 -c "
import sys, json
try:
  peers = json.load(sys.stdin)
  for p in peers:
    cwd = p.get('cwd','')
    if 'operator' in cwd:
      print(p.get('id',''))
      break
except: pass
" 2>/dev/null || true)
      if [ -n "$OPERATOR_ID" ]; then
        curl -sf -X POST "${PEERS_URL}/peers/${OPERATOR_ID}/messages" \
          -H "Content-Type: application/json" \
          -d "{\"message\": \"${CONFLICT_MSG}\"}" >/dev/null 2>&1 || true
      fi
      git rebase --abort 2>/dev/null || true
    fi
    # Continue without blocking — work may still succeed on current state
  fi
  git stash pop 2>/dev/null || true

  # Stream output directly to stdout (visible in tmux pane + tee'd to output.log)
  cd "$AGENTOS_ROOT"

  # Build agent-specific --add-dir flags
  AGENT_DIR_FLAG=""
  if [[ -n "$AGENT_TYPE" ]] && [[ -d "$AGENTOS_ROOT/agents/$AGENT_TYPE" ]]; then
    AGENT_DIR_FLAG="--add-dir $AGENTOS_ROOT/agents/$AGENT_TYPE"
  fi

  $CLAUDE \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --output-format stream-json --verbose \
    --add-dir "$AGENTOS_ROOT/memory" \
    --add-dir "$AGENTOS_ROOT/agents" \
    $AGENT_DIR_FLAG \
    -p "$(cat "${WORKER_DIR}/iter-prompt.md")" \
    2>>"${WORKER_DIR}/iter-${ITERATION}-errors.log" \
    | tee "${WORKER_DIR}/iter-${ITERATION}-stream.jsonl" \
    | python3 "$AGENTOS_ROOT/agents/dispatcher/parse-worker-stream.py" \
        "${WORKER_DIR}/iter-${ITERATION}-cost.json" \
    | tee "${WORKER_DIR}/iter-${ITERATION}-output.txt" \
    || true

  touch "${WORKER_DIR}/heartbeat"

  # If claude finished but forgot to write result.md, create it from stdout
  if [[ ! -f "$RESULT_FILE" ]] && [[ -s "${WORKER_DIR}/iter-${ITERATION}-output.txt" ]]; then
    {
      echo "---"
      echo "status: done"
      echo "summary: Worker completed (result auto-captured from stdout)"
      echo "---"
      echo ""
      cat "${WORKER_DIR}/iter-${ITERATION}-output.txt"
    } > "$RESULT_FILE"
  fi

  # Brief pause between iterations
  sleep 5
done

echo "Worker ${TASK_ID} finished at iteration ${ITERATION}" >&2
WORKER_EOF

chmod +x "$WORKER_DIR/run.sh"

# Launch in tmux with output logged
tmux new-session -d -s "$SESSION_NAME" -c "$AGENTOS_ROOT" \
  "bash ${WORKER_DIR}/run.sh ${TASK_ID} ${MAX_ITERATIONS} ${TIMEOUT_MIN} ${AGENTOS_ROOT} ${CLAUDE} ${AGENT_TYPE} ${MODEL} 2>&1 | tee ${WORKER_DIR}/output.log"

echo "LAUNCHED: $SESSION_NAME (max_iter=$MAX_ITERATIONS, timeout=${TIMEOUT_MIN}min, agent=${AGENT_TYPE:-generic}, model=${MODEL})" >&2
exit 0
