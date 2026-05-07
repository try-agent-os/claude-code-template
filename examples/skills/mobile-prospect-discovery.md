---
name: mobile-prospect-discovery
description: Активный поиск новых SaaS-компаний с мобильными приложениями для таблицы Mobile Prospects. Ротирует по 12 источникам (App Store, G2, Crunchbase, LinkedIn Jobs и др.) и вертикалям. Цель — 3-5 компаний за цикл.
type: procedure
trigger: discovery, поиск компаний, новые проспекты, mobile discovery, найти компании, App Store, SaaS
---

# Mobile Prospect Discovery -- Процедура

Активный поиск новых SaaS-компаний с мобильными приложениями для таблицы Mobile Prospects.

## Константы

- **Spreadsheet ID:** `1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4`
- **Sheet:** `Mobile Prospects`
- **Ротация источников:** храни индекс в `../../memory/check-log.md` ключ `mobile-discovery-source-index`. Каждый цикл берешь следующий источник из списка. Дошел до конца -- начинай сначала.

## Источники (ротация)

| # | Источник | Как искать | Что извлекать |
|---|----------|-----------|---------------|
| 1 | **App Store -- Business** | WebSearch "site:apps.apple.com business analytics saas" + WebFetch iTunes Search API по категории Business | Название, bundle ID, рейтинг, дата обновления, разработчик |
| 2 | **App Store -- Productivity** | WebSearch "site:apps.apple.com productivity saas B2B" + iTunes Search API категория Productivity | То же |
| 3 | **App Store -- Finance** | WebSearch "site:apps.apple.com finance analytics SaaS B2B" | То же |
| 4 | **Google Play -- Business** | WebSearch "site:play.google.com/store business analytics saas" | Название, package, рейтинг, обновление |
| 5 | **Product Hunt** | WebSearch "site:producthunt.com SaaS mobile app launched 2025 OR 2026" | Название, URL, описание, есть ли мобилка |
| 6 | **G2** | WebSearch "site:g2.com best SaaS mobile app low rating reviews" + WebSearch "site:g2.com {vertical} software mobile app" для текущей вертикали | Название, рейтинг, отзывы про мобилку |
| 7 | **Capterra** | WebSearch "site:capterra.com {vertical} software mobile app" | То же |
| 8 | **Clutch** | WebSearch "site:clutch.co mobile app development company hiring" -- тут ищем НЕ агентства, а их клиентов (компании ищущие mobile dev) | Название компании-заказчика |
| 9 | **Crunchbase** | WebSearch "site:crunchbase.com series A OR series B 2025 OR 2026 mobile app" | Компания, раунд, сумма |
| 10 | **LinkedIn Jobs** | WebSearch "site:linkedin.com/jobs mobile developer react native OR flutter OR iOS" + фильтр на SaaS-компании (не агентства) | Компания, позиция, как давно висит |
| 11 | **Upwork** | WebSearch "site:upwork.com/jobs mobile app maintenance OR support OR update iOS android" | Заказ, бюджет, описание, заказчик |
| 12 | **Reddit** | WebSearch "site:reddit.com SaaS mobile app terrible OR outdated OR needs update" | Упоминания компаний с плохими мобилками |

## Вертикали для поиска (расширяющийся список)

Начинаем с AdTech (уже в таблице). Каждую неделю добавляй новую вертикаль:
- W1 (апрель): AdTech, MarTech
- W2: FinTech, HR-tech
- W3: HealthTech, EdTech
- W4: E-commerce tools, Logistics-tech
- W5+: AI/ML tools, DevTools, Legal-tech, Real Estate tech

Храни текущую вертикаль в `../../memory/check-log.md` ключ `mobile-discovery-vertical`.

## Шаги

1. **Определи источник** по индексу ротации и текущую вертикаль.

2. **Запусти субагента** (run_in_background: true, model: sonnet):

```
Поиск новых SaaS-компаний с мобильными приложениями.

Источник: {source}
Вертикаль: {vertical}

Задача:
1. Выполни поиск по инструкции для этого источника (WebSearch + WebFetch)
2. Найди 3-5 компаний, которые:
   - Имеют мобильное приложение (iOS и/или Android)
   - Являются SaaS/B2B (не consumer apps, не игры)
   - Команда 10-200 человек (слишком маленькие не платят, слишком большие имеют свою команду)
   - НЕ являются mobile-first компаниями (мобилка = companion к вебу)
3. Для каждой компании собери:
   - Company Name, URL
   - Vertical (AdTech/MarTech/FinTech/...)
   - Employees (приблизительно)
   - iOS URL / Android URL (если есть)
   - Last Update (из стора если доступно)
   - App Rating
   - Description (одно предложение)
   - DM Name, Title, LinkedIn (CEO/CTO/VP Eng -- один лучший контакт)
   - Initial Signal Score (1-5)

4. Проверь что компании НЕТ в таблице (дедупликация через content-hub):
   ```bash
   curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/find_row \
     -H 'Content-Type: application/json' \
     -d '{"query": {"Company": "<company_name>"}}'
   ```
   Если ответ содержит `"count":0` -- компании нет, добавляй. Если `count > 0` -- пропусти.

5. Для каждой новой компании добавь строку через content-hub:
   ```bash
   curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/add_row \
     -H 'Content-Type: application/json' \
     -d '{"Company": "<name>", "URL": "<url>", "Vertical": "<vertical>", "Employees": "<N>", "Description": "<desc>", "iOS URL": "<ios_url>", "Android URL": "<android_url>", "Last Update": "<date>", "App Rating": "<rating>", "Signal Score": <score>, "DM Name": "<dm_name>", "DM Title": "<dm_title>", "DM LinkedIn": "<dm_linkedin>", "Status": "new", "Notes": "<notes>"}'
   ```
   Если curl exit code != 0 или response не содержит `"success":true` -- записать в result.md `status: partial`. НЕ писать напрямую в Sheets через MCP.

   **Notes обязательно включают источник в формате:**
   `Found via {source} | [source_type|YYYY-MM-DD|URL|описание]`
   Пример: `Found via LinkedIn Jobs | [hiring|2026-04-10|https://linkedin.com/jobs/view/4123456|Senior iOS Dev, B2B SaaS]`

6. Верни список добавленных компаний с кратким описанием каждой.
```

3. **Алерт в Telegram** -- если нашел 2+ компании:
   ```
   Discovery [{source}]: +{N} новых компаний
   {список: Company -- vertical -- score}
   Таблица Mobile Prospects обновлена.
   ```

4. **Обнови check-log:** `mobile-prospect-discovery` + `mobile-discovery-source-index`.

## Сохранение источников (ОБЯЗАТЕЛЬНО)

При добавлении компании в таблицу — Notes (последняя колонка) ВСЕГДА содержит:
1. Источник (откуда найдена): `Found via {source_name}`
2. URL первичного сигнала в формате: `[signal_type|YYYY-MM-DD|URL|описание]`

Формат Notes: `Found via {source} | [signal_type|YYYY-MM-DD|URL|описание]`

Пример для LinkedIn Jobs: `Found via LinkedIn Jobs | [hiring|2026-04-10|https://linkedin.com/jobs/view/4123456|Senior iOS Dev, B2B SaaS, 50-200 emp]`
Пример для App Store: `Found via App Store Business | [ios_rating|2026-04-10|https://apps.apple.com/us/app/example/id123|Rating 2.3, 180 reviews, last update 2024-08]`

Если URL недоступен: `Found via {source} | [signal_type|YYYY-MM-DD|NO_URL|описание почему]`

**Правило:** сигнал без URL — unverifiable через 7+ дней. Всегда сохраняй URL в момент нахождения.

## Правила
- Запускай как субагент (run_in_background: true) -- не блокируй основной цикл
- Один источник за цикл -- не пытайся покрыть все за раз
- Дедупликация обязательна -- проверяй таблицу перед добавлением
- Не добавляй consumer apps (Instagram, TikTok, Spotify), игры, mobile-first компании
- Не добавляй компании < 10 человек (не заплатят $3-5K/мес) и > 200 (у них своя команда)
- Signal Score при discovery = предварительный (3 по умолчанию). mobile-prospect-scan потом уточнит
- Если источник не дал результатов -- просто переходи к следующему, не фейлись
- Цель: 3-5 новых компаний за цикл, 15-20 в неделю, 100+ к концу Q2
