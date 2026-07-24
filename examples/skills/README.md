# Example skills

Reference patterns pulled from a live AgentOS instance — not enabled by
default, and not meant to run as-is. Copy the ones that fit into `skills/`
and adapt them to your own connectors before using.

| Skill | What it does |
|---|---|
| [`clickup-sync`](clickup-sync/SKILL.md) | Syncs ClickUp pipeline and contacts into `memory/people.md`, detecting deal-status changes and verifying critical events via Gmail. Runs every 2h or on demand. |
| [`contact-enrichment`](contact-enrichment/SKILL.md) | On a new or incomplete contact, pulls data from every connector available (Telegram, LinkedIn, Gmail, CRM, Fireflies, Calendar, web search). Runs on contact creation or on demand. |
| [`gmail-triage`](gmail-triage/SKILL.md) | Reads unread and sent mail from the last 2h, classifies it (client / lead / spam / newsletter), updates `contacts/*.md`. Runs every 2h or on demand. |
| [`meeting-debrief`](meeting-debrief/SKILL.md) | Turns a just-finished external meeting into a debrief: Fireflies transcript to summary to CRM follow-ups to contact timeline. Runs automatically ~2h after a meeting ends. |
| [`meeting-prep`](meeting-prep/SKILL.md) | Builds a pre-meeting briefing from Fireflies, CRM, Gmail, Calendar, and `memory/people.md`, sent ahead of the meeting start. |
| [`morning-brief`](morning-brief/SKILL.md) | Daily morning summary: meetings, open tasks, PR status, replies owed, and the current hot topics. |
| [`outbound-tracker`](outbound-tracker/SKILL.md) | Tracks the owner's own outgoing actions (sent email, outbound Telegram messages) and matches them against contacts so the system knows what's already been sent, not just what came in. |
| [`reply-watchdog`](reply-watchdog/SKILL.md) | Scans `memory/contacts/*.md` for anyone who has been waiting more than 24h for a reply. |
| [`telegram-channel-analytics`](telegram-channel-analytics/SKILL.md) | Analyzes an exported Telegram channel and produces a structured report — top posts, topic categories, posting frequency, trends. |
| [`telegram-export`](telegram-export/SKILL.md) | Exports one Telegram channel, chat, or group via `tdl` into a structured per-post archive. |
| [`telegram-scan`](telegram-scan/SKILL.md) | Exports all Telegram chats via `tdl --raw`, converts them to markdown, and refreshes contacts from what it finds. Runs every 12h or on demand. |
| [`youtube-analysis`](youtube-analysis/SKILL.md) | Extracts a YouTube video's transcript and generates insights from it, saved under `resources/youtube/`. |

## Caveats

- **Bodies are in Russian.** These were ported from a Russian-speaking
  instance and haven't been translated. Translate the procedure as you adapt
  it into `skills/` — frontmatter (`name`, `description`) is the only part
  that needs to stay machine-readable, but leaving the body untranslated
  will confuse both you and the agent.
- **Most assume specific connectors.** Gmail, Calendar, and Fireflies-style
  MCP servers for the CRM/meeting skills; the `tdl` CLI for the Telegram
  ones. Without the matching connector configured, treat these as patterns
  to follow, not skills you can drop in and run.
