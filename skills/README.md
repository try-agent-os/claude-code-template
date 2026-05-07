# AgentOS Skills — Индекс

Каждый скилл — самодостаточная процедура с AgentSkills frontmatter (`title`, `summary`, `read_when`).
Dispatcher читает `read_when` для автоматического матчинга задачи со скиллом.

## Как использовать

```python
# В dispatcher — всегда run_in_background: true
Agent(
    prompt=f"Выполни скилл meeting-prep. Прочитай skills/meeting-prep.md и следуй инструкциям.",
    run_in_background=True
)
```

---

## Базовые скиллы (минимальный набор шаблона)

| Скилл | Файл | read_when |
|-------|------|-----------|
| morning-brief | [morning-brief.md](morning-brief.md) | Ежедневно утром; задача "morning-brief", утренний брифинг |
| meeting-prep | [meeting-prep.md](meeting-prep.md) | За 30-60 мин до внешней встречи |
| meeting-debrief | [meeting-debrief.md](meeting-debrief.md) | Через 2ч после окончания внешней встречи |
| contact-enrichment | [contact-enrichment.md](contact-enrichment.md) | Новый или неполный контакт; ручной запрос "обогати контакт {имя}" |
| event-correlation | [event-correlation.md](event-correlation.md) | После каждого скана (gmail, telegram, calendar) |
| memory-search | [memory-search.md](memory-search.md) | Перед сложной задачей для context injection |

> Это минимальный baseline. Расширяй под свой домен — добавляй скиллы для outreach, sales, content, research и т.п.

---

## Связи между скиллами (типовой flow)

```
gmail-triage / calendar-scan → event-correlation → contact-enrichment
calendar → meeting-prep
calendar → meeting-debrief
```
