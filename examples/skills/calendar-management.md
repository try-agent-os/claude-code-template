---
name: calendar-management
description: Правила работы с Google Calendar Vasily — цветовая система, язык событий, recurring blocks, конфликт-проверка, рабочие/нерабочие интервалы. Применяется при любом создании или изменении событий через mcp__claude_ai_Google_Calendar__*.
type: procedure
---

# Calendar Management — Правила Vasily

## Когда вызывать

При любом действии с календарем Vasily:
- `mcp__claude_ai_Google_Calendar__create_event`
- `mcp__claude_ai_Google_Calendar__update_event`
- `mcp__claude_ai_Google_Calendar__delete_event`
- Когда планируем работу/неделю/день (Vasily просит "запланируй", "поставь", "добавь в календарь")

## КРИТИЧНО: pre-flight check

**ВСЕГДА перед созданием новых events на день — вызывать `list_events` на этот день.**

Цель:
- Не создавать дубликаты с recurring (Lunch, Dinner, Walk, Wind-down, Sleep, Morning walk + coffee, Check chats и т.д.)
- Не создавать дубликаты с meetings, которые уже стоят (Sync Planning, Anomalia, Liubov FemFast, Alexey Claude, Novo Site и т.д.)
- Не создавать дубликаты с другими блоками которые я сам же создал ранее
- Видеть свободные окна реально, не из памяти

Если этот шаг пропустить — получаем дубли, конфликты и Vasily злится. Это правило усилено явно после случаев когда я создавал свои Lunch/Dinner/Wind-down поверх его recurring, и Workout на вс поверх его recurring Workout.

**Никогда не создавать events "на ощущение свободного слота" — всегда сначала `list_events`.**

## Цветовая система (КРИТИЧНО — соблюдать строго)

**ТОЛЬКО эти 5 цветов / категорий. Других не использовать.**
Если событие не вписывается в одну из 5 — выбрать ближайшую, не изобретать новую категорию. Не использовать Lavender (1), Flamingo (4), Graphite (8), Blueberry (9), Basil (10), Tomato (11) — ничего кроме 5 ниже.

| Категория | colorId | Цвет в Google | Что относится |
|-----------|---------|---------------|---------------|
| **Meetings** | `6` | 🟠 Tangerine | Внешние встречи, calls, инвестор-коллы, интервью с клиентами, Vlad Pochukalin review |
| **Focus Work** | `5` | 🟡 Banana | Symoditi, Bailaspot, RedTrack, любая deep client work |
| **Personal** | `2` | 🟢 Sage | Тренировки, lunch, dinner, walks, sleep, wind-down, break, breakfast, любое личное |
| **Operations** | `7` | 🔵 Peacock | Planning, finance, anomalia, admin, chats EOD, taxes, backoffice, content batch |
| **Growth** | `3` | 🟣 Grape | Learning, новые идеи, networking, market research, рост доходных каналов |

### Спорные случаи (как Vasily решил)

- **Finance focus block** → Operations (7), а не Meetings или Growth
- **Vlad Pochukalin review** (даже если это не звонок) → Meetings (11)
- **Тренировки** → НЕ в отдельный Sport calendar, оставлять в primary с Personal (2)

### Проверка перед созданием

Если категория неоднозначна — спросить Vasily ОДНИМ вопросом, не выдумывать.

## Маркеры проектов в title (emoji prefixes)

Все Focus Work события одного цвета (Banana, 5). Проекты различаются emoji-кружком в начале title:

| Проект | Emoji prefix |
|--------|--------------|
| Bailaspot | 🟣 |
| Symoditi | 🟢 |
| RedTrack | 🔴 |

Категория событий ОСТАЕТСЯ Focus Work (5). Цветной кружок — это маркер ПРОЕКТА в названии, не цвет события.

**Названия — короткие.** Просто проект, без уточнений (`deep`, `kickoff`, `other tasks`, `block`, `DEV-470`). Это просто блок-маркер. Уточнения — в description.

Примеры (правильно):
- `🟣 Bailaspot`
- `🟢 Symoditi`
- `🔴 RedTrack`

Неправильно:
- ❌ `🟣 Bailaspot block`
- ❌ `🟢 Symoditi DEV-470 deep`
- ❌ `🔴 RedTrack kickoff`

Если новый клиент / новый проект — спросить Vasily какой emoji-маркер.

## Язык событий

**ВСЕ события на английском.** Не на русском. Это правило Vasily — он явно сказал.

Хорошо:
- 💪 Strength training
- 🔵 Bailaspot block
- 📞 Vlad Pochukalin: review product + questions
- ☕ Break
- 🍽️ Dinner

Плохо:
- 💪 Силовая тренировка
- 🔵 Байласпот
- 📞 Влад Пощукалин

Emoji в начале title — норма (визуальный маркер). Description можно по-русски.

## Recurring events которые УЖЕ В КАЛЕНДАРЕ

Перед созданием rhythm-events ВСЕГДА вызвать `list_events` на день. Vasily имеет следующие recurring:

| Событие | Время | Цвет | Не дублировать |
|---------|-------|------|----------------|
| 🐕 Morning walk + coffee | 08:00-09:30 (на дни без ранней тренировки) | Personal (2) | Никогда не создавать |
| 📱 Check messengers / inbox | 09:30-09:45 | Operations (7) | Никогда не создавать |
| 🥗 Lunch | 13:00-13:45 | Personal (2) | Никогда не создавать |
| 💬 Check chats | 13:30-13:45 | Operations (7) | Никогда не создавать |
| 💬 Check chats (EOD) | 18:00-18:15 | Operations (7) | Никогда не создавать |
| 🍲 Dinner | 18:30-19:00 | Personal (2) | Никогда не создавать |
| Wind-down | 22:30-23:00 | Personal (2) | Никогда не создавать |
| Sleep | 23:00-07:30 | Personal (2) | Никогда не создавать |

ПЛЮС встречи (Sync Planning, Anomalia, Alexey, Novo Site и т.д.) — recurring meetings, проверять перед созданием новых.

## Walks

Vasily передвинул прогулки на **сразу после ужина**: 19:00-19:30 (а не 20:30-21:00 как в старом плане). Эти Evening walk + sunset события я создаю на каждый день недели если их нет recurring.

Время: 19:00-19:30. Цвет: Personal (2).

## Стандартные блоки работы

| Блок | Длительность | Цвет |
|------|--------------|------|
| Deep work block (Symoditi, Bailaspot, RedTrack) | 1.5ч (90 мин) | Focus Work (5) |
| Operations / chats | 1ч | Operations (7) |
| Content batch | 1ч | Operations (7) |
| Vlad / external call | 30-60 мин | Meetings (6) |
| Re-parenting check-in | 5-15 мин | Personal (2) |
| Break | 15-30 мин | Personal (2) |
| Planning continuation | 15-45 мин | Operations (7) |
| Финансовый ритуал (раз в неделю) | 1.5ч | Operations (7) |

## Принципы планирования (под Vasily — ADHD + identity-нужда + пара)

- **Не более 3 главных дел в день** — ADHD-mode. 10 дел = 0 сделано.
- **Free time buffer** — минимум 30% свободного времени на неделю.
- **Тренировки фиксированные первыми** — ядро недели, остальное вокруг.
- **Среда = FOCUS DAY** — никаких meetings (если возможно).
- **Пятница 17:00-18:00** — weekly review + план на следующую неделю.
- **Вечера после ужина** — work blocks 19:30-21:00 (после walk 19:00-19:30).
- **22:30 wind-down, 23:00 sleep** — защита, не двигать.

## Workflow создания недельного плана

1. Vasily просит запланировать неделю (или конкретный день)
2. Спросить какие фиксированные events на неделе (тренировки, клиентские встречи, Anomalia, etc)
3. Вызвать `list_events` на каждый день — увидеть существующие recurring + meetings
4. Поставить тренировки первыми (Personal 2)
5. Вокруг них раскидать work blocks (Focus Work 5)
6. Operations / Finance / Planning слоты (Operations 7)
7. Content batch (Growth 3)
8. Не создавать дубликаты с recurring
9. Показать сводку дня в Telegram → Vasily ОК → следующий день

## Workflow исправления конфликтов

Если событие пересекается с уже существующим:
- Если recurring (lunch/dinner/walk/wind-down) — НЕ двигать recurring, двигать свое
- Если meeting (Sync Planning, Anomalia) — НЕ двигать, двигать свое
- Если оба мои — переcмотреть приоритет, спросить Vasily если не очевидно

## История правил (для evolution)

Этот skill эволюционирует. При новых правилах от Vasily — добавлять сюда.

- 2026-05-04: Создан. Цветовая система Meetings/Focus Work/Personal/Operations/Growth.
- 2026-05-04: События на английском (правило Vasily).
- 2026-05-04: Walks 19:00-19:30 после ужина (передвинуто из 20:30-21:00).
- 2026-05-04: Vlad Pochukalin reviews → Meetings (6), даже если не call.
- 2026-05-04: Meetings = Tangerine (6, оранжевый), НЕ Tomato (11, красный). Я ошибся изначально, Vasily поправил.
- 2026-05-04: Content batch → Operations (7), а не Growth (3). Контент это backoffice/output процесс. Growth — про новые направления и рост.
- 2026-05-04: ТОЛЬКО 5 цветов категорий, других не использовать. Если событие не вписывается — выбрать ближайшую, не выдумывать. Vasily подтвердил скриншотом легенды.
- 2026-05-04: Emoji-prefixes в title для проектов Focus Work — Bailaspot 🟣, Symoditi 🟢, RedTrack 🔴. Категория остается Focus Work (5).
- 2026-05-04: Названия Focus Work блоков — короткие. Просто `🟢 Symoditi` / `🟣 Bailaspot` / `🔴 RedTrack` без уточнений (deep / kickoff / other tasks / DEV-470). Это просто блоки.
- 2026-05-04: ВСЕГДА pre-flight `list_events` перед созданием. Не выдумывать свободные окна. Это правило усилено явно после нескольких случаев дубликатов Lunch/Dinner/Wind-down/Workout поверх recurring.
- 2026-05-04: Finance → Operations (7), не Growth.
- 2026-05-04: Тренировки в primary calendar с Personal (2), НЕ в Sport calendar.

## Связанные правила в memory

- [feedback_calendar_user_controls.md](https://github.com/novostudiotech/claude/blob/main/memory/contacts/) — никогда не создавать события без явного approval
- [user_lifelong_scarcity.md](auto-memory) — контекст ADHD + identity-нужда → 3 дела/день, buffer time
