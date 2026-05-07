---
name: self-heal-autofix
description: Автоматическое восстановление AgentOS по 8 runbook'ам (RB-001..RB-008) — MCP restart, декомпозиция задачи, orphan reset, dispatcher restart, zombie flood mitigation. Вызывается после диагностики L2.
when_to_use: После self-heal-diagnose с diagnosis_type определён и auto_fixable=true; для auth_expired и unknown — эскалация.
allowed-tools: Read, Edit, Write, Bash, mcp__saga-mcp__task_get, mcp__saga-mcp__task_update, mcp__saga-mcp__task_list, mcp__saga-mcp__task_create, mcp__claude-peers__send_message
disable-model-invocation: true
---

# Скилл: Self-Heal Autofix (Уровень 3: FIX)

> Destructive skill. Останавливает/перезапускает сервисы и сбрасывает состояние задач. `disable-model-invocation: true` — запускается только явным вызовом, не autoselect.

**Назначение:** Автоматическое восстановление AgentOS по результатам диагностики (L2).
**Триггер:** Вызывается после `self-heal-diagnose` с заполненным diagnosis JSON.
**Вход:** `diagnosis_type` + `saga_task_id` + при mcp_down — имя упавшего сервиса.
**Выход:** Запись в `logs/health/autofix.log`, обновление задачи в saga-mcp, уведомление operator.

---

## Маппинг: diagnosis_type → Runbook

| diagnosis_type | Runbook | auto_fixable |
|---------------|---------|-------------|
| `mcp_down` | RB-001 | ДА |
| `too_large` / MAX_ITERATIONS | RB-002 | ДА |
| `orphan` | RB-003 | ДА |
| `dispatcher_gap` | RB-004 | ДА |
| `zombie_loop` | RB-005 | ДА |
| `rate_limit` | RB-006 | ДА (wait) |
| `auth_expired` | RB-007 | НЕТ → эскалация |
| `unknown` | RB-008 | НЕТ → эскалация |

---

## RB-001: MCP Restart Autofix

**Триггер:** `diagnosis_type = "mcp_down"` — один из MCP-сервисов не отвечает на health check.

### Шаг 1: Определить упавший сервис

Проверить все MCP через curl (адаптируй порты под свой стек):

```bash
curl -s --max-time 3 http://localhost:3851/health 2>&1; STATUS_SAGA=$?
curl -s --max-time 3 http://localhost:3848/health 2>&1; STATUS_TG=$?
curl -s --max-time 3 http://127.0.0.1:7899/health 2>&1; STATUS_PEERS=$?
```

Маппинг порт → launchd label (адаптируй под свои plist'ы):

| Порт | Сервис | launchd label |
|------|--------|--------------|
| 3851 | saga-mcp | `com.novostudio.saga-mcp` |
| 3848 | telegram-mcp | `com.novostudio.telegram-mcp` |
| 7899 | claude-peers | `com.novostudio.claude-peers-broker` |

Также можно сверить через:
```bash
launchctl list | grep novostudio
# Формат: PID | ExitCode | Label
# PID = "-" означает сервис не запущен
# ExitCode != 0 означает сервис упал с ошибкой
```

### Шаг 2: Kickstart упавшего сервиса

```bash
FAILED_LABEL="com.novostudio.saga-mcp"  # заменить на нужный label
USER_ID=$(id -u)

launchctl kickstart -k "gui/${USER_ID}/${FAILED_LABEL}"
```

Флаг `-k` = kill + restart (безопаснее чем просто start, идемпотентен).

### Шаг 3: Подождать 5 секунд, проверить здоровье

```bash
sleep 5

# Проверить через curl соответствующий порт
HEALTH=$(curl -s --max-time 5 http://localhost:3851/health 2>&1)

# Проверить через launchctl
launchctl list | grep "${FAILED_LABEL}"
```

### Шаг 4: Записать результат в autofix.log

```bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if echo "$HEALTH" | grep -qiE "ok|healthy|running"; then
  RESULT="SUCCESS"
else
  RESULT="FAILED"
fi

echo "${TIMESTAMP} | RB-001 | ${FAILED_LABEL} | kickstart: ${RESULT} | health: ${HEALTH}" >> "${CLAUDE_PROJECT_DIR}/logs/health/autofix.log"
```

### Шаг 5: При SUCCESS

1. Повторить health check через 10 сек для подтверждения стабильности
2. Если worker был задача в saga — сбросить статус на `todo` (чтобы dispatcher перезапустил):
   ```
   mcp__saga-mcp__task_update(id: <saga_task_id>, status: "todo")
   ```
3. Уведомить operator:
   ```
   [AUTOFIX OK] RB-001: {FAILED_LABEL} перезапущен. Worker {task_slug} сброшен в todo.
   ```

### Шаг 6: При FAILURE

1. Записать в autofix.log с RESULT="FAILED"
2. Создать задачу эскалации в saga (epic AgentOS Infrastructure):
   ```
   mcp__saga-mcp__task_create(
     epic_id: <infra_epic>,
     title: "ESCALATE: MCP {FAILED_LABEL} не восстановился после kickstart",
     description: "RB-001 autofix не помог. Требуется ручная диагностика.",
     priority: "high"
   )
   ```
3. Уведомить operator:
   ```
   [AUTOFIX FAILED] RB-001: {FAILED_LABEL} не восстановился. Создана задача sysadmin #N.
   ```

---

## RB-002: MAX_ITERATIONS Decompose

**Триггер:** `diagnosis_type = "too_large"` — worker завершился с MAX_ITERATIONS.

### Шаг 1: Прочитать description исходной задачи

```
mcp__saga-mcp__task_get(id: <saga_task_id>)
```

Сохранить: `title`, `description`, `epic_id`.

### Шаг 2: Прочитать последний iter-output

```bash
ls -t "${CLAUDE_PROJECT_DIR}/logs/workers/{task_slug}/iter-*-output.txt" 2>/dev/null | head -1
```

Цель: понять **что уже сделано** и **что осталось**.

### Шаг 3: Определить что сделано vs что осталось

Анализировать output на признаки завершенных шагов:
- Упоминания "done", "создал", "записал", "обновил", "отправил"
- Коммиты (`git commit` в выводе)
- Созданные файлы (по Write tool вызовам в логе)

Определить оставшийся scope: то, что упомянуто в description но не появилось в output.

### Шаг 4: Создать 3-5 подзадач

Разбить оставшийся scope на части <= 15 итераций каждая:

```
mcp__saga-mcp__task_create(
  epic_id: <исходный epic_id>,
  title: "<Исходный title> — часть 1/3: <что именно>",
  description: "Продолжение задачи #<исходный_id> после MAX_ITERATIONS.\n\nУже сделано (из output.log):\n- ...\n\nЗадача этой части:\n- ...",
  priority: "medium"
)
```

### Шаг 5: Заблокировать исходную задачу

```
mcp__saga-mcp__task_update(
  id: <saga_task_id>,
  status: "blocked",
  description: "<existing>\n\n[DECOMPOSED <date>] MAX_ITERATIONS. Разбита на: #N1, #N2, #N3"
)
```

### Шаг 6: Записать в autofix.log

```bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "${TIMESTAMP} | RB-002 | task_${SAGA_TASK_ID} | decomposed into #N1,#N2,#N3 | subtasks: 3" >> "${CLAUDE_PROJECT_DIR}/logs/health/autofix.log"
```

### Шаг 7: Уведомить operator

```
[AUTOFIX OK] RB-002: задача #<id> ({title}) достигла MAX_ITERATIONS.
Декомпозирована на 3 подзадачи: #N1, #N2, #N3.
Исходная задача заблокирована.
```

---

## RB-003: Saga Orphan Reset

**Триггер:** `diagnosis_type = "orphan"` — задача висит в статусе `in_progress` в saga-mcp, но tmux-сессия worker'а не существует.

### Шаг 1: Получить список задач in_progress

```
mcp__saga-mcp__task_list(status: "in_progress")
```

### Шаг 2: Для каждой задачи — derive slug и проверить tmux

Slug = транслитерация title + замена пробелов на `-` + lowercase.

```bash
SLUG="<task-slug>"
tmux ls 2>/dev/null | grep "^worker-${SLUG}"
STATUS=$?
# STATUS=0 → сессия существует (живой worker)
# STATUS=1 → сессия не найдена (orphan)
```

### Шаг 3: Сбросить orphan-задачи в todo

Для каждой задачи где tmux-сессия не найдена:

```
mcp__saga-mcp__task_update(id: <task_id>, status: "todo")
```

### Шаг 4: Записать в autofix.log

```bash
echo "$(date '+%Y-%m-%d %H:%M') | RB-003 | orphan reset: ${SLUG} (#${TASK_ID})" >> "${CLAUDE_PROJECT_DIR}/logs/health/autofix.log"
```

### Шаг 5: Уведомить operator (только если были сброшены задачи)

```
[AUTOFIX OK] RB-003: сброшено N orphan-задач в todo: {slug1}, {slug2}
```

---

## RB-004: Dispatcher Restart

**Триггер:** `diagnosis_type = "dispatcher_gap"` — dispatcher не запускался более 45 минут.

### Шаг 1: Проверить последний выход dispatcher'а

```bash
USER_ID=$(id -u)
launchctl print "gui/${USER_ID}/com.novostudio.heartbeat-dispatcher" 2>&1 | grep -E "last-exit|time-since"
```

### Шаг 2: Kickstart dispatcher

Если пауза > 45 минут (2700 секунд):

```bash
USER_ID=$(id -u)
launchctl kickstart -k "gui/${USER_ID}/com.novostudio.heartbeat-dispatcher"
```

### Шаг 3: Записать в autofix.log

```bash
echo "$(date '+%Y-%m-%d %H:%M') | RB-004 | dispatcher restarted" >> "${CLAUDE_PROJECT_DIR}/logs/health/autofix.log"
```

### Шаг 4: Уведомить operator

```
[AUTOFIX OK] RB-004: dispatcher перезапущен (пауза была > 45 мин).
```

---

## RB-005: Zombie Flood

**Триггер:** `diagnosis_type = "zombie_loop"` — слишком высокая доля zombie workers за последние 2 часа.

### Шаг 1: Подсчитать zombie за 2 часа

```bash
TWO_HOURS_AGO=$(date -v-2H '+%Y-%m-%d %H:%M' 2>/dev/null || date -d '2 hours ago' '+%Y-%m-%d %H:%M')

ZOMBIE_COUNT=$(grep -E "zombie|crashed|MAX_ITER" "${CLAUDE_PROJECT_DIR}/memory/worker-errors.log" 2>/dev/null | \
  awk -v cutoff="${TWO_HOURS_AGO}" '$0 >= cutoff' | wc -l | tr -d ' ')
```

### Шаг 2: Подсчитать total workers за 2 часа

```bash
TOTAL_WORKERS=$(find "${CLAUDE_PROJECT_DIR}/logs/workers/" -maxdepth 1 -type d -newer /tmp/.rb005-marker 2>/dev/null | wc -l | tr -d ' ')
```

### Шаг 3: Вычислить zombie rate

```bash
if [ "${TOTAL_WORKERS}" -gt 0 ]; then
  ZOMBIE_RATE=$(( ZOMBIE_COUNT * 100 / TOTAL_WORKERS ))
else
  ZOMBIE_RATE=0
fi
```

### Шаг 4: При zombie_rate > 30% — выполнить flood mitigation

```bash
# 4a: Убить все worker-* tmux сессии
tmux ls 2>/dev/null | grep "^worker-" | cut -d: -f1 | while read SESSION; do
  tmux kill-session -t "${SESSION}" 2>/dev/null
done

KILLED_COUNT=$(tmux ls 2>/dev/null | grep -c "^worker-" || echo 0)
```

```
# 4b: Сбросить все in_progress задачи в todo
mcp__saga-mcp__task_list(status: "in_progress")
# Для каждой:
mcp__saga-mcp__task_update(id: <task_id>, status: "todo")
```

### Шаг 5: Записать в autofix.log

```bash
echo "$(date '+%Y-%m-%d %H:%M') | RB-005 | zombie flood: ${ZOMBIE_COUNT}/${TOTAL_WORKERS} (${ZOMBIE_RATE}%) | killed: ${KILLED_COUNT} workers" >> "${CLAUDE_PROJECT_DIR}/logs/health/autofix.log"
```

### Шаг 6: Уведомить operator

```
[AUTOFIX OK] RB-005: zombie flood detected (${ZOMBIE_RATE}%).
Убито ${KILLED_COUNT} worker-сессий. Все in_progress сброшены в todo.
```

---

## Эскалационная процедура (при auto_fixable=false)

Для `auth_expired` (RB-007) и `unknown` (RB-008):

### RB-007: Auth Expired

```
mcp__saga-mcp__task_create(
  epic_id: <infra_epic>,
  title: "ESCALATE: Auth истек для worker {task_slug}",
  description: "Worker {task_slug} вернул 401/Unauthorized.\n\nТребуется ручная авторизация:\n1. Определить какой сервис требует auth\n2. Пройти re-auth через браузер\n3. Обновить токены/cookies",
  priority: "high"
)
```

### RB-008: Unknown Pattern

```
mcp__saga-mcp__task_create(
  epic_id: <infra_epic>,
  title: "ESCALATE: Неизвестный паттерн краша — {task_slug}",
  description: "Worker крашился {crash_count} раз без известного паттерна.\nЛоги: logs/workers/{task_slug}/\nДиагноз: logs/health/diagnoses/{task_slug}-{timestamp}.json",
  priority: "medium"
)
```

---

## Финальный чеклист после любого Runbook

1. [ ] Результат записан в `logs/health/autofix.log`
2. [ ] Статус saga задачи обновлен (todo / blocked / escalation task создана)
3. [ ] Operator уведомлен (один из: OK / FAILED / ESCALATED)
4. [ ] При SUCCESS: проверить что fix сработал (второй health check / новый worker запустится)

---

## Связанные скиллы

- `self-heal-diagnose` — L2 диагностика (предыдущий шаг)
- `health-watchdog` — L1 detect, вызывает diagnose
