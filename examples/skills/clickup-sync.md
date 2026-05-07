---
name: clickup-sync
description: Синхронизирует ClickUp Pipeline и Contacts в memory/people.md. Детектирует изменения статусов сделок, верифицирует критические события через Gmail. Запускается каждые 2ч или по запросу.
type: procedure
trigger: clickup, задачи, sync, pipeline, CRM, контакты, статус сделки
---

# ClickUp Sync -- Процедура

## Константы

| Что | Workspace | List ID |
|-----|-----------|---------|
| Sales/Pipeline | Novo Studio (90151018528) | 901513408029 |
| Sales/Contacts | Novo Studio (90151018528) | 901511168305 |
| Symoditi задачи | PRPillar (4557261) | Space 90123497935 |

## Шаги

1. **Pull Pipeline:** `clickup_filter_tasks` list_id `901513408029` -> обновить `## Pipeline (из ClickUp)` в `../../memory/people.md`
2. **Pull Contacts:** `clickup_filter_tasks` list_id `901511168305` -> обновить `## CRM (из ClickUp)` в `../../memory/people.md`
3. **Pull Symoditi задачи на сегодня:** `clickup_filter_tasks` по workspace PRPillar, фильтр due_date = today. Fallback: списки 901209108934 и последний спринт в folder 90125377711
4. **Детект изменений:** `git diff ../../memory/people.md` -- новый контакт, смена статуса, новая сделка -> отметить в отчете

### 4.5. Верификация критических изменений

Если git diff показал смену статуса сделки (PROPOSAL → DEAL, появился новый контракт, DocuSign активность):

1. **Gmail:** `gmail_search_messages "from:{contact_domain} newer_than:7d"` — подтверждает ли email смену статуса?
   - Подтверждает → отметить в отчете "VERIFIED: Gmail + ClickUp"
   - Не подтверждает → отметить "UNVERIFIED: только ClickUp, проверь вручную"
2. **Не отправляй алерт о сделке** без верификации из второго источника.
3. Если ClickUp показывает сделку, но Gmail молчит → запиши в signals.md статус "unverified" и создай задачу [LOW] "Верифицировать статус {Company} в ClickUp"

5. **Фиксация:** `git add ../../memory/people.md ../../memory/check-log.md && git commit -m "sync: clickup CRM + pipeline" && git push`

**Конфликты:** ClickUp -- source of truth для CRM. Полностью перезаписывать секции Pipeline и CRM. Секцию "Контакты из Telegram" НЕ трогать.
