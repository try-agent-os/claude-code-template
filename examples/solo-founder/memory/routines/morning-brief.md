# Routine: Morning Brief

Fired by heartbeat dispatcher at the time configured in `memory/owner.md` (default 09:00 local). One Telegram message, founder reads it before deep work.

## Structure

```
доброе утро, {{name}}.

📥 Inbox overnight ({{count}} unread):
• {{2-4 line summary, only the worth-attention ones — investor / customer / urgent}}

📅 Today:
• {{HH:MM}} — {{event}} ({{who}})
• {{HH:MM}} — {{event}} ({{who}})

✅ Pending from yesterday:
• {{saga task title}} — was due {{date}}
• {{follow-up commitment from a thread}}

🎯 Top 3 for today:
1. {{from saga or owner.md priorities}}
2. {{...}}
3. {{...}}

{{optional: один маленький alert если что-то срочное — "investor X пишет с 7 утра, может важно"}}
```

## Rules

- **Maximum 12 lines.** If there's more, pick the most important. Founder can always ask "что ещё в inbox" later.
- **No filler.** No "have a productive day!" — they'll mute you.
- **Deep-work-aware.** If the founder's first deep-work block starts at 10:00 and brief fires at 09:00, the brief should be readable in <2 minutes. They don't have time for paragraphs.
- **Skip empty sections.** If inbox is clear, omit it entirely. Don't send "📥 Inbox overnight: nothing."
- **Numbers, not adjectives.** "3 unread" beats "a few unread." "$120k MRR" beats "growing well."

## When NOT to send

- Founder already messaged you between 06:00 and the brief time → skip, they're already in the loop.
- It's a weekend AND `working_hours.weekends: ad-hoc` (default) → skip.
- It's a holiday they've marked → skip.

## Edge cases

- **Inbox integration disabled** (Gmail MCP not configured) — omit the inbox section. Don't mention "you don't have inbox set up" — just skip.
- **No calendar integration** — skip Today section.
- **No active saga tasks** — skip the Pending section.

The brief degrades gracefully — even with zero integrations, at minimum it pings: "доброе утро. сегодня top 3 из приоритетов: ..." pulling from owner.md.
