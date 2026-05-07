---
name: self-upgrade-scan
description: Ежедневный поиск инструментов и подходов для улучшения AgentOS. Сканирует GitHub Trending, HN, Reddit по областям (agent memory, MCP ecosystem, LLM efficiency). Создает research-задачи в saga-mcp. Без тестирования (только поиск — в отличие от self-improvement-loop).
when_to_use: Ежедневный self-upgrade scan; пользователь сказал "улучшение агента", "новые инструменты", "MCP", "agent tools", "стек", "upgrade".
allowed-tools: Read, Edit, Write, Bash, WebSearch, WebFetch, mcp__saga-mcp__task_create
---

# Skill: Self-Upgrade Scan

Ежедневный поиск инструментов и подходов для улучшения AgentOS.

## Текущий стек (для сравнения)

Адаптируй под свой стек. Пример:

- **Task management:** saga-mcp (SQLite, MCP, HTTP/SSE)
- **Memory (files):** markdown файлы в `memory/`
- **Memory (vector):** Mem0 / Qdrant / Ollama (опционально)
- **Memory (graph):** под исследованием
- **Agent framework:** Claude Code CLI + tmux workers
- **Communication:** claude-peers (HTTP broker), telegram-mcp (Bot API)
- **Scheduling:** launchd / systemd + dispatcher.sh
- **Telegram read:** tdl (MTProto) — опционально

## Области поиска

1. **Agent memory** — graph DB, hybrid retrieval, episodic memory, temporal knowledge
2. **Agent architecture** — orchestration frameworks, multi-agent patterns, tool use optimization
3. **MCP ecosystem** — новые MCP серверы, протоколы, интеграции
4. **Developer tools** — CLI tools для агентов, debugging, observability
5. **LLM efficiency** — prompt caching, context compression, model routing
6. **Knowledge management** — PKM tools с API, Zettelkasten engines, linked notes

## Алгоритм

1. Web search по каждой области (2-3 запроса):
   - "AI agent tools 2026", "agent memory framework new"
   - "MCP server new releases", "claude code plugins"
   - GitHub trending: AI, agents, MCP, knowledge-graph
   - Hacker News, Reddit r/LocalLLaMA, r/MachineLearning
2. Для каждой находки оценить:
   - Что это делает
   - Чем лучше текущего решения в стеке
   - Сложность интеграции (drop-in / требует рефакторинг)
   - Зрелость (production-ready / experimental)
3. Если нашел стоящее (улучшает текущий стек, production-ready или close):
   - Создай research task в saga-mcp (epic Research)
   - Приоритет: high если решает известную проблему, medium если улучшение
4. Записать сканирование в `${CLAUDE_PROJECT_DIR}/research/self-upgrade-scan/{date}.md`
5. Обновить check-log.md строку self-upgrade-scan

## Фильтр (не тратить время)

- SaaS-only без self-hosted — пропускай
- Требует GPU — пропускай
- Python-only без CLI/API — пропускай (workers на bash + claude)
- Фреймворки требующие переписать все — пропускай

## Результат

Файл `${CLAUDE_PROJECT_DIR}/research/self-upgrade-scan/{date}.md`:
```
# Self-Upgrade Scan — {date}

## Найдено
- **{tool}** — {что делает}. {чем лучше}. Verdict: {skip/research/integrate}

## Создано задач
- #{id} — {title}

## Итог
{1-2 предложения: нашли что-то стоящее или стек актуален}
```
