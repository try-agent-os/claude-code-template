---
name: timing-rebuild
description: Ежедневный rebuild time entries за вчерашний день на основе raw app usage из Timing.app SQLite + правил из memory/timing-rules.yaml. Отправляет preview в Telegram.
when_to_use: Ежедневно утром после morning-brief (24ч интервал, после 08:30); пользователь сказал "пересобрать таймтрекинг", "timing-rebuild".
allowed-tools: Read, Edit, Bash, mcp__claude-peers__list_peers, mcp__claude-peers__send_message
---

# Скилл: Timing Rebuild

Пересобирает time entries Timing.app за вчерашний день. Использует SQLite → rules → API pipeline.

## Зависимости

- Timing.app (macOS, https://timingapp.com) с подпиской дающей API access
- TIMING_API_KEY в env (или `~/.timing/secrets`)
- Скрипты `rebuild_day.py`, `build_entries.py` в `${CLAUDE_PROJECT_DIR}/.claude/skills/timing-app-management/scripts/`
- `${CLAUDE_PROJECT_DIR}/memory/timing-rules.yaml` (правила классификации)
- claude-peers + operator для отправки preview в Telegram

Если у тебя другой time-tracker (Toggl, RescueTime, Hubstaff) — адаптируй под их API.

## Когда запускать

- Ежедневно утром после morning-brief (`memory/schedule.md`: `timing-rebuild`, 24ч, after 08:30)
- Приоритет: low (не блокирует другие задачи)

## Алгоритм

### Step 1: Определить вчерашний день

```bash
YESTERDAY=$(date -v-1d '+%Y-%m-%d')   # macOS
# Linux: YESTERDAY=$(date -d 'yesterday' '+%Y-%m-%d')
```

### Step 2: Прогнать rebuild

```bash
cd "${CLAUDE_PROJECT_DIR}"
python3 .claude/skills/timing-app-management/scripts/rebuild_day.py "$YESTERDAY"
```

Скрипт сам:
- Удаляет существующие entries за день
- Анализирует AppActivity (Mac-only, context classification)
- Применяет calendar overlay (meetings, haircut, lunch)
- Создаёт новые entries через API

### Step 3: Собрать сводку

```bash
python3 .claude/skills/timing-app-management/scripts/build_entries.py "$YESTERDAY"
# План в /tmp/timing_plan.json
```

Из JSON извлечь:
- Часы по Production (разбивка по клиенту/проекту)
- Часы по Operations / Meetings / Growth / Personal
- Главный блок дня
- Алерты (night_work, sleep <6h, client_zero)

### Step 4: Отправить preview в Telegram

Через claude-peers → operator → Telegram. Пример формата:

```
⏱ Таймтрекинг за DD.MM (пересобрано)

🔧 Production: 6ч 30м
  • Project A 5ч
  • Project B 1ч 30м
🤝 Meetings: 45м
💬 Operations: 2ч
💤 Sleep: 7ч 15м
😴 Breaks: 2ч

⚠ Сигналы:
• Sleep 6ч 45м (на 15м меньше целевых 7)

Если что-то не так — скажи, исправлю.
```

Отправка:

```bash
PEERS=$(curl -s http://127.0.0.1:7899/list-peers -H 'Content-Type: application/json' -d '{"scope":"machine","cwd":"/","git_root":null}')
OPERATOR_ID=$(echo "$PEERS" | python3 -c "import json,sys; peers=json.load(sys.stdin); print(next((p['id'] for p in peers if 'operator' in p.get('cwd','')), ''))")
if [ -n "$OPERATOR_ID" ]; then
  curl -s http://127.0.0.1:7899/send-message \
    -H 'Content-Type: application/json' \
    -d "{\"to_id\": \"$OPERATOR_ID\", \"from_id\": \"timing-rebuild\", \"text\": \"<СООБЩЕНИЕ>\"}"
fi
```

### Step 5: Check-log

```bash
echo "timing-rebuild | $(date '+%Y-%m-%d %H:%M') | $YESTERDAY пересобран" >> "${CLAUDE_PROJECT_DIR}/memory/check-log.md"
```

## Ошибки

| Ситуация | Действие |
|----------|----------|
| TIMING_API_KEY не найден | Пропустить, записать ошибку в check-log "timing-rebuild failed: no token" |
| SQLite locked | Retry через 30 сек (Timing закончит sync) |
| API 5xx | Retry 1 раз, потом пропуск + лог |
| Operator не найден в peers | Создать задачу в saga "Timing rebuild: output below" + embed сводку |

## Исключения

- Если вчерашний день — выходной без работы (< 30 мин Mac activity) — пропустить rebuild, записать "quiet day"
- Если за день уже >10 ручных правок в TaskActivity (detected via notes field) — НЕ перезаписывать, отправить пользователю «день уже размечен вручную, rebuild пропущен»
