# Claude Code Template

> Minimal AgentOS template for Claude Code: orchestrator + dispatcher + one example skill.

## Structure

```
.
├── CLAUDE.md                  # Root system prompt for the orchestrator
├── agents/
│   ├── operator/CLAUDE.md     # Long-running agent (Telegram interface)
│   └── dispatcher/CLAUDE.md   # Ephemeral cron agent (spawns workers)
└── skills/
    └── morning-brief.md        # Example reusable skill
```

## Idea

The operator holds an ongoing session and talks to the user. The dispatcher wakes up on cron, reads the task queue, spawns short-lived workers, collects their results, and exits.

The template is intentionally minimal — add your own sub-agents, skills, and infrastructure for your domain.

## License

MIT
