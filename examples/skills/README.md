# Example Skills — Reference Patterns

These are **reference skills** taken from a real AgentOS deployment (Novo Studio). Most are tightly bound to that deployment's specific business workflows, connectors, data sources, and conventions.

## How to use these

- **Read for ideas**, not as drop-in components.
- **Copy-paste-adapt** is the intended usage: pick a skill that resembles something you want, copy it into your own `agents/<name>/skills/`, then rewrite the company-specific bits (named contacts, custom tables, business jargon, MCP tool calls) for your context.
- The Russian prose is preserved as part of the authenticity of the reference — you can read past it or translate per-skill as you adapt.
- For the **generic** skills shipped with the template (memory-search, event-correlation, self-heal-*, signal-analysis, etc.), see [`agents/heartbeat/skills/`](../../agents/heartbeat/skills/).

## Index

### Daily / scheduled

| Skill | One-line description |
|-------|----------------------|
| [morning-brief.md](morning-brief.md) | Morning briefing — meetings, tasks, PR status, pending replies, hot topics; sent to user via operator. |
| [energy-checkin.md](energy-checkin.md) | Periodic Telegram pings about energy/mood; aimed at catching ADHD-burnout cycles early and adapting the day's plan. |
| [whoop-morning-check.md](whoop-morning-check.md) | Pulls WHOOP recovery/HRV/RHR/sleep data; updates `memory/health.md`; alerts operator on low recovery. |
| [timing-rebuild.md](timing-rebuild.md) | Daily rebuild of yesterday's time entries from raw app usage in Timing SQLite + rules in `memory/timing-rules.yaml`; sends preview to Telegram. |
| [reply-watchdog.md](reply-watchdog.md) | Scans contact files for messages awaiting reply >24h; prevents ADHD task-switch losses in networking. |

### Communication connectors

| Skill | One-line description |
|-------|----------------------|
| [gmail-triage.md](gmail-triage.md) | Triages last-2h unread mail and SENT, classifies (client/lead/spam/newsletter), updates `contacts/*.md`. |
| [telegram-scan.md](telegram-scan.md) | Exports all Telegram chats via tdl --raw, converts to markdown, updates contacts via Event Correlation. |
| [telegram-export.md](telegram-export.md) | Exports a specific Telegram channel/chat/group through tdl into `resources/{slug}/posts/` plus `index.md`. |
| [telegram-channel-analytics.md](telegram-channel-analytics.md) | Analyzes an exported Telegram channel and produces a structured `analytics.md` (top posts, topic categories, posting cadence, trends). |
| [outbound-tracker.md](outbound-tracker.md) | Tracks the user's outgoing actions (Gmail SENT, Telegram OUT), correlates with `contacts/*.md`, updates timeline. Fixes "the system doesn't know what was already sent". |

### Sales / outreach pipeline

| Skill | One-line description |
|-------|----------------------|
| [mobile-prospect-discovery.md](mobile-prospect-discovery.md) | Active discovery of new mobile-app SaaS companies for a Mobile Prospects sheet; rotates 12 sources (App Store, G2, Crunchbase, LinkedIn Jobs, etc.). |
| [mobile-prospect-scan.md](mobile-prospect-scan.md) | Continuous research on companies in Mobile Prospects: App Store ratings, hiring, funding, SDK compliance, complaints; updates Signal Score. |
| [auto-outreach-draft.md](auto-outreach-draft.md) | Generates an outreach draft for a Mobile Prospects company at Signal Score >= 4; picks channel and offer, persists draft to Google Sheets. |
| [outreach-trajectory.md](outreach-trajectory.md) | Builds a 6-8 touch sequence for an OPP lead; rewrites drafts to v2 standard, creates Funnel rows, schedules tracker reminders. |
| [contact-enrichment.md](contact-enrichment.md) | On a new or incomplete contact, gathers data from all connectors (Telegram, LinkedIn, Gmail, ClickUp, Fireflies, Calendar, Web). |
| [clickup-sync.md](clickup-sync.md) | Syncs ClickUp Pipeline and Contacts into `memory/people.md`; detects deal-stage changes, verifies critical events via Gmail. |

### Meetings

| Skill | One-line description |
|-------|----------------------|
| [meeting-prep.md](meeting-prep.md) | Briefing 30 min before a meeting from Fireflies, ClickUp, Gmail, Calendar, and `people.md`; sent to Telegram. |
| [meeting-debrief.md](meeting-debrief.md) | 2h after a meeting: Fireflies transcript → debrief → ClickUp tasks → contact timeline. |
| [calendar-management.md](calendar-management.md) | Rules for working with Google Calendar (color system, event language, recurring blocks, conflict checks, work/non-work intervals); applied on any event create/update via the Calendar MCP. |

### Content / research

| Skill | One-line description |
|-------|----------------------|
| [youtube-analysis.md](youtube-analysis.md) | Analyzes a YouTube video — extracts transcript, generates insights via Claude, stores result under `resources/youtube/`. |

---

## A note on style

These skills mix Russian prose with English technical nouns. That mirrors how the source operator actually thinks and writes. When adapting, you can:
- Rewrite Russian → your language as you adapt.
- Keep technical names (saga-mcp, claude-peers, dispatcher, worker, heartbeat, strategist) unchanged — the rest of the template uses them too.

## Where to start adapting

If you want to build your own version of these:

1. Pick one workflow that maps to your business (e.g. `gmail-triage` if you live in email).
2. Copy the skill file into `agents/<your-agent>/skills/<skill>.md`.
3. Strip references to specific companies, sheets, MCP servers you don't have.
4. Replace data-source steps with your own connectors.
5. Test in isolation, then wire it into your dispatcher's `read_when` matching.
