---
name: meeting-prep
description: Собирает брифинг перед внешней встречей из Fireflies, CRM, Gmail, Calendar и memory/people.md. Отправляет в Telegram за 30 мин до начала.
when_to_use: 'Calendar-проверка нашла встречу в следующие 30-60 мин; задача "Meeting prep" с названием встречи; пользователь сказал "подготовь брифинг к встрече с {имя}".'
allowed-tools: Read, Grep, Bash, mcp__claude_ai_Google_Calendar__list_events, mcp__claude_ai_Fireflies__fireflies_get_transcripts, mcp__claude_ai_Fireflies__fireflies_get_summary, mcp__claude_ai_Gmail__search_threads, mcp__claude-peers__send_message
---

# Meeting Prep — Процедура AgentOS

## Когда вызывать

- Автоматически: calendar-проверка (каждые 2ч) находит встречу в следующие 30-60 мин
- Проактивно: если в очереди задач создана задача `[MED] Meeting prep: {название встречи}`
- Вручную: "подготовь брифинг к встрече с {имя}"

**Только внешние встречи.** Если встреча внутренняя (нет участников вне твоей команды) — пропустить.

## Зависимости

- Google Calendar MCP — для определения встречи
- Fireflies MCP — для истории встреч (опционально)
- ClickUp MCP или другой CRM — для pipeline-статуса (опционально)
- Gmail MCP — для переписки
- claude-peers + operator — для отправки в Telegram

## Шаги

### 1. Определить участника

Из события календаря извлечь:
- Имя и email собеседника
- Название встречи
- Время начала
- Ссылка на Google Meet / Zoom (если есть)

Исключить из участников: владельца аккаунта.

### 2. Fireflies — история встреч

```
fireflies_get_transcripts → поиск по имени/email участника
```

Для каждой найденной встречи:
```
fireflies_get_summary → ключевые темы, решения, action items
```

Извлечь:
- Сколько встреч было с этим человеком
- Когда последняя
- Ключевые темы каждой встречи
- Что обещали мы, что обещали они
- Нерешенные вопросы

### 3. CRM — контекст из pipeline

```
clickup_search по имени участника
```

(или аналог в твоем CRM — настрой list IDs под свой workspace)

Извлечь:
- Статус в pipeline (COLD / OUTREACH / DISCOVERY / PROPOSAL / DEAL)
- Последние заметки по контакту
- Открытые задачи связанные с этим человеком

### 4. Gmail — переписка

```
gmail_search_messages query "from:{email} OR to:{email}"
```

Последние 5-10 писем. Извлечь:
- Ключевые темы переписки
- Последнее письмо — о чем?
- Есть ли открытые вопросы или ожидания?

### 5. memory/people.md

Найти записи по имени человека — дополнительный контекст который мог быть добавлен вручную (`${CLAUDE_PROJECT_DIR}/memory/people.md`).

### 6. Файл контакта

Если есть `${CLAUDE_PROJECT_DIR}/memory/contacts/{slug}.md` — прочитать:
- Секцию `## Статус` (pipeline, следующий шаг)
- Секцию `## Связи` (через кого познакомились)
- `## Timeline` (история взаимодействий)

### 7. Собрать брифинг

Компактный документ:

```
📋 Брифинг к встрече: {Имя} ({Компания}) — {время}

Кто: {имя}, {роль}, {компания}
Pipeline: {статус в CRM}

История встреч ({N} всего, последняя {дата}):
- {краткое резюме последней встречи}

Договоренности (открытые):
- Мы обещали: {список}
- Они обещали: {список}

Открытые вопросы:
- {нерешенные темы}

Последние письма: {краткие темы}

Контекст: {дополнительное из people.md}
```

### 8. Отправить в Telegram

За 30 мин до встречи через claude-peers → operator:

```bash
PEERS=$(curl -s http://127.0.0.1:7899/list-peers -H 'Content-Type: application/json' -d '{"scope":"machine","cwd":"/","git_root":null}')
OPERATOR_ID=$(echo "$PEERS" | python3 -c "import json,sys; peers=json.load(sys.stdin); print(next((p['id'] for p in peers if 'operator' in p.get('cwd','')), ''))")
```

**Не отправляй пустой брифинг** — только если нашел полезный контекст.

### 9. Обновить people.md

Если нашел новую информацию о человеке — добавить в `${CLAUDE_PROJECT_DIR}/memory/people.md`.

### 10. Синк с CRM

Если в Fireflies обнаружены action items или договоренности, которых нет в CRM:

```
clickup_create_task — создать задачу
# или
clickup_create_task_comment — добавить заметку к контакту
```

## Результат

- Брифинг отправлен в Telegram за 30 мин до встречи
- `${CLAUDE_PROJECT_DIR}/memory/people.md` обновлен (если нашел новое)
- CRM обновлен (если нашел пропущенные action items)

## Правила

- Только внешние встречи (есть участники вне твоей команды)
- Не отправлять пустой брифинг — только если есть полезный контекст
- Запускать как субагент с `run_in_background: true`
- Если человек новый (нет в Fireflies/CRM/people.md) — создать контакт и запустить скилл `contact-enrichment`
- Для обработки прошедшей встречи — использовать скилл `meeting-debrief`
