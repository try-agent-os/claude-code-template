---
name: telegram-export
description: Экспортирует конкретный Telegram канал/чат/группу через tdl в resources/{slug}/posts/ (отдельный файл на пост) + index.md. Используй когда нужно сохранить историю канала как структурированный ресурс.
type: procedure
trigger: ["экспорт канала", "сохранить чат", "telegram export", "tdl export", "скачать историю"]
---

# Telegram Export — Процедура AgentOS

## Когда вызывать

- Нужно сохранить историю конкретного канала/чата как структурированный ресурс
- Разовый глубокий экспорт перед анализом (больше 50 сообщений)
- Архивирование канала для ресерча (communities, competitors, leads)
- Пользователь дал URL/username канала и попросил "экспортировать" или "сохранить"

Отличие от `telegram-scan`: scan — мониторинг ВСЕХ чатов за сигналами (50 сообщений). Export — глубокий архив ОДНОГО источника (500+ сообщений, per-post файлы).

## Аккаунт (ОБЯЗАТЕЛЬНАЯ ПОМЕТКА)

По умолчанию — **рабочий аккаунт** (`@vasilykrylov`, default namespace). Если канал/чат доступен только с личного — использовать `tdl -n personal ...`.

**В каждом `index.md` в `resources/{slug}/` обязательно frontmatter:**
```yaml
---
source: telegram
account: work          # work | personal
namespace: default     # default | personal
chat_id: <id>
exported_at: <ISO>
---
```

Без этой пометки артефакт не сохранять — это правило Source-of-Truth для всех tdl-артефактов. Подробнее: [`CLAUDE.md`](../../../CLAUDE.md) → Telegram (tdl) → Источник аккаунта.

## Входные данные

- **URL или username** канала/чата (обязательно) — например: `@y_everyday`, `t.me/communitysprints`, числовой ID
- **Количество сообщений** (default: 500)
- **Категория** (опционально) — если не указана, определяй автоматически
- **Namespace** (опционально) — `default` (рабочий) | `personal` (личный). По умолчанию `default`.

## Структура хранения

```
resources/
  {channel-slug}/
    posts/
      001_YYYY-MM-DD.md   # один файл = один пост
      002_YYYY-MM-DD.md
      ...
    index.md              # обзор канала: описание, статистика, дата экспорта
```

Референс реализации: `resources/outreacher/andrew_shishkin/`

### Определение slug и категории

| Тип источника | Папка | Slug |
|--------------|-------|------|
| Группа, сообщество, форум | `resources/communities/` | kebab-case из названия |
| Канал (контент, советы) | `resources/telegram/` | username без @ |
| Рынок, prospects, outreach | `resources/outreacher/` | username без @ |
| Личная переписка | `resources/contacts/` | username |

## Шаги

### 1. Найти chat_id

Сначала реестр `../memory/telegram-chats.md` — там уже есть ID известных чатов.

Если нет:
```bash
tdl chat ls
```

### 2. Проверить существующую папку

```bash
ls resources/{category}/{slug}/posts/ 2>/dev/null | tail -1
```

Если папка существует — найди последний файл, прочитай из него `message_id` (frontmatter). Экспортируем только сообщения после него.

### 3. Экспортировать через tdl

```bash
# Последние N сообщений:
tdl chat export -c <chat_id> --all --with-content --raw -T last -i <N> -o /tmp/tg-export-raw.json

# По времени (конкретный период):
tdl chat export -c <chat_id> --all --with-content --raw -T time -i <unix_from>,<unix_to> -o /tmp/tg-export-raw.json

# Топик (AltaLab Online Module и другие с топиками):
tdl chat export -c <chat_id> --topic <topic_id> --all --with-content --raw -T last -i <N> -o /tmp/tg-export-raw.json
```

**КРИТИЧНО:** всегда `--raw`. Без него теряются URL из hyperlink entities.  
URL в raw формате: `message.raw.Entities[].URL`

### 4. Slim-обработка

```bash
python3 $HOME/Workspaces/novostudio/claude/agents/heartbeat/slim-tdl-export.py /tmp/tg-export-raw.json /tmp/tg-export.json
```

### 5. Дедупликация

Если папка уже существует:
- Найди максимальный `message_id` среди существующих постов
- Отфильтруй из `/tmp/tg-export.json` только сообщения с `message_id` выше этого значения
- Нумерация новых файлов продолжает существующую (следующий номер после последнего)

### 6. Создать файлы постов

## Направление сообщений (КРИТИЧНО для личных чатов)

tdl --raw JSON содержит поле `Out`:
- `"Out": true` — исходящее сообщение (Vasily написал)
- `"Out": false` — входящее сообщение (собеседник написал)

При парсинге ВСЕГДА маркировать направление: "[OUT]" или "[IN]"
Никогда не приписывать исходящие сообщения собеседнику.

Для каждого сообщения создай файл `resources/{category}/{slug}/posts/{NNN}_{YYYY-MM-DD}.md`:

- `NNN` — порядковый номер (001, 002, ... сквозная нумерация)
- `YYYY-MM-DD` — дата сообщения

Формат файла:
```markdown
---
message_id: 123
date: YYYY-MM-DD HH:MM UTC
views: 1234
forwards: 12
replies: 0
reactions_total: 45
reactions: "🔥 20, 👍 15, ❤ 10"
has_media: false
media_type: none
link: https://t.me/{username}/{message_id}
---

# Первая строка или первые 60 символов текста...

Полный текст сообщения.

Ссылки: https://example.com

[Оригинал в Telegram](https://t.me/{username}/{message_id})
```

Правила:
- `has_media: true` если есть фото/видео/документ; `media_type: photo|video|document|none`
- `reactions` — только топ-3 по количеству; если нет реакций — пустая строка
- Медиа без текста: в теле файла `[медиа: фото/видео/документ]`
- URL из `Entities` добавлять явно в строку `Ссылки:` (если есть)
- Системные сообщения (вход/выход из группы): пропускать
- Для личных переписок: добавить поле `direction: out|in` в frontmatter (из `raw.Out`)

### 7. Создать/обновить index.md

Файл `resources/{category}/{slug}/index.md`:

```markdown
---
name: Название канала/чата
username: @username
source_url: https://t.me/username
chat_id: 123456789
category: communities|telegram|outreacher|contacts
first_exported_at: YYYY-MM-DD
last_exported_at: YYYY-MM-DD HH:MM
posts_count: N
last_message_id: 12345
---

# Название канала

> Краткое описание: тип, тематика, зачем нужен

## Статистика

- Постов в архиве: N
- Период: YYYY-MM-DD — YYYY-MM-DD
- Последний экспорт: YYYY-MM-DD HH:MM

## Описание

[2-3 предложения о канале/чате и его ценности для Novo Studio]
```

При обновлении — обновить `last_exported_at`, `posts_count`, `last_message_id`.

### 8. Добавить в реестр (если новый чат)

Если чата не было в `../memory/telegram-chats.md` — добавить строку в соответствующую секцию.

### 9. Очистить временные файлы

```bash
rm /tmp/tg-export-raw.json /tmp/tg-export.json
```

### 10. Commit и push

```bash
git add resources/{category}/{slug}/
git commit -m "export: {slug} — {N} постов"
git push
```

## Результат

- `resources/{category}/{slug}/posts/*.md` — посты
- `resources/{category}/{slug}/index.md` — обзор канала
- `memory/telegram-chats.md` — обновлен (если новый чат)

## Правила

- Экспорт — read-only, подтверждение не нужно
- Временные JSON только в `/tmp/`
- Никогда не перезаписывай существующие посты — только добавляй новые
- Не экспортируй личные переписки без явного запроса пользователя
