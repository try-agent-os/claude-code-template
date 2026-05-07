---
name: contact-enrichment
description: При новом или неполном контакте собирает данные из всех коннекторов (Telegram, LinkedIn, Gmail, ClickUp, Fireflies, Calendar, Web). Запускается автоматически при создании контакта или вручную.
type: procedure
---

# Contact Enrichment — Процедура AgentOS

## Когда вызывать

- Новый контакт создан в `../memory/contacts/`
- Существующий контакт имеет пустые ключевые поля (email, linkedin, компания)
- Ручной запрос от пользователя: "обогати контакт {имя}"
- После Event Correlation: новый контакт определен как важный (клиент, лид, партнер)

## Шаги

### 1. Telegram (tdl)

Если у контакта есть username:

```bash
tdl chat export -c <chat_id> --all --with-content --raw -T last -i 50 -o /tmp/out-raw.json
python3 $HOME/Workspaces/novostudio/claude/agents/heartbeat/slim-tdl-export.py /tmp/out-raw.json /tmp/out.json
```

Извлечь из сообщений:
- Полное имя
- Ссылки (LinkedIn, сайт, GitHub, Twitter)
- Описание продукта/компании
- Контекст и тон общения

### 2. LinkedIn (web search)

Поиск: `"{имя} {фамилия}" LinkedIn {компания}`

Извлечь:
- Роль и должность
- Опыт и стаж
- Локация
- Прямая ссылка на профиль (добавить в поле `linkedin:` файла контакта)

### 3. Gmail

```
gmail_search_messages query "from:{email} OR to:{email} OR {имя} {компания}"
```

Извлечь:
- Темы переписки
- Даты контактов
- Контекст взаимодействий

### 4. ClickUp

```
clickup_search по имени/компании
```

Список ID:
- Sales/Pipeline: list `901513408029`
- Sales/Contacts: list `901511168305`

Извлечь:
- Статус в pipeline (COLD / OUTREACH / DISCOVERY / PROPOSAL / DEAL)
- Последние заметки
- Открытые задачи связанные с контактом

### 5. Fireflies

```
fireflies_get_transcripts → поиск по имени участника
fireflies_get_summary для каждой найденной встречи
```

Извлечь:
- Темы обсуждений
- Договоренности
- Action items

### 6. Google Calendar

```
gcal_list_events → поиск по email или имени
```

Извлечь:
- Когда встречались в прошлом
- Когда следующая встреча (если запланирована)

### 7. Web search

Если есть компания или продукт:

Поиск: `"{компания}" {продукт}`

Извлечь:
- Описание бизнеса
- Стадия (pre-seed / seed / Series A / etc.)
- Размер команды
- Технологический стек
- Последние новости/публикации

### 8. Cross-contact analysis

Найти связи с другими контактами из `../memory/contacts/`:

1. Пробежаться по файлам контактов — искать упоминания имени/компании/продукта этого контакта
2. Fireflies: `fireflies_get_transcripts` с несколькими участниками — найти встречи где присутствовали оба
3. Telegram: если есть общие чаты (оба в `../memory/telegram-chats.md`) — отметить
4. Заполнить секцию `## Связи` в файле контакта

## Результат

Заполнить все поля в файле контакта (`../memory/contacts/{slug}.md`):

```markdown
## Контакт
- **Полное имя:** {имя}
- **Компания:** {компания}
- **Роль:** {должность}
- **Telegram:** @username
- **Email:** email@domain.com
- **LinkedIn:** https://linkedin.com/in/...
- **Источник:** откуда узнали

## Матчинг
- emails: domain.com
- telegram: @username
- keywords: Company, Name, Product

## Связи
- **Общие чаты:** {чаты}
- **Общие встречи:** {встречи}
- **Через кого:** {кто привел}
- **Знает:** {людей из сети}
```

Дополнительно:
- Записать найденные события в `## Timeline` контакта
- Обновить секцию `## Матчинг` (emails, keywords)
- Если найдена важная информация (активная сделка, открытый запрос) — сигнал в `../memory/signals.md`

## Шаблон нового контакта

```markdown
# {Имя Фамилия} ({Компания})

## Контакт
- **Полное имя:**
- **Компания:**
- **Роль:**
- **Telegram:**
- **Email:**
- **LinkedIn:**
- **Источник:** откуда узнали

## Статус
- **Pipeline:** COLD | OUTREACH | DISCOVERY | PROPOSAL | DEAL | PARTNER | INACTIVE
- **Следующий шаг:**
- **Последнее обновление:** YYYY-MM-DD

## Матчинг
- emails: domain.com, name@domain.com
- telegram: @username
- keywords: Company, Name, Product

## Связи
- **Общие чаты:**
- **Общие встречи:**
- **Через кого:**
- **Знает:**

## Timeline

### YYYY-MM-DD HH:MM [источник]
Описание
```

## Правила

- Запускать как субагент с `run_in_background: true` — не блокировать основной цикл
- Максимум 3 enrichment за один heartbeat цикл (rate limiting)
- Если коннектор не дает результатов — пропускать, не фейлиться
- НЕ обогащать внутренних контактов (команда Novo Studio) и спамеров
- Slug файла = имя-фамилия (lowercase, дефис): `vasily-petrov.md`
- После завершения: git commit + push изменений в contacts/
