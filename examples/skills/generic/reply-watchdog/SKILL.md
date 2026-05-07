---
name: reply-watchdog
description: Сканирует memory/contacts/*.md и выявляет контакты ожидающие ответа пользователя более 24ч. Предотвращает ADHD task-switch потери в networking.
when_to_use: Часть morning-brief Step 4; после telegram-scan при обнаружении новых входящих; пользователь сказал "кому я не ответил?", "pending replies".
allowed-tools: Read, Grep, Bash
paths:
  - "memory/contacts/*.md"
context: fork
agent: Explore
---

# Skill: Reply Watchdog

Проверяет контакты где собеседник ответил, а пользователь ещё не отреагировал.

**Паттерн:** пользователь инициирует → получает ответ → контекст переключается → ответ теряется.

---

## Алгоритм

```bash
cd "${CLAUDE_PROJECT_DIR}"

PENDING=()
for f in memory/contacts/*.md; do
  name=$(grep -m1 "^# " "$f" | sed 's/# //')
  next_step=$(grep -A1 "Следующий шаг:" "$f" | head -2)
  last_date=$(grep -o "### 2026-[0-9-]*" "$f" | tail -1)

  # Признаки ожидающего ответа:
  if grep -q "ответил\|предложил встречу\|ещё не ответил\|не ответил на предложение" "$f"; then
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
⚡ Ждут ответа:
• Имя 1 — предложил встречу вт 22.04 (3 дня без ответа!) → подтвердить/отклонить
• Имя 2 — окно DM после буткемпа
```

## Когда запускать

- Ежедневно в morning-brief (Step 4)
- После telegram-scan при обнаружении новых входящих

## Интеграция

1. В `morning-brief` → добавить Reply Watchdog check в Step 4
2. Worker читает `${CLAUDE_PROJECT_DIR}/memory/contacts/*.md` напрямую (нет внешних зависимостей)
3. Результат пишет в секцию `⚡ Требует ответа` в Telegram сообщении
