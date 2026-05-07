---
name: self-upgrade-scan
description: Daily search for tools and approaches that could improve AgentOS. Scans GitHub Trending, HN, and Reddit across areas (agent memory, MCP ecosystem, LLM efficiency). Creates research tasks. Search-only — no testing (unlike self-improvement-loop).
type: procedure
read_when: Daily search for tools that could improve the AgentOS stack; "self-upgrade", "new tools", "MCP", "agent tools", "stack upgrade".
---

# Skill: Self-Upgrade Scan

Daily search for tools and approaches that could improve AgentOS.

## Current stack (for comparison)

Edit this section to match your deployment. Example template:

- **Task management:** saga-mcp (SQLite, MCP, HTTP/SSE)
- **Memory (files):** markdown files under memory/
- **Memory (vector):** Mem0 (Qdrant + Ollama nomic-embed-text)
- **Memory (graph):** under research
- **Agent framework:** Claude Code CLI + tmux workers
- **Communication:** claude-peers (HTTP broker), telegram-mcp (Bot API + grammY)
- **Scheduling:** launchd + dispatcher.sh
- **Telegram read:** tdl (MTProto)

## Search areas

1. **Agent memory** — graph DB, hybrid retrieval, episodic memory, temporal knowledge
2. **Agent architecture** — orchestration frameworks, multi-agent patterns, tool-use optimization
3. **MCP ecosystem** — new MCP servers, protocols, integrations
4. **Developer tools** — CLI tools for agents, debugging, observability
5. **LLM efficiency** — prompt caching, context compression, model routing (when Haiku, when Sonnet)
6. **Knowledge management** — PKM tools with API, Zettelkasten engines, linked notes

## Algorithm

1. Web search across each area (2-3 queries):
   - "AI agent tools 2026", "agent memory framework new"
   - "MCP server new releases", "claude code plugins"
   - GitHub trending: AI, agents, MCP, knowledge-graph
   - Hacker News, Reddit r/LocalLLaMA, r/MachineLearning
2. For each find, evaluate:
   - What it does
   - How it improves on the current AgentOS stack
   - Integration cost (drop-in / requires refactor)
   - Maturity (production-ready / experimental)
3. If you find something worthwhile (improves the current stack, production-ready or close):
   - Create a research task in the **Research** epic (epic IDs resolve via `memory/epic-map.json`)
   - Priority: high if it solves a known problem, medium if it's an enhancement
4. Record the scan in `research/self-upgrade-scan/{date}.md`
5. Update the `self-upgrade-scan` row in `check-log.md`

## Filter (don't waste time)

- SaaS-only without a self-hosted option — skip
- Requires GPU — skip (we run on CPU/Apple Silicon)
- Python-only without CLI/API — skip (workers run on bash + claude)
- Frameworks that require rewriting everything — skip (we want drop-in improvements)

## Result

File `research/self-upgrade-scan/{date}.md`:

```
# Self-Upgrade Scan — {date}

## Found
- **{tool}** — {what it does}. {why it's better}. Verdict: {skip/research/integrate}

## Tasks created
- #{id} — {title}

## Summary
{1-2 sentences: did we find anything worthwhile, or is the stack still current}
```
