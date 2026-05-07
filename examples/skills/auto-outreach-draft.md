---
name: auto-outreach-draft
description: Генерирует outreach-драфт для компании из Mobile Prospects при Signal Score >= 4. Определяет канал, выбирает оффер, создает персонализированный текст и записывает в Google Sheets. Запускается после mobile-prospect-scan или opportunity-review.
type: procedure
trigger: outreach, драфт, email, cold email, написать, питч, связаться, draft
---

# Auto-Outreach Draft -- Процедура

Запускается из opportunity-review когда opportunity score >= 4, или из mobile-prospect-scan когда Signal Score = 5.

## Триггер
- `opportunity-review` выявил opportunity с score >= 4 и статусом `new` или `planned`
- `mobile-prospect-scan` нашел компанию с Signal Score 5
- Поле `next action` содержит "написать", "outreach", "связаться", "питч"

## Шаги

### 0. Pre-check (до генерации драфта)

Перед генерацией outreach — верифицируй что контакт не был reached раньше:

1. **Gmail:** `gmail_search_messages "from:{company_domain} OR to:{company_domain} newer_than:30d"` — был ли уже email-контакт в последние 30 дней?
   - Если да → НЕ генерировать новый драфт, отправить уведомление "Уже был контакт с {Company} {дата}: {тема письма}. Нужен follow-up, не cold outreach."
2. **Telegram:** проверь `memory/contacts/{slug}.md` → поле Telegram. Если есть и в Timeline недавняя запись → приоритет переписке в Telegram, не email.
3. **ClickUp:** если Status уже "contacted" или выше → skip (дублируется намеренно из шага 8 — для надежности).

Только после прохождения pre-check → переходить к шагу 1.

1. **Прочитай контекст компании** из Mobile Prospects через content-hub:
   ```bash
   curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/find_row \
     -H 'Content-Type: application/json' \
     -d '{"query": {"Company": "<company_name>"}}'
   ```
   Ответ содержит `{"rows": [{"rowIndex": N, "data": {...}}]}`. Сохрани `rowIndex` для шага 6.
   Извлеки: Description, Review Pain, Signal Score, Notes, DM Name, DM Email, DM LinkedIn.
2. **Прочитай лист Offers** из Google Sheets -- определи какой оффер подходит по сигналам:
   - App Rating < 4.0 или Last Update > 6 мес → "App Store Rescue"
   - Есть приложение, нужна поддержка → "Mobile Maintenance"
   - Нет приложения, конкуренты имеют → "Mobile Companion App"
   - Есть API, хотят AI → "Mobile AI Assistant"
3. **Прочитай контекст** `../../studio/identity/PRODUCT_DESCRIPTION.md` -- текущие услуги и позиционирование
4. **Определи канал:** LinkedIn (если есть DM LinkedIn) → Email (если есть DM Email) → Telegram
5. **Сгенерируй драфт** через Opus субагент:
   - Тон: персональный, конкретный, не шаблонный
   - Крюк: конкретный сигнал из таблицы (рейтинг, дата обновления, SDK дедлайн, жалобы юзеров)
   - Связь: почему наш оффер релевантен именно им
   - CTA: один конкретный шаг (звонок 15 мин, quick demo, вопрос)
   - Длина: до 100 слов для LinkedIn, до 150 для email
6. **Запиши драфт через content-hub** (используй `rowIndex` из шага 1):
   ```bash
   curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/update_row/{rowIndex} \
     -H 'Content-Type: application/json' \
     -d '{"Notes": "[DRAFT {date}] Channel: {channel}\n{текст драфта}", "Status": "draft_ready"}'
   ```
   Fallback: если hub недоступен (exit code != 0 или нет `"success":true`) -- записать `status: partial`.
   **Верификация:** после записи вызови find_row снова и убедись что Notes/Status обновились правильно.
7. **Отправь уведомление в Telegram:**
   ```
   📬 Новый outreach драфт: {Company} [score: {N}]
   Оффер: {offer_name}
   Канал: {channel}
   Драфт записан в таблицу Mobile Prospects.
   ```
8. **Обнови opportunity:** статус → `draft_ready`

## Правила
- Только один драфт за heartbeat цикл (не спамить)
- НЕ отправлять outreach автоматически -- только драфт в таблицу + уведомление
- Драфты хранятся в Google Sheets Mobile Prospects (колонка Notes) -- это single source of truth
- Если у компании нет DM Name/Email/LinkedIn -- сначала запусти Contact Enrichment или web search
- Если Status уже "contacted" или выше -- не генерировать новый драфт
- Если Status = "draft_ready" и возраст > 3 дней -- напомни в Telegram "Драфт для {Company} ждет 3+ дней"
