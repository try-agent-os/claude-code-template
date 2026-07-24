---
name: meeting-debrief
description: Обрабатывает прошедшую внешнюю встречу — Fireflies транскрипт → debrief → CRM задачи → timeline контакта. Запускается автоматически через 2ч после окончания.
when_to_use: Calendar-проверка нашла встречу, закончившуюся за последние 2ч и не обработанную; пользователь сказал "обработай встречу с {имя} от {дата}".
allowed-tools: Read, Grep, Edit, Write, Bash, mcp__claude_ai_Google_Calendar__list_events, mcp__claude_ai_Fireflies__fireflies_get_transcripts, mcp__claude_ai_Fireflies__fireflies_get_summary, mcp__claude_ai_Gmail__search_threads, mcp__claude-peers__send_message
---

# Meeting Debrief — Процедура AgentOS

## Когда вызывать

- Автоматически: при каждой calendar-проверке (каждые 2ч) искать встречи, которые закончились за последние 2ч и еще не обработаны
- Вручную: "обработай встречу с {имя} от {дата}"

**Проверка дублирования:** перед обработкой проверить `${CLAUDE_PROJECT_DIR}/memory/check-log.md` — запись `meeting-debrief-{event_id}`. Если уже есть — пропустить.

**Только внешние встречи.** Если встреча внутренняя (нет участников вне твоей команды) — пропустить.

## Зависимости

- Fireflies MCP — для транскриптов
- Google Calendar MCP — для определения встречи
- ClickUp / другой CRM — для синка action items
- claude-peers + operator — для отчёта в Telegram

## Шаги

### 1. Fireflies — запись встречи

```
fireflies_get_transcripts → найти по времени/участнику
fireflies_get_summary → темы, решения, action items
```

Извлечь:
- Ключевые темы обсуждения
- Принятые решения
- Action items (кто, что, когда)
- Следующие шаги

Если Fireflies не нашел запись — проверить через 30 мин (транскрипт может еще обрабатываться).

### 2. Loom — видео (если есть)

```
gmail_search_messages query "from:notifications@loom.com subject:{имя участника}"
```

Искать письма за последние 2ч. Если есть ссылка на Loom — извлечь и добавить в debrief.

### 3. Собрать debrief

```
📝 Встреча: {Имя} ({Компания}) — {дата}

Участники: {список}

Ключевые темы:
- {тема 1}
- {тема 2}

Решения:
- {решение 1}

Action items:
- [ ] {кто}: {что} — до {когда}
- [ ] {кто}: {что} — до {когда}

Следующие шаги:
- {следующий шаг}

Loom: {ссылка если есть}
```

### 4. Обновить CRM

```
clickup_search по имени участника → найти контакт/сделку
```

Настрой list IDs под свой workspace.

Добавить комментарий к контакту/задаче:
```
clickup_create_task_comment:
"Встреча {дата}: {краткое summary}. Action items: ..."
```

Если action items требуют отдельных задач:
```
clickup_create_task — создать задачу с due_date и assignee
```

### 5. Обновить timeline контакта

Найти файл `${CLAUDE_PROJECT_DIR}/memory/contacts/{slug}.md` (slug = имя-фамилия, lowercase, дефис).

Добавить в секцию `## Timeline`:
```
### YYYY-MM-DD HH:MM [fireflies]
Встреча: {краткое описание}. Action items: N. Следующий шаг: {шаг}.
```

Если нужно — обновить `## Статус` (pipeline, следующий шаг, дата обновления).

### 6. Обновить people.md

Добавить запись о встрече в `${CLAUDE_PROJECT_DIR}/memory/people.md` к соответствующему контакту:
```
- {YYYY-MM-DD}: встреча — {краткое резюме}
```

### 7. Залогировать

Записать в `${CLAUDE_PROJECT_DIR}/memory/check-log.md`:
```
meeting-debrief-{event_id}: YYYY-MM-DD HH:MM — {Имя}, N action items
```

Это предотвращает повторную обработку той же встречи.

### 8. Отчет в Telegram

Через claude-peers: `send_message(to_id: <operator_peer_id>, message: "<debrief>")`.

## Результат

- `${CLAUDE_PROJECT_DIR}/memory/contacts/{slug}.md` — обновлен timeline и статус
- `${CLAUDE_PROJECT_DIR}/memory/people.md` — добавлена запись о встрече
- CRM — добавлен комментарий + созданы action items как задачи
- `${CLAUDE_PROJECT_DIR}/memory/check-log.md` — залогирована обработка
- Telegram — краткий отчет

## Правила

- Только внешние встречи (есть участники вне твоей команды)
- Проверять check-log перед обработкой (не дублировать)
- Если Fireflies не нашел запись — ждать, не фейлиться
- Если человек новый — создать контакт и запустить скилл `contact-enrichment`
- Запускать как субагент с `run_in_background: true`
- CRM — добавлять информацию, не перезаписывать существующие заметки
