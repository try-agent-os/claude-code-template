---
name: mobile-prospect-scan
description: Непрерывный ресерч компаний из таблицы Mobile Prospects. Проверяет App Store рейтинги, найм, фандинг, SDK compliance и жалобы пользователей. Обновляет Signal Score. Запускается каждые 20 минут ротацией по 1-2 компании.
when_to_use: По расписанию каждые 20 мин (ротация 1-2 компании); пользователь сказал "просканируй мобайл", "mobile scan", "App Store", "рейтинг", "лид", "SDK", "signal score".
allowed-tools: Read, Edit, Write, Bash, WebSearch, WebFetch, mcp__claude_ai_ClickUP__clickup_search, mcp__claude_ai_Gmail__search_threads, mcp__saga-mcp__task_create, mcp__claude-peers__send_message
---

# Mobile Prospect Scan — Процедура

> **DEMONSTRATION ONLY.** Этот скилл — Novo Studio-specific. Конкретная Google Sheet, формат колонок, маппинг сигналов под мобильную разработку. Скопируй и адаптируй под свой prospect tracker.

Непрерывный ресерч компаний из таблицы Mobile Prospects. Цель — накапливать сигналы для outreach: обновления приложений, найм, раунды, боли.

## Зависимости

- Google Sheet "Mobile Prospects" + content-hub HTTP-сервис (или прямой Sheets MCP)
- WebSearch / WebFetch
- iTunes API (публичный, не требует ключа): `https://itunes.apple.com/lookup?bundleId={bundle_id}`
- ClickUp MCP / CRM (для pre-alert check)
- Gmail MCP (для проверки переписки)
- saga-mcp (для создания outreach-задач при Score=5)

## Константы

- **Spreadsheet ID:** `<твой-google-sheet-id>` (для Novo: `1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4`)
- **Sheet:** `Mobile Prospects`
- **Ротация:** храни индекс последней проверенной строки в `${CLAUDE_PROJECT_DIR}/memory/check-log.md` ключ `mobile-prospect-scan-index`. Каждый цикл берешь следующие 1-2 компании.

## Триггер

Каждые 20 минут (проверяй `last_check` в check-log). Выполняется даже если есть задачи в queue — это фоновый процесс через субагента.

## Шаги

1. **Прочитай таблицу через content-hub:**
   ```bash
   curl -s -X POST http://localhost:7901/sheets/<SPREADSHEET_ID>/find_row \
     -H 'Content-Type: application/json' \
     -d '{"query": {}}'
   ```
   Ответ: `{"success": true, "count": N, "rows": [{"rowIndex": 2, "data": {"Company": "...", ...}}, ...]}`.
   Определи следующие 1-2 компании по индексу ротации.
   Fallback: если hub недоступен — записать `status: partial` в result.md и завершить.

2. **Pre-filter (ОБЯЗАТЕЛЬНО перед ресерчем):** для каждой компании проверь:
   - Есть ли iOS URL (колонка G) или Android URL (колонка H)? Если оба пустые — **skip** с записью в check-log "dismissed: {company} — no app URL".
   - Signal Score (колонка O) уже = 1? Skip — LOW PRIORITY.
   - Employees < 10? Skip — слишком маленькая, не заплатят.
   - Если `mobile-scan-dismissed-streak` в check-log >= 4 — значит текущий сегмент исчерпан. Инкрементируй `mobile-discovery-vertical` и сбрось streak в 0.

3. **Запусти субагента** (run_in_background: true, model: sonnet) для каждой компании. Промпт:

```
Ресерч компании {Company} ({URL}) — ищем сигналы что им нужна помощь с мобильным приложением.

Выполни ВСЕ проверки:

1. **App Store (если есть iOS URL):**
   WebFetch https://itunes.apple.com/lookup?bundleId={bundle_id} ИЛИ поиск по названию
   Извлеки: currentVersionReleaseDate, averageUserRating, version, description

2. **Google Play (если есть Android URL):**
   WebSearch "{company} app android play store update"

3. **Блог/новости компании:**
   WebSearch "{company} blog mobile app" OR "{company} mobile update 2026"

4. **Найм:**
   WebSearch "site:linkedin.com/jobs {company} mobile developer OR react native OR flutter OR iOS OR android"

5. **Фандинг/раунды:**
   WebSearch "{company} funding series seed 2025 OR 2026"

6. **Жалобы юзеров:**
   WebSearch "{company} app review bugs OR slow OR crash site:reddit.com OR site:g2.com"

7. **Конкуренты обновились?**
   WebSearch "{company} vs competitors mobile app 2026"

8. **SDK Compliance:**
   WebSearch "Apple iOS SDK requirements 2026 deadline" OR "Google Play target API level requirements 2026"
   Сравни дедлайны с Last App Update компании:
   - Если последний релиз был ДО введения нового требования — приложение 100% не соответствует
   - Если дедлайн через 1-3 мес и приложение не обновлялось — ГОРЯЧИЙ сигнал (score +2)
   - Если дедлайн прошел и приложение не обновлялось — КРИТИЧЕСКИЙ сигнал

Верни структурированный результат:
- Last App Update, App Rating, Hiring Mobile, Recent Funding, Blog/News Signals, User Complaints, Competitor Pressure, SDK Compliance, Signal Score (1-5), Recommended Action, Notes
```

4. **Обнови таблицу через content-hub:** когда субагент вернется — запиши результаты используя `rowIndex` из шага 1:
   ```bash
   curl -s -X POST http://localhost:7901/sheets/<SPREADSHEET_ID>/update_row/{rowIndex} \
     -H 'Content-Type: application/json' \
     -d '{"Last Update": "<date>", "App Rating": "<rating>", "Review Pain": "<pain>", "Mobile Devs": "<N>", "Open Mobile Position": "<да/нет>", "Signal Score": <N>, "Notes": "<findings | [signal|date|url|desc]>"}'
   ```

## Сохранение источников (ОБЯЗАТЕЛЬНО)

Каждый сигнал должен иметь URL первоисточника в колонке `Notes`.

Формат: `[signal_type|YYYY-MM-DD|URL|description]`

Примеры:
- `[hiring|2026-04-05|https://linkedin.com/jobs/view/4123456|Senior iOS Dev, Chennai, Swift+RN]`
- `[ios_rating|2026-04-10|https://apps.apple.com/us/app/example/id12345|Rating 2.1, 340 reviews]`
- `[funding|2026-04-08|https://crunchbase.com/organization/example|Series A $5M, Mar 2026]`
- `[android_gap|2026-04-10|https://play.google.com/store/apps/details?id=com.example|App removed from Play Store]`

Типы сигналов:
- `hiring`, `ios_rating`, `android_gap`, `funding`, `sdk_risk`, `user_pain`, `linkedin_contact`

**Правило:** если URL не найден — записать `[signal_type|YYYY-MM-DD|NO_URL|описание_источника]`.

### 4.5. Pre-alert CRM check (перед алертом при Score >= 4)

Перед отправкой алерта или созданием outreach задачи:

1. **ClickUp pipeline:** `clickup_search "{company}"` в Sales/Pipeline и Sales/Contacts list
   - Если статус "contacted" или выше → НЕ создавать outreach задачу: "Follow-up с {Company}: уже в pipeline ({статус})"
   - Если статус "DEAL" → "Действующий клиент {Company} в mobile-scan — убрать из ротации"
2. **Gmail:** `gmail_search_messages "from:{company_domain} OR {company_name} newer_than:30d"`
   - Если есть переписка → добавить к алерту "Примечание: уже был email-контакт {дата}"
3. **memory/contacts/{slug}.md:** если файл существует → прочитать Timeline (последние 2 записи)
   - Если в Timeline запись < 14 дней → не создавать новую outreach задачу

### 5. Уведомление в Telegram

```
Добавлено/обновлено N проспектов в таблицу: {Company1} {Score}/5, {Company2} {Score}/5
```

Без деталей, без approve — пользователь сам посмотрит в таблице.

### 6. Обнови check-log:

записать `mobile-prospect-scan` + `mobile-prospect-scan-index` с новым значением.

## Правила

- Запускай как субагент (run_in_background: true)
- 1-2 компании за цикл, не больше — экономия контекста и rate limits
- Если компания только что просканирована (<24ч) — пропусти
- Если Score обновился до 5 — создай задачу через saga-mcp (epic Mobile Pipeline, priority: high): `Outreach: {Company} — {signal}`
- Если Score упал до 1 — добавь в Notes "LOW PRIORITY" и пропускай при ротации
- **Расширение списка:** если при ресерче нашел похожую SaaS-компанию (конкурент, партнер, упомянут в статье) — добавь новую строку в таблицу со статусом "new" и Signal Score 3

## Правило автосмены вертикали

Веди счетчик `mobile-scan-dismissed-streak` в `${CLAUDE_PROJECT_DIR}/memory/check-log.md`.
- После каждого dismissed-результата: increment счетчика
- После каждого HIGH/MED сигнала: сбросить счетчик в 0
- Если streak >= 3: добавить запись в check-log `mobile-scan-vertical-switch: pending`
- В следующем цикле при наличии маркера: сбросить `mobile-prospect-scan-index` на начало следующей вертикали, убрать маркер
