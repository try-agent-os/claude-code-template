# Example: Solo Founder Assistant

A pre-built AgentOS persona for a solo founder running a small startup or independent practice. The operator listens to your Telegram, reads your inbox via Gmail / Calendar integrations, drafts replies, tracks priorities in saga-mcp, and pings you proactively about things that need attention before they fall through.

## Who this is for

- You're running a 1-3 person operation. There's no PM, no inbox triager, no "let me hand this off."
- Your day is fragmented across investor updates, customer support, hiring DMs, contract drafts, and your actual product work.
- You need an assistant that holds context across days — not "summarise this thread," but "remember why I told this lead I'd circle back next week, and remind me at the right time."

## What it does out of the box

- **Daily morning brief** at the time you specify: yesterday's pending replies, today's calls, anything that touched the inbox overnight worth your attention before deep work.
- **Inbox triage** when you forward an email or paste a thread: classify (investor / customer / sales / noise), draft a reply if appropriate, file the follow-up in saga-mcp.
- **Calendar context-awareness**: knows what meeting is next, what's been moved, what tomorrow looks like.
- **Priority tracking**: every "I should do X this week" becomes a saga task with the right tag. Heartbeat dispatcher surfaces overdue items in the next morning brief.
- **Voice memos**: forward an audio message, get a transcribed action-list back. Whisper.cpp runs on the droplet.
- **Proactive nudges**: "ты вчера сказал что свяжешься с {investor} в среду — сегодня среда, хочешь чтобы я подготовил draft?"

## What's in this directory

```
examples/solo-founder/
├── README.md
├── operator-CLAUDE.md              # drop-in agents/operator/CLAUDE.md
├── memory/
│   ├── owner.md                    # founder profile (filled on first run)
│   ├── projects/                   # one folder per active project / company
│   ├── people/                     # contact memory (investors, customers, hires)
│   └── routines/
│       ├── morning-brief.md        # SOP for the daily 09:00 brief
│       └── weekly-review.md        # Friday 17:00 wrap-up
└── saga-seed.json                  # onboarding tasks
```

## How to use it

Same as the [restaurant-consultant](../restaurant-consultant/) example — copy the files into your agent dirs and restart the operator service. See that README for the exact commands.

## What you'll need to add

This persona is most useful with Gmail + Google Calendar integrations. Out of the box AgentOS doesn't ship these MCP servers — you'll want to:
1. Create a Google Cloud project with Gmail + Calendar APIs enabled
2. Generate OAuth credentials and add them to `/etc/agent-os/agent-os.env`
3. Install a Gmail / Calendar MCP plugin (e.g. <https://github.com/oleander/google-mcp> or build one with the agent-sdk-dev plugin)
4. Add to the operator's `mcpServers` config

The operator-CLAUDE.md in this directory references these tools assuming they're available — if they aren't, the operator will gracefully degrade to "I can't read your inbox unless you forward, but I can do everything else."

## Honest limitations

- Without Gmail integration, "inbox triage" requires manual paste. With it, fully automated.
- Calendar reasoning depends on the integration quality — most public Google Calendar MCPs handle reads well, writes (creating events) are flakier.
- This is a starter — your routines are different from the next founder's. Tune the morning-brief and weekly-review SOPs to match.
