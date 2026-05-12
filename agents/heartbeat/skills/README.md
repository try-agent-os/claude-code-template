# AgentOS Skills — Index

Each skill is a self-contained procedure with AgentSkills frontmatter (`title` or `name`, `summary` or `description`, `read_when`).
The dispatcher reads `read_when` to automatically match a task to a skill.

## How to use

```python
# In heartbeat — always run_in_background: true
Agent(
    prompt=f"Run the {skill} skill. Read agents/heartbeat/skills/{skill}.md and follow the instructions.",
    run_in_background=True
)
```

---

## Worker Skills (called from dispatcher)

| Skill | File | read_when |
|-------|------|-----------|
| memory-search | [memory-search.md](memory-search.md) | Before a complex task for context injection; "search memory for {topic}" |
| event-correlation | [event-correlation.md](event-correlation.md) | After every connector scan (gmail, telegram, calendar, etc.) |
| self-improvement-loop | [self-improvement-loop.md](self-improvement-loop.md) | Runs as a strategist-worker for the full Scan→Evaluate→Spike→Integrate cycle |
| self-upgrade-scan | [self-upgrade-scan.md](self-upgrade-scan.md) | Daily search for tools that could improve the AgentOS stack |
| self-heal-diagnose | [self-heal-diagnose.md](self-heal-diagnose.md) | crash_streak >= 3 or zombie/MAX_ITER; need to diagnose root cause before fix |
| self-heal-autofix | [self-heal-autofix.md](self-heal-autofix.md) | After self-heal-diagnose with diagnosis JSON; auto_fixable=true |

---

## Strategist Skills (called from strategist-prompt)

| Skill | File | read_when |
|-------|------|-----------|
| health-watchdog | [strategist/health-watchdog.md](strategist/health-watchdog.md) | **First in every strategist cycle** — system health check |
| signal-analysis | [strategist/signal-analysis.md](strategist/signal-analysis.md) | New signals accumulated in signals.md; need conversion to tasks |
| business-analysis | [strategist/business-analysis.md](strategist/business-analysis.md) | Analyze data through lenses (configurable via `memory/lenses.yaml`) to find concrete opportunities |
| blocker-resolution | [strategist/blocker-resolution.md](strategist/blocker-resolution.md) | Blocked tasks in saga-mcp |
| self-improvement | [strategist/self-improvement.md](strategist/self-improvement.md) | Regular cycle — pattern confidence updates and performance review |
| worker-results-analysis | [strategist/worker-results-analysis.md](strategist/worker-results-analysis.md) | heartbeat_count % 5 == 0 (every 5 strategist cycles) |

---

## Skill relationships

```
connector scans ──► event-correlation
health-watchdog ──► self-heal-diagnose ──► self-heal-autofix
strategist cycle:
  health-watchdog → signal-analysis → business-analysis → blocker-resolution → self-improvement
  every 5 cycles: + worker-results-analysis
  daily/weekly:   + self-upgrade-scan, self-improvement-loop
```

---

## Reference patterns

For domain-specific reference skills (Telegram scanning, Gmail triage, mobile prospect discovery, calendar management, etc.), see `examples/skills/` at the repository root. Those are real-deployment skills you can adapt to your own workflows.
