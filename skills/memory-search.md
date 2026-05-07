---
name: memory-search
description: Поиск по всем файлам памяти AgentOS (patterns, learnings, signals, opportunities, contacts, performance). Вызывается перед задачами для context injection и при анализе.
type: procedure
---

# Memory Search — Скилл AgentOS

## Когда вызывать
- Перед сложной задачей (context injection)
- При анализе сигналов/возможностей (поиск связей)
- При meta-review (поиск паттернов)

## Как искать

### Keyword search по memory/
```bash
grep -ril "ключевое слово" ../../memory/ --include="*.md" | head -10
```

### Поиск по контактам
```bash
grep -ril "имя или компания" ../../memory/contacts/ --include="*.md"
```

### Поиск по паттернам (с confidence)
```bash
grep "ключевое слово" ../../memory/patterns.md
```

### Поиск по сигналам
```bash
grep -A5 "ключевое слово" ../../memory/signals.md
```

### Поиск по возможностям
```bash
grep -A5 "компания\|OPP-" ../../memory/opportunities.md
```

### Поиск по performance (trajectory)
```bash
grep -B1 -A5 "ключевое слово" ../../memory/performance.md | head -30
```

## Результат

Вернуть список найденных записей с путями и релевантными строками. Если ничего не найдено — сказать "не найдено в memory".
