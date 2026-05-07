---
name: morning-brief
description: Утренний брифинг — собирает встречи, ClickUp задачи, PR статус, pending replies и горячие темы. Отправляет Vasily в Telegram через operator.
type: scheduled
trigger: morning-brief, утренний брифинг, доброе утро, morning
read_when: morning-brief, ежедневный брифинг
---

# Скилл: Morning Brief

Ежедневный утренний брифинг. Собирает контекст дня и отправляет сводку Vasily в Telegram.

## Когда запускать

- Ежедневно утром по расписанию (`memory/schedule.md`: `morning-brief`, 24ч)
- Приоритет задачи: medium

---

## Алгоритм

### Step 1: Google Calendar — встречи на сегодня

Получить события на сегодня через `mcp__claude_ai_Google_Calendar__list_events`.

Формат для каждого события:
- `HH:MM — Название`
- Если `needsAction` — добавить `(не подтверждено!)`

Если событий нет — написать "Свободный день".

---

### Step 2: ClickUp — urgent/due задачи

Проверить задачи workspace 4557261 (Symoditi) с приоритетом urgent или due today/overdue.

Максимум 5 задач по убыванию срочности. Формат: `DEV-XXX: название`.

Если ничего нет — блок не выводить.

---

### Step 3: Open PRs

```bash
gh pr list --repo symoditi/platform --state open --json number,title,statusCheckRollup 2>/dev/null
```

Формат: `N открытых` + флаг `❌ CI` если есть blocked checks.

---

### Step 4: Reply Watchdog — ждут ответа Vasily

Сканируй `memory/contacts/*.md` на признаки pending reply:

```bash
PENDING=()
for f in memory/contacts/*.md; do
  name=$(grep -m1 "^# " "$f" | sed 's/# //')
  # Признаки ожидающего ответа:
  if grep -q "ответил\|предложил встречу\|Vasily ещё не ответил\|не ответил на предложение\|pending_reply: true\|last_contact_direction: incoming" "$f"; then
    # Исключить если DONE/closed/архив
    if ! grep -qi "DONE\|closed\|архив" "$f"; then
      next=$(grep 'Следующий шаг' "$f" | head -1 | sed 's/.*Следующий шаг[^:]*://;s/^\s*//')
      last=$(grep -o "### 2026-[0-9-]*" "$f" | tail -1)
      PENDING+=("• $name — $next ($last)")
    fi
  fi
done
```

Если `PENDING` не пустой — добавить блок в итоговое сообщение:

```
⚡ Ждут ответа:
• [Имя] — [контекст 1 строка]
```

Если pending нет — блок не добавлять (не спамить).

---

### Step 5: Горячие темы

Прочитать `memory/context.md`. Извлечь 2-3 самых горячих пункта:
- Активные сделки (ожидающие подписи/ответа)
- Критичные дедлайны
- Urgent задачи пользователю

---

### Step 6: Собрать и отправить в Telegram

Формат сообщения (блоки с пустыми значениями — пропускать):

```
🌅 DD.MM — Доброе утро!

📅 Сегодня:
• HH:MM — Название
• HH:MM — Название (не подтверждено!)

🔥 Горячее:
• [пункт 1]
• [пункт 2]

⚡ Ждут ответа:
• [Имя] — [контекст]

🔧 Urgent ClickUp:
• DEV-XXX: название

🔀 PRs: N открытых
```

Отправить через claude-peers:

```bash
PEERS=$(curl -s http://127.0.0.1:7899/list-peers -H 'Content-Type: application/json' -d '{"scope":"machine","cwd":"/","git_root":null}')
OPERATOR_ID=$(echo "$PEERS" | python3 -c "import json,sys; peers=json.load(sys.stdin); print(next((p['id'] for p in peers if 'operator' in p.get('cwd','')), ''))")
if [ -n "$OPERATOR_ID" ]; then
  curl -s http://127.0.0.1:7899/send-message \
    -H 'Content-Type: application/json' \
    -d "{\"to_id\": \"$OPERATOR_ID\", \"from_id\": \"morning-brief\", \"text\": \"<СООБЩЕНИЕ>\"}"
fi
```

---

### Step 7: Обновить check-log

```bash
echo "morning-brief | $(date '+%Y-%m-%d %H:%M') | отправлен" >> memory/check-log.md
```

---

## Ошибки

| Ситуация | Действие |
|----------|----------|
| Google Calendar недоступен | Пропустить Step 1, продолжить |
| ClickUp MCP недоступен | Пропустить Step 2, продолжить |
| Operator не найден в peers | Пропустить отправку, записать в result.md |
| `memory/contacts/` пуст | Step 4 → блок не добавлять |
