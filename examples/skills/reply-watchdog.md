---
name: reply-watchdog
description: Сканирует memory/contacts/*.md и выявляет контакты ожидающие ответа Vasily >24ч. Предотвращает ADHD task-switch потери в networking (4+ подтвержденных случаев).
type: check
trigger: reply, watchdog, pending, контакт ждет, ответить, не ответил, peding replies
read_when: morning-brief, telegram-scan, network-check, daily-check
---

# Skill: Reply Watchdog

Проверяет контакты где собеседник ответил, а Vasily ещё не отреагировал.

**Паттерн:** Vasily инициирует → получает ответ → контекст переключается → ответ теряется.
**Confidence:** 0.60 (4 подтвержденных случая: Golman, Pochukalin, Краснопеев×2)

---

## Алгоритм

```bash
cd /path/to/repo

PENDING=()
for f in memory/contacts/*.md; do
  name=$(grep -m1 "^# " "$f" | sed 's/# //')
  next_step=$(grep -A1 "Следующий шаг:" "$f" | head -2)
  last_date=$(grep -o "### 2026-[0-9-]*" "$f" | tail -1)
  
  # Признаки ожидающего ответа:
  if grep -q "ответил\|предложил встречу\|Vasily ещё не ответил\|не ответил на предложение" "$f"; then
    # Исключить если статус done/closed
    if ! grep -q "DONE\|closed\|архив" "$f"; then
      echo "⚡ $name | $last_date"
      echo "   $(grep 'Следующий шаг' "$f" | head -1)"
    fi
  fi
done
```

## Приоритизация

| Сигнал | Приоритет |
|--------|-----------|
| Предложена встреча (завтра/послезавтра) | 🔴 CRITICAL |
| Ответ получен >48ч назад | 🔴 HIGH |
| Ответ получен 24-48ч назад | 🟡 MEDIUM |
| Draft ждет одобрения >72ч | 🟡 MEDIUM |

## Вывод в morning-brief

Если найдены pending — добавить блок в Telegram-сообщение:

```
⚡ Ждут ответа Vasily:
• Andrey Краснопеев — предложил встречу вт 22.04 (3 дня без ответа!) → подтвердить/отклонить
• Vlad Pochukalin — окно DM после буткемпа
```

## Когда запускать

- Ежедневно в morning-brief (Step 4)
- После telegram-scan при обнаружении новых входящих

## Интеграция

1. В `agents/heartbeat/skills/morning-brief.md` → добавить Reply Watchdog check в Step 4
2. Worker читает `memory/contacts/*.md` напрямую (нет внешних зависимостей)
3. Результат пишет в секцию `⚡ Требует ответа` в Telegram сообщении
