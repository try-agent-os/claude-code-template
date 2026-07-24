# Example Skills — AgentOS Heartbeat

A reference set of 12 skills ported from a live AgentOS deployment. Each skill is in current Claude Code skill format: directory with `SKILL.md` + frontmatter spec.

These skills are **examples** — they demonstrate patterns for building agents that scan inboxes, prep meetings, monitor Telegram, etc. They are not enabled by default. Copy what you need, adapt to your stack, and drop into `<repo>/.claude/skills/<name>/SKILL.md` (skills are watched live by Claude Code).

The system's own self-healing and strategist skills are **not** duplicated here — the live copies ship in [`agents/heartbeat/skills/`](../../agents/heartbeat/skills/) and run as part of the heartbeat. Read those for the self-heal / strategist patterns.

## Layout

```
examples/skills/
└── generic/              # 12 skills useful to any AgentOS deployment
    ├── morning-brief/SKILL.md
    ├── gmail-triage/SKILL.md
    ├── meeting-prep/SKILL.md
    └── ...
```

### `generic/` — drop-in candidates

Communication / inbox / pipeline:
- [`morning-brief`](generic/morning-brief/SKILL.md) — daily briefing (Calendar + tasks + PRs + pending replies)
- [`gmail-triage`](generic/gmail-triage/SKILL.md) — classify inbox, sync sent mail to contact timelines
- [`outbound-tracker`](generic/outbound-tracker/SKILL.md) — record outgoing email + Telegram into contacts
- [`reply-watchdog`](generic/reply-watchdog/SKILL.md) — surface contacts waiting on a reply >24h
- [`clickup-sync`](generic/clickup-sync/SKILL.md) — pull ClickUp pipeline into `memory/people.md`

Meetings:
- [`meeting-prep`](generic/meeting-prep/SKILL.md) — pre-meeting briefing from Fireflies + CRM + Gmail
- [`meeting-debrief`](generic/meeting-debrief/SKILL.md) — post-meeting transcript → action items → CRM

Contacts / memory:
- [`contact-enrichment`](generic/contact-enrichment/SKILL.md) — fill contact file from all connectors

Telegram (require [tdl](https://github.com/iyear/tdl)):
- [`telegram-scan`](generic/telegram-scan/SKILL.md) — periodic scan of all chats for signals
- [`telegram-export`](generic/telegram-export/SKILL.md) — deep export of one channel/chat to `resources/`
- [`telegram-channel-analytics`](generic/telegram-channel-analytics/SKILL.md) — top posts / themes / trends

Research:
- [`youtube-analysis`](generic/youtube-analysis/SKILL.md) — transcript → insights → `resources/youtube/`

## How to enable a skill

1. Pick a skill from `examples/skills/generic/<name>/SKILL.md`
2. Copy the directory to `<repo>/.claude/skills/<name>/`
3. Claude Code watches `.claude/skills/` live — the skill is available immediately
4. The skill matches against task content via its `description` and `when_to_use` fields

To use across projects, copy to `~/.claude/skills/<name>/` (user-level).

## Frontmatter cheatsheet

Every skill has YAML frontmatter at the top:

```yaml
---
name: my-skill                   # kebab-case identifier
description: <required>          # what the skill does + when to match (≤1536 chars total)
when_to_use: <optional>          # narrower trigger context (was `read_when` in legacy format)
allowed-tools: Read, Bash, ...   # only what the skill actually uses (whitelist)
paths: ["memory/**/*.md"]        # only when scoped to specific globs
context: fork                    # for read-only research skills (run in forked agent)
agent: Explore                   # paired with context: fork
disable-model-invocation: true   # for destructive skills — won't auto-trigger, only explicit invocation
---
```

What we applied here:
- `context: fork` + `agent: Explore` — read-only research skills: `contact-enrichment`, `reply-watchdog`, `telegram-channel-analytics`
- `disable-model-invocation: true` — skills that mutate shared state (Google Sheets, CRM): `clickup-sync`
- `paths:` — only for `reply-watchdog` (file-scoped)
- Other skills use plain `description` + `allowed-tools` whitelist

## Caveats

- **Russian content.** All skill bodies are in Russian — the original AgentOS instance was Russian-speaking. Translate as needed.
- **MCP server dependencies.** Many skills assume specific MCP servers are running:
  - `claude-peers` (HTTP broker on `:7899`) — for cross-agent messaging to a Telegram operator
  - `saga-mcp` (`:3851`) — task tracker, see [@novostudiotech/saga-mcp](https://github.com/novostudiotech/saga-mcp)
  - `telegram-mcp` (`:3848`) — Bot API wrapper for outbound messages
  - Optional: `claude_ai_Gmail`, `claude_ai_Google_Calendar`, `claude_ai_Fireflies`, `claude_ai_ClickUP` (Composio/Rube-style integrations)
- **CLI tool dependencies.** `tdl` (Telegram MTProto client) for telegram-* skills; `yt-dlp` + `youtube-transcript-api` for youtube-analysis; `gh` CLI optional for morning-brief.
- **Hardcoded paths.** Original skills referenced absolute paths. These were replaced with `${CLAUDE_PROJECT_DIR}/...` (Claude Code expands this at runtime). Auxiliary scripts (`slim-tdl-export.py`, `youtube-analyze.py`) are referenced by path but not included in the template — they live in the original repo.
- **Workflow assumption.** These skills assume an AgentOS-style heartbeat dispatcher creates tasks in the queue, picks them up, and routes to workers. They run fine standalone via `Skill` tool invocation as well.

## Frontmatter validation

All SKILL.md files have YAML frontmatter that:
- Includes required `name` and `description`
- Uses `when_to_use` (renamed from legacy `read_when`)
- Lists explicit `allowed-tools` (no implicit "everything")
- Drops legacy `type:` and `trigger:` (replaced by description-driven matching)

Run a quick check:
```bash
for f in examples/skills/*/*/SKILL.md; do
  python3 -c "import sys, yaml; yaml.safe_load(open('$f').read().split('---')[1])" || echo "BAD: $f"
done
```

## Source

These were ported from `agents/heartbeat/skills/*.md` in the AgentOS knowledge-base repo. Original format used a different frontmatter (`type:`, `trigger:`, `read_when:`). This port preserves the body content character-for-character and modernizes the frontmatter to the current Claude Code skill spec.
