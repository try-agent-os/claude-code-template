---
name: self-improvement-loop
description: Полный цикл улучшений AgentOS и бизнес-процессов по модели Scan→Evaluate→Spike→Integrate→Measure. Включает тестирование (spike) и доказательство гипотезы перед интеграцией. Запускается как strategist-worker (Opus, ~30 мин).
when_to_use: Регулярный self-improvement цикл; пользователь сказал "улучшение системы", "spike", "autoresearch", "оптимизация процессов", "bottleneck".
allowed-tools: Read, Edit, Write, Bash, WebSearch, WebFetch, mcp__saga-mcp__task_create, mcp__saga-mcp__task_list
---

# Skill: Self-Improvement Loop

Замкнутый цикл улучшений AgentOS и бизнес-процессов. По модели autoresearch:
**Scan → Evaluate → Spike → Integrate → Measure**

Запускается как **strategist-worker** (Opus, ~30 мин). Отличие от `self-upgrade-scan`:
- `self-upgrade-scan` — находит инструменты для инфры, без тестирования
- `self-improvement-loop` — полный цикл, включая бизнес-процессы, и доказательство перед интеграцией

---

## Шаг 1: SCAN

### Области поиска (расширенные)

**A. Инфраструктура AgentOS** (из self-upgrade-scan)
- Agent memory: graph DB, hybrid retrieval, temporal KG
- Agent architecture: orchestration, tool use, multi-agent patterns
- MCP ecosystem: новые серверы, интеграции
- LLM efficiency: prompt caching, model routing, context compression

**B. Бизнес-процессы**
- Outreach automation: новые подходы к cold email, LinkedIn automation, reply tracking
- CRM & pipeline: автоматизация стадий, scoring моделей
- Proposal/КП: инструменты для быстрой генерации, track открытий

**C. Productivity пользователя**
- Automation: zapier/make alternatives, n8n workflow patterns
- Research tools: web scraping, market intelligence, competitive monitoring
- Meeting productivity: summary tools, action item extraction
- Calendar/scheduling: автоматизация booking, time blocking

**D. Внутренняя аналитика**
- Читать `${CLAUDE_PROJECT_DIR}/memory/learnings.md` → найти задачи, которые делаются вручную снова и снова
- Читать `${CLAUDE_PROJECT_DIR}/memory/patterns.md` → найти паттерны с высоким confidence, но без автоматизации
- Читать `${CLAUDE_PROJECT_DIR}/logs/workers/` → какие workers часто завершаются `blocked`?
- Читать `${CLAUDE_PROJECT_DIR}/memory/schedule.md` → какие проверки выполняются нерегулярно?

### Источники

```
Web search:
  - "AI business automation 2026"
  - "sales outreach tools alternatives"
  - "n8n workflow ai agents"
GitHub trending: topics = ai-agents, automation, productivity
HN: "Ask HN: what's your team automating in 2026"
```

### Результат Scan

Список кандидатов с кратким описанием:
```
- **[название]** — [что делает]. Область: [A/B/C/D]. Источник: [ссылка или "internal"]
```

---

## Шаг 2: EVALUATE

### Скоринг каждого кандидата

| Критерий | Баллы | Описание |
|----------|-------|----------|
| **Fit** | 0-3 | 0=нет связи, 1=слабая, 2=хорошая, 3=идеальная |
| **Impact** | 0-3 | 0=косметика, 1=удобство, 2=экономия 1ч/нед, 3=разблокирует bottleneck |
| **Effort** | 1-3 | 1=часы, 2=дни, 3=недели |
| **No-Docker** | pass/fail | Fail если требует Docker без self-hosted альтернативы |
| **No-GPU** | pass/fail | Fail если требует GPU |

**Формула:** `score = (fit + impact) / effort`

**Фильтры (fail → skip):**
- Docker-only без альтернативы → skip
- GPU-only → skip
- SaaS-only без self-hosted или API → skip
- Требует полного рефакторинга (>1 недели effort) → skip (создай только research task)
- Уже есть в текущем стеке → skip

**Порог для Spike:** `score >= 2.5` И оба фильтра pass

Если нет кандидатов выше порога — записать в историю, завершить с `status: no-candidates`.

---

## Шаг 3: SPIKE

### Для каждого кандидата (score >= 2.5)

**Принцип:** доказать гипотезу за ≤ 30 мин без риска для production системы.

**Изоляция:**
- Инструмент/скрипт: тест в `/tmp/spike-{tool}-{date}/`
- Код: git worktree (если нужны изменения в репо)
- НЕ менять production файлы в ходе spike

**Шаги spike:**

1. **Определить гипотезу** (1-2 предложения):
   ```
   "Если использовать X, то Y улучшится с A до B"
   ```

2. **Определить критерии успеха** (бинарные, до запуска):
   ```
   - [ ] Работает без Docker
   - [ ] Установка < 10 мин
   - [ ] Базовая функция работает
   - [ ] API/CLI существует
   ```

3. **Выполнить spike:**
   ```bash
   cd /tmp/spike-{tool}-$(date +%Y%m%d)
   # установка, конфигурация, тест
   ```

4. **Записать результат:**
   ```
   Hypothesis: [что проверяли]
   Result: PASS | FAIL
   Evidence: [что именно сделали и что получили]
   Time spent: [мин]
   ```

**Если spike > 30 мин** — стоп, записать `TIMEOUT`, создать отдельную задачу.

**Количество spike за один запуск:** максимум 2.

---

## Шаг 4: INTEGRATE

**При PASS:**

1. Создать задачу в saga-mcp:
   ```
   mcp__saga-mcp__task_create(
     epic_id: <infra_epic>,
     title: "Integrate [tool]: [одна строка что добавляет]",
     description: "Spike PASSED [дата]. Evidence: [ссылка на историю]. Scope: [что нужно сделать]",
     priority: "medium"
   )
   ```

2. Обновить `${CLAUDE_PROJECT_DIR}/memory/context.md` если это меняет статус системы

3. Добавить в staging:
   ```
   memory/patterns-staging.md → новая запись
   ```

**При FAIL:**

1. Записать в историю улучшений (шаг 5) с причиной
2. НЕ создавать задачу
3. Пометить кандидата как `rejected: [причина]` в файле истории

**При TIMEOUT:**

1. Создать задачу `priority: low` — исследовать дальше
2. Записать в историю как `deferred`

---

## Шаг 5: MEASURE + ИСТОРИЯ

### Запись в историю улучшений

Файл: `${CLAUDE_PROJECT_DIR}/research/self-improvement-history/{YYYY-MM}.md`

```markdown
## [YYYY-MM-DD] — [название кандидата]

**Область:** A/B/C/D
**Источник:** [откуда взяли идею]
**Score:** [fit+impact/effort = X]
**Spike result:** PASS | FAIL | TIMEOUT | SKIPPED
**Hypothesis:** [что проверяли]
**Evidence:** [что получили]
**Outcome:** integrate | reject | defer
**Saga task:** #[id] | none
**Time spent:** [мин]

**Baseline metric (до):** [что измеряли]
**Target metric (после):** [ожидаемое улучшение]
**Actual metric:** [заполнить при следующем запуске]
```

### Проверка предыдущих интеграций

При каждом запуске — прочитать историю за последний месяц:
- Есть ли задачи с `Outcome: integrate` и пустым `Actual metric`?
- Если задача уже выполнена → заполнить `Actual metric`
- Сравнить baseline vs actual → delta

---

## Алгоритм запуска

```
1. Читать memory/learnings.md + memory/patterns.md (контекст ошибок)
2. SCAN: собрать кандидатов
3. EVALUATE: отсеять, scored top-2 → Spike
4. SPIKE: тест в /tmp, max 30 мин
5. INTEGRATE: создать saga task если PASS
6. MEASURE: обновить историю, заполнить actual metrics
7. Записать в research/self-improvement-history/{YYYY-MM}.md
8. Обновить check-log.md
```

---

## Фильтр "не тратить время"

- Инструменты только для enterprise ($500+/мес) → skip
- Требует смены стека (замени launchd на Kubernetes) → skip
- Дублирует то, что уже есть в репо
- Маркетинговые инструменты без API/CLI → skip

---

## Вывод

После завершения — краткий отчет в `logs/workers/self-improv-agent/result.md`:

```
## Self-Improvement Loop — {date}

### Кандидаты после Evaluate
- **[tool]** — score: X, verdict: spike/skip

### Spike результаты
- **[tool]** — PASS/FAIL. Evidence: [1-2 строки]

### Интеграции
- Saga task #[id]: [title]

### Measure
- [tool из прошлого] — baseline: X, actual: Y, delta: Z%

### Итог
[1-2 предложения]
```
