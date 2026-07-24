---
name: telegram-scan
description: Экспортирует все Telegram чаты через tdl --raw, конвертирует в markdown, обновляет контакты через Event Correlation. Запускается каждые 12ч или вручную.
when_to_use: По расписанию каждые 12ч; нужны свежие данные из Telegram перед анализом; перерыв > 12ч; пользователь сказал "просканируй telegram".
allowed-tools: Read, Edit, Write, Bash, Grep
---

# Telegram Scan — Процедура AgentOS

> Требует: `tdl` (MTProto-клиент) с авторизованным аккаунтом. Установка: https://github.com/iyear/tdl. Если не настроен — пропусти этот скилл при разворачивании.

## Когда вызывать

- По расписанию: каждые 12 часов (проверяй `${CLAUDE_PROJECT_DIR}/memory/check-log.md` — поле `telegram-scan`)
- Вручную: если нужно получить свежие данные из Telegram перед анализом
- После перерыва > 12ч (или когда `now - last_check >= 12ч`)

## Аккаунт

Tdl поддерживает несколько namespace для разных аккаунтов. Скилл работает с аккаунтом по умолчанию (`default`). Если хочешь использовать другой — добавь флаг `-n <namespace>` ко всем командам tdl.

**ОБЯЗАТЕЛЬНО:** во все markdown-артефакты (research, contacts) ставить frontmatter с `account: <тип>` и `namespace: <namespace>`. Без этой пометки данные не сохранять.

## Шаги

### 1. Получить список чатов

```bash
tdl chat ls
```

Реестр чатов для мониторинга: `${CLAUDE_PROJECT_DIR}/memory/telegram-chats.md`. Сканировать ВСЕ чаты из реестра.

### 2. Экспортировать каждый чат

```bash
# Последние 50 сообщений (основной режим):
tdl chat export -c <chat_id> --all --with-content --raw -T last -i 50 -o /tmp/out-raw.json

# По времени (если нужен конкретный период):
tdl chat export -c <chat_id> --all --with-content --raw -T time -i <unix_from>,<unix_to> -o /tmp/out-raw.json

# Топик (если чат использует топики):
tdl chat export -c <chat_id> --topic <topic_id> --all --with-content --raw -T last -i 20 -o /tmp/out-raw.json
```

**КРИТИЧНО:** всегда `--raw`. Без него теряются URL из hyperlink entities (text "LinkedIn" без ссылки).
URL в raw формате: `message.raw.Entities[].URL`

### 3. Slim-обработка (убрать мусор)

```bash
python3 "${CLAUDE_PROJECT_DIR}/scripts/slim-tdl-export.py" /tmp/out-raw.json /tmp/out.json
```

Убирает ~85% мусора, оставляет: text, urls, from_user_id, date.

(Скрипт `slim-tdl-export.py` — простой Python-парсер raw tdl JSON; если его нет, напиши вручную или используй упрощённый JSON-фильтр через `jq`.)

### 4. Конвертация в markdown

Конвертировать `/tmp/out.json` в markdown и сохранить в `${CLAUDE_PROJECT_DIR}/research/telegram-raw/{chat-name}.md`.

## Направление сообщений (КРИТИЧНО)

tdl --raw JSON содержит поле `Out`:
- `"Out": true` — исходящее сообщение (пользователь написал)
- `"Out": false` — входящее сообщение (собеседник написал)

При парсинге ВСЕГДА маркировать направление: "[OUT]" или "[IN]"
Никогда не приписывать исходящие сообщения собеседнику.

Формат markdown:
```
### [YYYY-MM-DD HH:MM] [OUT] Пользователь

Текст исходящего сообщения

---

### [YYYY-MM-DD HH:MM] [IN] @username (Name)

Текст входящего сообщения

---
```

Правила:
- Сообщения хронологически (старые сверху)
- `[OUT]` для `raw.Out == true`, `[IN]` для `raw.Out == false`
- Медиа без текста: `[медиа: фото/видео/документ]`
- Временные JSON-файлы: только `/tmp/`

### 5. Извлечь сигналы

При чтении сообщений искать:
- Упоминания потенциальных клиентов, партнеров, конкурентов
- Запросы на услуги, обсуждение болей
- Тренды, инструменты, рыночные движения

Записывать в `${CLAUDE_PROJECT_DIR}/memory/signals.md`:
```
### [YYYY-MM-DD] Тип: описание
- **Источник:** telegram / @chat-name
- **Потенциал:** high | med | low
- **Статус:** new
```

Типы сигналов: `lead`, `trend`, `request`, `problem`, `idea`

### 5.5. Pre-signal cross-check

Перед записью high-потенциал сигнала (score = high или явная сделка/договор):

1. **Дедупликация:** есть ли уже этот сигнал в `${CLAUDE_PROJECT_DIR}/memory/signals.md`? Если да — обнови, не создавай новый.
2. **Для сигналов о сделках (DocuSign, договор, подписание):**
   - Проверь Gmail: `gmail_search_messages "from:{contact_domain} OR to:{contact_domain} newer_than:7d"`
   - Если Gmail подтверждает событие → сигнал VERIFIED, можно алертить
   - Если Gmail молчит → сигнал UNVERIFIED, записать в signals.md без алерта, дождаться второго источника
3. **Для новых лидов из Telegram:**
   - Проверь CRM pipeline по имени/компании
   - Если уже в pipeline → обнови timeline без создания нового opportunity
4. **Если нашел противоречие между Telegram и другим источником** → запиши в алерт явно: "КОНФЛИКТ данных: {источник 1} говорит X, {источник 2} говорит Y"

### 6. Event Correlation

После каждого скана — связать найденные события с контактами. Вызвать скилл `event-correlation` для каждого релевантного события:
- Новое сообщение от известного контакта → обновить timeline
- Упоминание компании/человека из `memory/contacts/` → записать в timeline

### 7. Записать summary

Сохранить итоговый summary: `${CLAUDE_PROJECT_DIR}/research/telegram-scan-{YYYY-MM-DD}.md`
- Что нового в каждом чате
- Ключевые сигналы
- Новые упомянутые люди

### 8. Обновить check-log

```bash
# В ${CLAUDE_PROJECT_DIR}/memory/check-log.md добавить:
# telegram-scan: YYYY-MM-DD HH:MM — N чатов, M сигналов
```

## Результат

- `${CLAUDE_PROJECT_DIR}/research/telegram-raw/{chat-name}.md` — сырые данные по каждому чату
- `${CLAUDE_PROJECT_DIR}/research/telegram-scan-{date}.md` — summary скана
- `${CLAUDE_PROJECT_DIR}/memory/signals.md` — обновленные сигналы
- `${CLAUDE_PROJECT_DIR}/memory/contacts/*.md` — обновленные timeline через Event Correlation
- `${CLAUDE_PROJECT_DIR}/memory/check-log.md` — время последнего скана

## Правила

- Экспорт сообщений — read-only, подтверждение не нужно
- Отправка/пересылка — требует подтверждения пользователя
- Люди → `memory/people.md` (индекс) + `memory/contacts/{slug}.md` (детальный файл)
- НЕ создавай файлы контактов для спамеров и внутренних контактов (твоя команда)
- Запускать как субагент с `run_in_background: true` — не блокирует основной цикл
- Нашел что-то новое → отчет в Telegram через operator. Ничего нового → молчи
