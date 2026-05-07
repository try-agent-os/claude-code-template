---
name: outreach-trajectory
description: Строит полную траекторию 6-8 касаний для OPP-лида. Переписывает draft под v2 standard, создает Funnel rows, saga-напоминалки. Запускается вручную или через dispatcher при "trajectory", "касания", "touches", "sequence".
type: procedure
trigger: trajectory, касания, touches, sequence, outreach-trajectory, траектория
---

# Outreach Trajectory — Процедура

Строит полную multichannel outreach sequence для одного лида: переписывает draft, строит траекторию 6-8 касаний, записывает в Funnel sheet, создает saga-напоминалки.

## Входные данные

Worker получает в промпте:
- `OPP_ID` — идентификатор opportunity (OPP-NNN)
- `DRAFT_PATH` — путь к существующему драфту в `studio/sales/outreach/`
- Опционально: `D0_DATE` — дата первого email (по умолчанию: следующий четверг вечер)

## Константы

- **Spreadsheet ID:** `1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4`
- **Funnel sheet:** `Funnel` (gid 20780300)
- **Методология:** [`studio/sales/OUTREACH_PROCESS.md`](https://github.com/novostudiotech/claude/blob/main/studio/sales/OUTREACH_PROCESS.md)
- **Шаблон:** [`studio/sales/outreach/_TEMPLATE_trajectory.md`](https://github.com/novostudiotech/claude/blob/main/studio/sales/outreach/_TEMPLATE_trajectory.md)
- **Saga epic:** 3 (Business Operations)

## Шаги

### 1. Собрать контекст лида

1. **Прочитай OPP из [`memory/opportunities.md`](https://github.com/novostudiotech/claude/blob/main/memory/opportunities.md):** найди OPP-{OPP_ID}. Извлеки: компанию, контакт, сигналы, score, статус.
2. **Прочитай существующий draft:** `studio/sales/outreach/{DRAFT_PATH}`. Извлеки: контакт (name, email, LinkedIn), company data, hooks, emails.
3. **Прочитай Mobile Prospects через content-hub:**
   ```bash
   curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/find_row \
     -H 'Content-Type: application/json' \
     -d '{"query": {"Company": "<company_name>"}}'
   ```
   Извлеки из ответа: Description, Review Pain, Signal Score, Notes, DM Name, DM Email, DM LinkedIn, и `rowIndex` для Funnel sheet.
4. **Прочитай контакт** (если есть): `memory/contacts/{slug}.md` — проверь Timeline на предыдущие касания.

### 2. Верификация контакта

**ОБЯЗАТЕЛЬНО перед генерацией:**

1. Имя + должность ЛПР: проверь через WebSearch `{DM_Name} {Company} site:linkedin.com` — совпадает ли должность с данными в draft.
2. Email: если помечен как unverified — записать в draft пометку "⚠️ email unverified".
3. Если у компании уже был контакт (Gmail search `from:{domain} OR to:{domain} newer_than:60d`) — это НЕ cold outreach, а follow-up. Скорректировать тон.

> **Паттерн:** Outreach contact verification: всегда проверять имя+должность через официальный сайт, не только LinkedIn (confidence: 0.70).

### 3. Рассчитать даты касаний

На основе D0_DATE (или следующий четверг по умолчанию):

```
D-1  = D0 - 1 день (pre-warm LinkedIn)
D0   = дата первого email (четверг вечер по TZ получателя)
D+3  = D0 + 3 дня (FU #1 + LinkedIn DM)
D+7  = D0 + 7 дня (Value drop)
D+14 = D0 + 14 дней (Urgency)
D+21 = D0 + 21 дней (Last FU Shishkin)
D+24 = D0 + 24 дня (Pattern break)
```

**Правило тайминга:** emails отправлять 20:00-23:00 по TZ получателя. Лучший день: четверг.

### 4. Переписать draft под v2 standard

Прочитай [`studio/sales/OUTREACH_PROCESS.md`](https://github.com/novostudiotech/claude/blob/main/studio/sales/OUTREACH_PROCESS.md) и [`studio/sales/outreach/_TEMPLATE_trajectory.md`](https://github.com/novostudiotech/claude/blob/main/studio/sales/outreach/_TEMPLATE_trajectory.md).

Проверь каждый email в draft на соответствие v2:

| Критерий | Проверка |
|----------|---------|
| Hook = конкретный сигнал | Не "we help companies", а "your iOS 2.83 vs Jobber 4.8" |
| Регалии после hook, не в начале | Параграф proof идет после pain |
| CTA = один открытый вопрос | Не "let me know", не конкретный слот |
| Длина ≤ 7 предложений (Email #1) | Посчитать |
| FU = новый угол, не "пингую" | Каждый FU имеет unique angle |
| Last FU = Shishkin ("что нужно") | Формат вопроса, не питча |
| Subject не рекламный | Интригующий, конкретный |

Если draft уже соответствует v2 (как Zuper) — не переписывать, только добавить траекторию если её нет.

Если draft НЕ соответствует — переписать, сохранив конкретику и сигналы.

### 5. Построить полную траекторию

Создай/обнови файл `studio/sales/outreach/{company-slug}.md` с полной траекторией по формату из [`_TEMPLATE_trajectory.md`](https://github.com/novostudiotech/claude/blob/main/studio/sales/outreach/_TEMPLATE_trajectory.md):

- Touch #0-4: Pre-warm (LinkedIn view, follow, like, validate email, infra check)
- Touch #5: Email #1 Cold (D0)
- Touch #6: LinkedIn connect (D0)
- Touch #7: Email #2 FU timing (D+3)
- Touch #8: LinkedIn DM #1 (D+3)
- Touch #9: Email #3 Value drop (D+7)
- Touch #10: LinkedIn DM #2 (D+7)
- Touch #11: Email #4 Urgency (D+14)
- Touch #12: Email #5 Last FU Shishkin (D+21)
- Touch #13: LinkedIn DM #3 Pattern break (D+24)
- Rollback rules
- Pre-send checklist

Все emails должны быть fully written (не placeholders). LinkedIn DMs — тоже конкретные.

### 6. Записать касания в Funnel sheet

Для каждого касания (Touch #5 — Touch #13) создай строку в Funnel sheet через content-hub:

```bash
curl -s -X POST http://localhost:7901/sheets/1Iiv4twaGpjAdfSoqQGDChC0Be3AcuwPej_Oa_dzogS4/add_row \
  -H 'Content-Type: application/json' \
  -d '{
    "Company": "{Company}",
    "OPP ID": "{OPP-ID}",
    "Contact": "{DM_Name}",
    "Touch Type": "{Touch_Type}",
    "Channel": "{Channel}",
    "Planned Date": "{Planned_Date}",
    "Sent Date": "",
    "Status": "planned",
    "Reply Date": "",
    "Reply Sentiment": "",
    "Subject": "{Subject_Line}",
    "Draft Path": "{Draft_Path}"
  }'
```

Значения Touch Type: `cold_email`, `fu1`, `value_drop`, `urgency`, `last_fu`, `linkedin_dm`, `pattern_break`.
Fallback: если hub недоступен (exit code != 0 или нет `"success":true`) -- записать касания только в файл draft (таблица вручную).

**Верификация после записи:** вызови find_row `{"query": {"Company": "{Company}", "Touch Type": "{Touch_Type}"}}` и проверь что данные легли в правильные колонки.

> **Паттерн:** Google Sheets запись — обязательная верификация после КАЖДОЙ записи (confidence: 0.85).

### 7. Создать saga-напоминалки

Для каждого касания создай задачу-напоминалку в saga-mcp:

```
mcp__saga-mcp__task_create(
  epic_id: 3,
  title: "Outreach {Company}: Touch #{N} — {Touch_Type} ({Planned_Date})",
  description: "Отправить {Touch_Type} для {Company} ({OPP-ID}).\n\nДрафт: studio/sales/outreach/{slug}.md\nКонтакт: {DM_Name} ({DM_Email})\nSubject: {Subject}\n\nПлановая дата: {Planned_Date}",
  priority: "medium"
)
```

Для Touch #5 (первый email) — priority: "high".
Для Touch #11 (urgency, если SDK deadline) — priority: "high".

### 8. Обновить opportunity

В `memory/opportunities.md` обнови OPP:
- Статус: `in_progress` (sequence запущена)
- Next action: "Touch #5 planned {D0_Date}"

### 9. Git + Result

```bash
git add studio/sales/outreach/{slug}.md memory/opportunities.md
git commit -m "worker: outreach-trajectory — {Company} OPP-{ID} sequence built"
git push
```

## Правила

- **Не отправляй email!** Только создание драфтов и Funnel rows. Отправка — ответственность Vasily.
- **Не выдумывай сигналы.** Только из данных (Mobile Prospects, App Store reviews, draft).
- **Каждый FU = новый угол.** Никаких "following up" / "circling back".
- **Gmail draft опционально:** если Gmail MCP доступен — создать draft для Touch #5. Если нет — только файл.
- **Один лид за запуск.** Не пытаться обработать несколько.

## Rollback

- Если Mobile Prospects sheet недоступен → работать только с данными из draft файла
- Если Funnel sheet недоступен → записать касания только в draft файл (таблица вручную)
- Если saga-mcp недоступен → записать напоминалки в `memory/queue.md`

## Smoke Test Criteria

Worker считается рабочим если на тестовом лиде:
1. ✅ Draft файл обновлен с полной траекторией (все emails + LinkedIn DMs written out)
2. ✅ Funnel sheet содержит 7-9 строк для этого лида
3. ✅ saga-mcp содержит 7-9 reminder задач с planned dates
4. ✅ Draft проходит v2 checklist (hook, регалии, CTA, длина)
