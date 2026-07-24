---
name: clickup-sync
description: Синхронизирует ClickUp Pipeline и Contacts в memory/people.md. Детектирует изменения статусов сделок, верифицирует критические события через Gmail. Запускается каждые 2ч или вручную.
when_to_use: По расписанию каждые 2ч; пользователь сказал "синхронизируй ClickUp", "обнови pipeline", "статус сделки".
allowed-tools: Read, Edit, Bash, mcp__claude_ai_ClickUP__clickup_filter_tasks, mcp__claude_ai_ClickUP__clickup_search, mcp__claude_ai_Gmail__search_threads
disable-model-invocation: true
---

# ClickUp Sync — Процедура

> Скилл пишет в `memory/people.md` (перезаписывает секции). `disable-model-invocation: true` — запускается только явно из task/scheduler, не autoselect.

## Зависимости

- ClickUp MCP (`mcp__claude_ai_ClickUP__*`)
- Gmail MCP (для верификации критических изменений)
- `${CLAUDE_PROJECT_DIR}/memory/people.md`

## Константы (адаптируй под свой workspace)

| Что | List ID |
|-----|---------|
| Sales/Pipeline | `<твой-pipeline-list-id>` |
| Sales/Contacts | `<твой-contacts-list-id>` |
| Доп. workspace задач | `<твой-tasks-workspace-id>` |

Заполни ID в первой строке скилла или в `${CLAUDE_PROJECT_DIR}/memory/clickup-config.md`.

## Шаги

1. **Pull Pipeline:** `clickup_filter_tasks` list_id `<pipeline-list-id>` → обновить `## Pipeline (из ClickUp)` в `${CLAUDE_PROJECT_DIR}/memory/people.md`
2. **Pull Contacts:** `clickup_filter_tasks` list_id `<contacts-list-id>` → обновить `## CRM (из ClickUp)` в `${CLAUDE_PROJECT_DIR}/memory/people.md`
3. **Pull задачи на сегодня:** `clickup_filter_tasks` по workspace, фильтр due_date = today.
4. **Детект изменений:** `git diff ${CLAUDE_PROJECT_DIR}/memory/people.md` — новый контакт, смена статуса, новая сделка → отметить в отчете

### 4.5. Верификация критических изменений

Если git diff показал смену статуса сделки (PROPOSAL → DEAL, появился новый контракт, DocuSign активность):

1. **Gmail:** `gmail_search_messages "from:{contact_domain} newer_than:7d"` — подтверждает ли email смену статуса?
   - Подтверждает → отметить в отчете "VERIFIED: Gmail + ClickUp"
   - Не подтверждает → отметить "UNVERIFIED: только ClickUp, проверь вручную"
2. **Не отправляй алерт о сделке** без верификации из второго источника.
3. Если ClickUp показывает сделку, но Gmail молчит → запиши в signals.md статус "unverified" и создай задачу [LOW] "Верифицировать статус {Company} в ClickUp"

5. **Фиксация:** `git add ${CLAUDE_PROJECT_DIR}/memory/people.md ${CLAUDE_PROJECT_DIR}/memory/check-log.md && git commit -m "sync: clickup CRM + pipeline" && git push`

**Конфликты:** ClickUp — source of truth для CRM. Полностью перезаписывать секции Pipeline и CRM. Секции вне ClickUp (например "Контакты из Telegram") НЕ трогать.
