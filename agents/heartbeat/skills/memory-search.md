---
name: memory-search
description: Searches across all AgentOS memory files (patterns, learnings, signals, opportunities, contacts, performance). Used before tasks for context injection and during analysis.
type: procedure
read_when: Before a complex task for context injection; "search memory for {topic}"; signal/opportunity analysis; meta-review.
---

# Memory Search — AgentOS Skill

## When to call

- Before a complex task (context injection)
- When analyzing signals/opportunities (looking for connections)
- During meta-review (looking for patterns)

## How to search

### Keyword search across memory/

```bash
grep -ril "keyword" ../../memory/ --include="*.md" | head -10
```

### Search contacts

```bash
grep -ril "name or company" ../../memory/contacts/ --include="*.md"
```

### Search patterns (with confidence)

```bash
grep "keyword" ../../memory/patterns.md
```

### Search signals

```bash
grep -A5 "keyword" ../../memory/signals.md
```

### Search opportunities

```bash
grep -A5 "company\|OPP-" ../../memory/opportunities.md
```

### Search performance (trajectory)

```bash
grep -B1 -A5 "keyword" ../../memory/performance.md | head -30
```

## Result

Return a list of found entries with paths and relevant lines. If nothing is found — say "not found in memory".
