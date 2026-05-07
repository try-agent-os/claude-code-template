---
name: mobile-prospect-discovery
description: Активный поиск новых SaaS-компаний с мобильными приложениями для таблицы Mobile Prospects. Ротирует по 12 источникам (App Store, G2, Crunchbase, LinkedIn Jobs и др.) и вертикалям. Цель — 3-5 компаний за цикл.
when_to_use: Регулярный prospect discovery; пользователь сказал "discovery", "поиск компаний", "новые проспекты", "mobile discovery", "найди компании", "App Store", "SaaS".
allowed-tools: Read, Edit, Write, Bash, WebSearch, WebFetch, mcp__claude-peers__send_message
---

# Mobile Prospect Discovery — Процедура

> **DEMONSTRATION ONLY.** Этот скилл специфичен для Novo Studio — поиск SaaS-компаний с мобильными приложениями для предложения mobile-разработки и поддержки. Скопируй и адаптируй под свой продукт: замени источники, вертикали, целевой профиль клиента, ID Google Sheet, структуру колонок.

Активный поиск новых SaaS-компаний с мобильными приложениями для таблицы Mobile Prospects.

## Зависимости

- Google Sheet "Mobile Prospects" (или твой эквивалентный prospect-tracker)
- HTTP-сервис content-hub на `localhost:7901` (для записи в Sheets через REST API) — опционально, можно заменить на прямой Google Sheets MCP
- WebSearch / WebFetch для источников
- claude-peers + operator (для алертов в Telegram, опционально)

## Константы

- **Spreadsheet ID:** `<твой-google-sheet-id>` (для Novo: `1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4`)
- **Sheet:** `Mobile Prospects`
- **Ротация источников:** храни индекс в `${CLAUDE_PROJECT_DIR}/memory/check-log.md` ключ `mobile-discovery-source-index`. Каждый цикл берешь следующий источник из списка. Дошел до конца — начинай сначала.

## Источники (ротация)

| # | Источник | Как искать | Что извлекать |
|---|----------|-----------|---------------|
| 1 | **App Store — Business** | WebSearch "site:apps.apple.com business analytics saas" + WebFetch iTunes Search API | Название, bundle ID, рейтинг, дата обновления, разработчик |
| 2 | **App Store — Productivity** | WebSearch + iTunes Search API категория Productivity | То же |
| 3 | **App Store — Finance** | WebSearch "site:apps.apple.com finance analytics SaaS B2B" | То же |
| 4 | **Google Play — Business** | WebSearch "site:play.google.com/store business analytics saas" | Название, package, рейтинг, обновление |
| 5 | **Product Hunt** | WebSearch "site:producthunt.com SaaS mobile app launched 2025 OR 2026" | Название, URL, описание |
| 6 | **G2** | WebSearch "site:g2.com best SaaS mobile app low rating reviews" | Название, рейтинг, отзывы про мобилку |
| 7 | **Capterra** | WebSearch "site:capterra.com {vertical} software mobile app" | То же |
| 8 | **Clutch** | WebSearch "site:clutch.co mobile app development company hiring" — клиенты | Название компании-заказчика |
| 9 | **Crunchbase** | WebSearch "site:crunchbase.com series A OR series B 2025 OR 2026 mobile app" | Компания, раунд, сумма |
| 10 | **LinkedIn Jobs** | WebSearch "site:linkedin.com/jobs mobile developer react native OR flutter OR iOS" | Компания, позиция |
| 11 | **Upwork** | WebSearch "site:upwork.com/jobs mobile app maintenance OR support OR update iOS android" | Заказ, бюджет, заказчик |
| 12 | **Reddit** | WebSearch "site:reddit.com SaaS mobile app terrible OR outdated OR needs update" | Упоминания компаний с плохими мобилками |

## Вертикали для поиска (расширяющийся список)

Начинаем с AdTech (уже в таблице). Каждую неделю добавляй новую вертикаль:
- W1: AdTech, MarTech
- W2: FinTech, HR-tech
- W3: HealthTech, EdTech
- W4: E-commerce tools, Logistics-tech
- W5+: AI/ML tools, DevTools, Legal-tech, Real Estate tech

Храни текущую вертикаль в `${CLAUDE_PROJECT_DIR}/memory/check-log.md` ключ `mobile-discovery-vertical`.

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
   - Команда 10-200 человек
   - НЕ являются mobile-first компаниями (мобилка = companion к вебу)
3. Для каждой компании собери:
   - Company Name, URL
   - Vertical (AdTech/MarTech/FinTech/...)
   - Employees (приблизительно)
   - iOS URL / Android URL
   - Last Update (из стора если доступно)
   - App Rating
   - Description (одно предложение)
   - DM Name, Title, LinkedIn (CEO/CTO/VP Eng — один лучший контакт)
   - Initial Signal Score (1-5)

4. Проверь что компании НЕТ в таблице (дедупликация через content-hub):
   curl -s -X POST http://localhost:7901/sheets/<SPREADSHEET_ID>/find_row \
     -H 'Content-Type: application/json' \
     -d '{"query": {"Company": "<company_name>"}}'
   Если ответ содержит "count":0 — компании нет, добавляй. Если count > 0 — пропусти.

5. Для каждой новой компании добавь строку через content-hub:
   curl -s -X POST http://localhost:7901/sheets/<SPREADSHEET_ID>/add_row \
     -H 'Content-Type: application/json' \
     -d '{"Company": "<name>", "URL": "<url>", "Vertical": "<vertical>", "Employees": "<N>", ... "Notes": "<notes>"}'
   Если curl exit code != 0 или response не содержит "success":true — записать `status: partial`.

   Notes обязательно включают источник в формате:
   `Found via {source} | [source_type|YYYY-MM-DD|URL|описание]`

6. Верни список добавленных компаний.
```

3. **Алерт в Telegram** — если нашел 2+ компании:
   ```
   Discovery [{source}]: +{N} новых компаний
   {список: Company — vertical — score}
   Таблица Mobile Prospects обновлена.
   ```

4. **Обнови check-log:** `mobile-prospect-discovery` + `mobile-discovery-source-index`.

## Сохранение источников (ОБЯЗАТЕЛЬНО)

При добавлении компании в таблицу — Notes (последняя колонка) ВСЕГДА содержит:
1. Источник (откуда найдена): `Found via {source_name}`
2. URL первичного сигнала в формате: `[signal_type|YYYY-MM-DD|URL|описание]`

Пример для LinkedIn Jobs: `Found via LinkedIn Jobs | [hiring|2026-04-10|https://linkedin.com/jobs/view/4123456|Senior iOS Dev, B2B SaaS, 50-200 emp]`

Если URL недоступен: `Found via {source} | [signal_type|YYYY-MM-DD|NO_URL|описание почему]`

**Правило:** сигнал без URL — unverifiable через 7+ дней. Всегда сохраняй URL в момент нахождения.

## Правила

- Запускай как субагент (run_in_background: true) — не блокируй основной цикл
- Один источник за цикл
- Дедупликация обязательна
- Не добавляй consumer apps (Instagram, TikTok, Spotify), игры, mobile-first компании
- Не добавляй компании < 10 человек и > 200
- Signal Score при discovery = предварительный (3 по умолчанию). mobile-prospect-scan потом уточнит
- Если источник не дал результатов — переходи к следующему
- Цель: 3-5 новых компаний за цикл, 15-20 в неделю, 100+ к концу квартала
