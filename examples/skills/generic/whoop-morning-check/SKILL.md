---
name: whoop-morning-check
description: Получает данные здоровья из WHOOP MCP (recovery, HRV, RHR, sleep), обновляет memory/health.md и отправляет алерт оператору если recovery < 33%.
when_to_use: Каждое утро после 07:00 по расписанию (24ч интервал); задача типа whoop, health, recovery, утренний чек.
allowed-tools: Read, Edit, Write, Bash, mcp__claude-peers__list_peers, mcp__claude-peers__send_message
---

# Скилл: whoop-morning-check

Получает данные здоровья из WHOOP и записывает в `${CLAUDE_PROJECT_DIR}/memory/health.md`.
При recovery < 33% отправляет алерт оператору.

## Когда запускать

- Каждое утро (после 07:00)
- Частота: 24ч (см. `${CLAUDE_PROJECT_DIR}/memory/schedule.md`)

## Требования

- WHOOP MCP сервер запущен на `localhost:3850` (стороннее решение, см. WHOOP API SDK)
- Транспорт: StreamableHTTP POST `/mcp`
- Если у тебя нет WHOOP — пропусти этот скилл или адаптируй под другой fitness-tracker (Oura, Garmin, Apple Health)

## Шаги

### 1. Получить данные

Вызови `whoop_get_overview` через MCP (`localhost:3850/mcp`):

```bash
curl -s -X POST http://localhost:3850/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"whoop_get_overview","arguments":{}},"id":1}'
```

Если сервер недоступен — записать в check-log `whoop-offline` и завершить без алерта.

### 2. Извлечь ключевые метрики

Из ответа извлечь:
- `recovery_score` (0–100)
- `hrv_rmssd_milli` (мс)
- `resting_heart_rate` (bpm)
- `sleep_performance_percentage` (%)
- Общее время сна в часах

### 3. Обновить memory/health.md

Перезаписать секцию `## Последние данные` в `${CLAUDE_PROJECT_DIR}/memory/health.md`:

```markdown
## Последние данные

**Дата:** YYYY-MM-DD HH:MM

| Метрика | Значение | Статус |
|---------|----------|--------|
| Recovery | 73% | 🟡 yellow |
| HRV | 31.8 мс | — |
| RHR | 52 bpm | — |
| Sleep | 7.2ч / 84% | — |
```

Зоны recovery:
- 🟢 green: 67–100
- 🟡 yellow: 34–66
- 🔴 red: 0–33

### 4. Добавить в Morning Brief

Если worker `morning-brief` уже запущен сегодня — добавить WHOOP секцию в его output.
Если нет — подготовить standalone блок для Telegram:

```
🫀 WHOOP {дата}
Recovery: {N}% ({color})
HRV: {hrv} мс | RHR: {rhr} bpm
Сон: {h}ч / {perf}%
```

### 5. Алерт при recovery < 33%

Если `recovery_score < 33`:

1. Вызвать `list_peers(scope: "machine")` — найти operator peer
2. Отправить через claude-peers:
   ```
   ⚠️ WHOOP ALERT: Recovery {score}% — красная зона.
   HRV: {hrv} мс, RHR: {rhr} bpm.
   Рекомендация: минимальная нагрузка, критические встречи только.
   ```

### 6. Обновить check-log

Записать в `${CLAUDE_PROJECT_DIR}/memory/check-log.md`:
```
whoop-morning-check | YYYY-MM-DD HH:MM | recovery={score}%
```

## Ошибки

| Ситуация | Действие |
|----------|----------|
| Сервер недоступен | check-log "whoop-offline", молчим |
| WHOOP API 401 | Сервер перезапустится сам (KeepAlive), retry через 30 мин |
| score_state != "SCORED" | Записать "pending" в health.md, повторить через 1ч |
| recovery не получен | Логировать, не алертить |
