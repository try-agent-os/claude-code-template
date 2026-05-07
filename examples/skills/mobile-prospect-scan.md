---
name: mobile-prospect-scan
description: Непрерывный ресерч компаний из таблицы Mobile Prospects. Проверяет App Store рейтинги, найм, фандинг, SDK compliance и жалобы пользователей. Обновляет Signal Score. Запускается каждые 20 минут ротацией по 1-2 компании.
type: procedure
trigger: mobile, prospect, scan, mobile scan, App Store, рейтинг, лид, SDK, signal score
---

# Mobile Prospect Scan -- Процедура

Непрерывный ресерч компаний из таблицы Mobile Prospects. Цель -- накапливать сигналы для outreach: обновления приложений, найм, раунды, боли.

## Константы

- **Spreadsheet ID:** `1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4`
- **Sheet:** `Mobile Prospects`
- **Ротация:** храни индекс последней проверенной строки в `../../memory/check-log.md` ключ `mobile-prospect-scan-index`. Каждый цикл берешь следующие 1-2 компании. Дошел до конца -- начинай сначала.

## Триггер

Каждые 20 минут (проверяй `last_check` в check-log). Выполняется даже если есть задачи в queue -- это фоновый процесс через субагента.

## Шаги

1. **Прочитай таблицу через content-hub:**
   ```bash
   curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/find_row \
     -H 'Content-Type: application/json' \
     -d '{"query": {}}'
   ```
   Ответ: `{"success": true, "count": N, "rows": [{"rowIndex": 2, "data": {"Company": "...", ...}}, ...]}`.
   Определи следующие 1-2 компании по индексу ротации.
   Fallback: если hub недоступен (exit code != 0) -- записать `status: partial` в result.md и завершить.

2. **Pre-filter (ОБЯЗАТЕЛЬНО перед ресерчем):** для каждой компании проверь:
   - Есть ли iOS URL (колонка G) или Android URL (колонка H)? Если оба пустые -- **skip** с записью в check-log "dismissed: {company} -- no app URL". Переходи к следующей компании.
   - Signal Score (колонка O) уже = 1? Skip -- LOW PRIORITY.
   - Employees < 10? Skip -- слишком маленькая, не заплатят.
   - Если `mobile-scan-dismissed-streak` в check-log >= 4 -- значит текущий сегмент исчерпан. Инкрементируй `mobile-discovery-vertical` (добавь следующую вертикаль) и сбрось streak в 0.

3. **Запусти субагента** (run_in_background: true, model: sonnet) для каждой компании. Промпт субагенту:

```
Ресерч компании {Company} ({URL}) для Novo Studio -- ищем сигналы что им нужна помощь с мобильным приложением.

Выполни ВСЕ проверки:

1. **App Store (если есть iOS URL):**
   WebFetch `https://itunes.apple.com/lookup?bundleId={bundle_id}` ИЛИ поиск по названию `https://itunes.apple.com/search?term={company}&entity=software`
   Извлеки: currentVersionReleaseDate, averageUserRating, version, description

2. **Google Play (если есть Android URL):**
   WebSearch "{company} app android play store update"

3. **Блог/новости компании:**
   WebSearch "{company} blog mobile app" OR "{company} mobile update 2026"
   WebSearch "{company} press release 2026"

4. **Найм:**
   WebSearch "site:linkedin.com/jobs {company} mobile developer OR react native OR flutter OR iOS OR android"
   WebSearch "{company} careers mobile"

5. **Фандинг/раунды:**
   WebSearch "{company} funding series seed 2025 OR 2026"
   WebSearch "site:crunchbase.com {company}"

6. **Жалобы юзеров:**
   WebSearch "{company} app review bugs OR slow OR crash site:reddit.com OR site:g2.com OR site:trustpilot.com"

7. **Конкуренты обновились?**
   WebSearch "{company} vs competitors mobile app 2026"

8. **SDK Compliance:**
   WebSearch "Apple iOS SDK requirements 2026 deadline" OR "Google Play target API level requirements 2026"
   Если Last App Update старше 6 мес -- проверь: приложение скорее всего не соответствует текущим требованиям Apple/Google.
   Актуальные требования (обновляй при каждом скане):
   - Apple: минимальный Xcode, iOS SDK version, Privacy Manifest дедлайны
   - Google: target API level (targetSdkVersion), Play Integrity, данные безопасности
   WebSearch "app store removal outdated SDK 2026"
   Сравни дедлайны с Last App Update компании:
   - Если последний релиз был ДО введения нового требования -- приложение 100% не соответствует
   - Если дедлайн через 1-3 мес и приложение не обновлялось -- ГОРЯЧИЙ сигнал (score +2)
   - Если дедлайн прошел и приложение не обновлялось -- КРИТИЧЕСКИЙ сигнал (приложение могут убрать из стора)
   Запиши актуальные дедлайны в `../../memory/sdk-deadlines.md` (создай если нет) -- обновляй раз в неделю.

Верни структурированный результат:
- **Last App Update:** дата и что обновили (если нашел)
- **App Rating:** текущий рейтинг iOS/Android
- **Hiring Mobile:** да/нет, какие позиции
- **Recent Funding:** раунд, сумма, дата
- **Blog/News Signals:** ключевые находки
- **User Complaints:** ключевые жалобы
- **Competitor Pressure:** кто обновился, что делают
- **SDK Compliance:** соответствует ли текущим требованиям Apple/Google, ближайший дедлайн, риск удаления из стора
- **Signal Score (1-5):** твоя оценка -- насколько горячий лид
- **Recommended Action:** что делать (outreach/wait/drop)
- **Notes:** все что не влезло выше
```

3. **Обнови таблицу через content-hub:** когда субагент вернется -- запиши результаты. Используй `rowIndex` из шага 1 (find_row ответ):
   ```bash
   curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/update_row/{rowIndex} \
     -H 'Content-Type: application/json' \
     -d '{"Last Update": "<date>", "App Rating": "<rating>", "Review Pain": "<pain>", "Mobile Devs": "<N or hiring>", "Open Mobile Position": "<да/нет + срок>", "Signal Score": <N>, "Notes": "<findings | [signal|date|url|desc]>"}'
   ```
   Колонки для обновления:
   - `Last Update` -- актуальная дата скана
   - `App Rating` -- текущий рейтинг
   - `Review Pain` -- обновить если нашел новые жалобы
   - `Mobile Devs` -- кол-во или "hiring"
   - `Open Mobile Position` -- да/нет + как давно
   - `Signal Score` -- обновить по результатам ресерча
   - `Notes` -- ключевые находки с источниками
   Fallback: если hub недоступен (exit code != 0) -- записать `status: partial`, не использовать MCP напрямую.

## Сохранение источников (ОБЯЗАТЕЛЬНО)

Каждый сигнал должен иметь URL первоисточника в колонке `Notes` (W).

Формат: `[signal_type|YYYY-MM-DD|URL|description]`

Примеры:
- `[hiring|2026-04-05|https://linkedin.com/jobs/view/4123456|Senior iOS Dev, Chennai, Swift+RN]`
- `[ios_rating|2026-04-10|https://apps.apple.com/us/app/example/id12345|Rating 2.1, 340 reviews]`
- `[funding|2026-04-08|https://crunchbase.com/organization/example|Series A $5M, Mar 2026]`
- `[android_gap|2026-04-10|https://play.google.com/store/apps/details?id=com.example|App removed from Play Store]`

Типы сигналов:
- `hiring` — URL вакансии (LinkedIn/Workable/Greenhouse/etc) + должность + дата + платформа
- `ios_rating` — App Store URL + количество reviews + дата скана
- `android_gap` — Play Store URL или объяснение отсутствия (removed/never existed)
- `funding` — Crunchbase/пресс-релиз URL + сумма + дата раунда
- `sdk_risk` — ссылка на требование Apple/Google + дедлайн + текущая версия приложения
- `user_pain` — ссылка на отзыв (G2/Reddit/Trustpilot) + суть жалобы
- `linkedin_contact` — LinkedIn URL ЛПР

**Правило:** если URL не найден — записать `[signal_type|YYYY-MM-DD|NO_URL|описание_источника]`. Никогда не оставлять Notes без указания источника сигнала.

### 4.5. Pre-alert CRM check (перед алертом при Score >= 4)

Перед отправкой алерта или созданием outreach задачи:

1. **ClickUp pipeline:** `clickup_search "{company}"` в list 901513408029 (Sales/Pipeline) и 901511168305 (Sales/Contacts)
   - Если статус "contacted" или выше → НЕ создавать outreach задачу, вместо этого: "Follow-up с {Company}: уже в pipeline ({статус})"
   - Если статус "DEAL" → алерт: "Действующий клиент {Company} в mobile-scan — убрать из ротации"
2. **Gmail:** `gmail_search_messages "from:{company_domain} OR {company_name} newer_than:30d"`
   - Если есть переписка → добавить к алерту "Примечание: уже был email-контакт {дата}"
3. **memory/contacts/{slug}.md:** если файл существует → прочитать Timeline (последние 2 записи)
   - Если в Timeline запись < 14 дней → не создавать новую outreach задачу

Только после прохождения → создавать задачу/алерт.

4. **Уведомление в Telegram** -- краткое, после записи в таблицу:
   ```
   Добавлено/обновлено N проспектов в таблицу: {Company1} {Score}/5, {Company2} {Score}/5
   ```
   Без деталей, без approve -- пользователь сам посмотрит в таблице. Детальные данные только в Google Sheet.

5. **Обнови check-log:** записать `mobile-prospect-scan` + `mobile-prospect-scan-index` с новым значением.

## Правила
- Запускай как субагент (run_in_background: true) -- НЕ блокируй основной цикл
- 1-2 компании за цикл, не больше -- экономия контекста и rate limits
- Если компания только что просканирована (<24ч) -- пропусти, возьми следующую
- Если Score обновился до 5 -- создай задачу через saga-mcp (epic_id: 1, priority: high): `Outreach: {Company} -- {signal}`
- Если Score упал до 1 -- добавь в Notes "LOW PRIORITY" и пропускай при ротации
- Новые компании можно добавлять в таблицу вручную или через оркестратора -- heartbeat подхватит их при следующей ротации
- **Расширение списка:** если при ресерче компании нашел похожую SaaS-компанию с мобильным приложением (конкурент, партнер, упомянута в статье) -- добавь новую строку в таблицу со статусом "new" и Signal Score 3

## Playwright MCP — когда использовать

Playwright MCP установлен в user config Claude Code (`~/.claude.json`), но **недоступен в worker сессиях** (claude -p без --dangerously-load-development-channels).

### В mobile-prospect-scan: НЕ использовать вместо iTunes API

iTunes Lookup API даёт все нужные данные структурированно и быстро:
```
https://itunes.apple.com/search?term={company}&entity=software&country=us&limit=1
# → trackName, version, currentVersionReleaseDate, averageUserRating, userRatingCount
```

### Playwright MCP НЕ поможет с G2/Capterra

G2 и Capterra защищены Cloudflare — блокируют headless браузеры так же, как curl. WebSearch по этим сайтам остаётся единственным рабочим подходом.

### Когда Playwright реально нужен (в интерактивных сессиях)

- JS-rendered страницы без API (WebFetch возвращает пустую оболочку)
- One-off ресерч конкретной страницы
- Форм-филлинг, скриншоты для документации

Детальный evaluation: [`research/playwright-mcp/evaluation.md`](https://github.com/novostudiotech/claude/blob/main/research/playwright-mcp/evaluation.md)

---

## Правило автосмены вертикали

Веди счетчик `mobile-scan-dismissed-streak` в `../../memory/check-log.md`.
- После каждого dismissed-результата: increment счетчика
- После каждого HIGH/MED сигнала: сбросить счетчик в 0
- Если streak >= 3: добавить запись в check-log `mobile-scan-vertical-switch: pending`
- В следующем цикле при наличии маркера: сбросить `mobile-prospect-scan-index` на начало следующей вертикали, убрать маркер
