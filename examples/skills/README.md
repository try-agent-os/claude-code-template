# Example Skills — AgentOS Heartbeat

A reference set of 31 skills ported from a live AgentOS deployment (Novo Studio). Each skill is in current Claude Code skill format: directory with `SKILL.md` + frontmatter spec.

These skills are **examples** — they demonstrate patterns for building agents that scan inboxes, prep meetings, monitor Telegram, run self-healing loops, etc. They are not enabled by default. Copy what you need, adapt to your stack, and drop into `<repo>/.claude/skills/<name>/SKILL.md` (skills are watched live by Claude Code).

## Layout

```
examples/skills/
├── generic/              # 27 skills useful to any AgentOS deployment
│   ├── morning-brief/SKILL.md
│   ├── gmail-triage/SKILL.md
│   ├── meeting-prep/SKILL.md
│   └── ...
└── novo-specific/        # 4 skills bound to Novo Studio's mobile-services business
    ├── mobile-prospect-discovery/SKILL.md
    ├── mobile-prospect-scan/SKILL.md
    ├── auto-outreach-draft/SKILL.md
    └── outreach-trajectory/SKILL.md
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
- [`event-correlation`](generic/event-correlation/SKILL.md) — link new events to contacts
- [`memory-search`](generic/memory-search/SKILL.md) — grep across `memory/`

Telegram (require [tdl](https://github.com/iyear/tdl)):
- [`telegram-scan`](generic/telegram-scan/SKILL.md) — periodic scan of all chats for signals
- [`telegram-export`](generic/telegram-export/SKILL.md) — deep export of one channel/chat to `resources/`
- [`telegram-channel-analytics`](generic/telegram-channel-analytics/SKILL.md) — top posts / themes / trends

Health & energy (personal-use scheduled checks):
- [`energy-checkin`](generic/energy-checkin/SKILL.md) — 3 daily energy pings via Telegram
- [`whoop-morning-check`](generic/whoop-morning-check/SKILL.md) — WHOOP recovery → `memory/health.md` + alert
- [`timing-rebuild`](generic/timing-rebuild/SKILL.md) — rebuild yesterday's Timing.app entries

Research:
- [`youtube-analysis`](generic/youtube-analysis/SKILL.md) — transcript → insights → `resources/youtube/`

System self-healing & improvement:
- [`self-heal-diagnose`](generic/self-heal-diagnose/SKILL.md) — L2: classify worker crash from logs
- [`self-heal-autofix`](generic/self-heal-autofix/SKILL.md) — L3: 8 runbooks (RB-001..RB-008)
- [`self-improvement-loop`](generic/self-improvement-loop/SKILL.md) — Scan→Evaluate→Spike→Integrate→Measure
- [`self-upgrade-scan`](generic/self-upgrade-scan/SKILL.md) — daily search for stack upgrades

Strategist patterns (run at top of each strategist cycle):
- [`strategist-health-watchdog`](generic/strategist-health-watchdog/SKILL.md) — L1 detect anomalies
- [`strategist-signal-analysis`](generic/strategist-signal-analysis/SKILL.md) — score → group → opportunities
- [`strategist-business-analysis`](generic/strategist-business-analysis/SKILL.md) — 5-lens framework
- [`strategist-blocker-resolution`](generic/strategist-blocker-resolution/SKILL.md) — unblock-attempt → user-request → aging
- [`strategist-self-improvement`](generic/strategist-self-improvement/SKILL.md) — pattern confidence + meta-review
- [`strategist-worker-results-analysis`](generic/strategist-worker-results-analysis/SKILL.md) — Reflexion over `result.md`

### `novo-specific/` — demonstration only

Bound to Novo Studio's mobile-services sales motion (a specific Google Sheet, OUTREACH_PROCESS.md, Funnel sheet, mobile SaaS prospecting). Useful as concrete examples of what a real lead-discovery + outreach pipeline looks like — copy and adapt heavily, don't drop in as-is:

- [`mobile-prospect-discovery`](novo-specific/mobile-prospect-discovery/SKILL.md) — find new SaaS companies (12-source rotation)
- [`mobile-prospect-scan`](novo-specific/mobile-prospect-scan/SKILL.md) — research existing prospects (App Store, hiring, funding, SDK compliance)
- [`auto-outreach-draft`](novo-specific/auto-outreach-draft/SKILL.md) — generate cold-outreach draft when Signal Score >= 4
- [`outreach-trajectory`](novo-specific/outreach-trajectory/SKILL.md) — full 6-8 touch sequence + Funnel rows + reminders

Each Novo-specific SKILL.md begins with a "DEMONSTRATION ONLY" note explaining what you'd need to change for your domain.

## How to enable a skill

1. Pick a skill from `examples/skills/{generic,novo-specific}/<name>/SKILL.md`
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
- `context: fork` + `agent: Explore` — read-only research skills: `memory-search`, `contact-enrichment`, `event-correlation`, `reply-watchdog`, `telegram-channel-analytics`, `self-heal-diagnose`
- `disable-model-invocation: true` — skills that mutate shared state (Google Sheets, CRM, launchd services): `clickup-sync`, `self-heal-autofix`, `auto-outreach-draft`, `outreach-trajectory`
- `paths:` — only for `memory-search` and `reply-watchdog` (file-scoped)
- Other skills use plain `description` + `allowed-tools` whitelist
- Dynamic context injection (`!`<cmd>`` blocks) used in `strategist-health-watchdog` and `self-heal-diagnose` for live launchd status

## Caveats

- **Russian content.** All skill bodies are in Russian — the original AgentOS instance was Russian-speaking. Translate as needed.
- **MCP server dependencies.** Many skills assume specific MCP servers are running:
  - `claude-peers` (HTTP broker on `:7899`) — for cross-agent messaging to a Telegram operator
  - `saga-mcp` (`:3851`) — task tracker, see [@novostudiotech/saga-mcp](https://github.com/novostudiotech/saga-mcp)
  - `telegram-mcp` (`:3848`) — Bot API wrapper for outbound messages
  - Optional: `claude_ai_Gmail`, `claude_ai_Google_Calendar`, `claude_ai_Fireflies`, `claude_ai_ClickUP` (Composio/Rube-style integrations)
  - WHOOP MCP (custom, see whoop-morning-check) — only relevant if you have a WHOOP
- **CLI tool dependencies.** `tdl` (Telegram MTProto client) for telegram-* skills; `yt-dlp` + `youtube-transcript-api` for youtube-analysis; Timing.app + scripts for timing-rebuild; `gh` CLI optional for morning-brief.
- **Hardcoded paths.** Original skills referenced absolute paths like `$HOME/Workspaces/novostudio/claude/agents/heartbeat/`. These were replaced with `${CLAUDE_PROJECT_DIR}/...` (Claude Code expands this at runtime). Auxiliary scripts (`slim-tdl-export.py`, `youtube-analyze.py`, timing rebuild scripts) are referenced by path but not included in the template — they live in the original repo.
- **Sheet IDs / list IDs.** Novo-specific skills reference a hardcoded Google Sheet ID and ClickUp list IDs; replace with your own or move to `memory/<service>-config.md`.
- **Workflow assumption.** These skills assume an AgentOS-style heartbeat dispatcher creates tasks in saga-mcp, picks them up, and routes to workers. They run fine standalone via `Skill` tool invocation as well.

## Frontmatter validation

All 31 SKILL.md files have YAML frontmatter that:
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
