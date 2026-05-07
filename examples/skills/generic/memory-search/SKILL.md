---
name: memory-search
description: Поиск по всем файлам памяти AgentOS (patterns, learnings, signals, opportunities, contacts, performance). Вызывается перед задачами для context injection и при анализе.
when_to_use: Перед сложной задачей (context injection); при анализе сигналов/возможностей (поиск связей); при meta-review (поиск паттернов); пользователь сказал "поищи в памяти про {тему}".
allowed-tools: Read, Grep, Bash
paths:
  - "memory/**/*.md"
context: fork
agent: Explore
---

# Memory Search — Скилл AgentOS

> Read-only research skill. Запускается в forked context — собирает релевантные записи из memory/ и возвращает summary.

## Когда вызывать
- Перед сложной задачей (context injection)
- При анализе сигналов/возможностей (поиск связей)
- При meta-review (поиск паттернов)

## Как искать

### Keyword search по memory/
```bash
grep -ril "ключевое слово" "${CLAUDE_PROJECT_DIR}/memory/" --include="*.md" | head -10
```

### Поиск по контактам
```bash
grep -ril "имя или компания" "${CLAUDE_PROJECT_DIR}/memory/contacts/" --include="*.md"
```

### Поиск по паттернам (с confidence)
```bash
grep "ключевое слово" "${CLAUDE_PROJECT_DIR}/memory/patterns.md"
```

### Поиск по сигналам
```bash
grep -A5 "ключевое слово" "${CLAUDE_PROJECT_DIR}/memory/signals.md"
```

### Поиск по возможностям
```bash
grep -A5 "компания\|OPP-" "${CLAUDE_PROJECT_DIR}/memory/opportunities.md"
```

### Поиск по performance (trajectory)
```bash
grep -B1 -A5 "ключевое слово" "${CLAUDE_PROJECT_DIR}/memory/performance.md" | head -30
```

## Результат

Вернуть список найденных записей с путями и релевантными строками. Если ничего не найдено — сказать "не найдено в memory".
