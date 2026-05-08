# Example: Restaurant Operations Consultant

A pre-built AgentOS persona for someone consulting independent restaurants on operations, marketing, and growth. The operator listens to the consultant's Telegram, helps draft client communications, tracks engagements in saga-mcp, runs scheduled checks (review-site monitoring, competitor pricing), and persists context across long-running engagements.

## Who this is for

You're a one-person consulting practice working with 3-15 small / mid restaurants. Your day is fragmented — site visits, client calls, draft proposals between commutes, last-minute "can you look at our menu prices vs the new place down the road?" requests. You need an assistant that actually remembers your clients and runs in the background.

## What it does out of the box

- **Client engagement tracker** — every conversation creates / updates a saga-mcp epic for that client. Decisions, action items, deliverables persist between sessions.
- **Daily / weekly briefs** — heartbeat dispatcher fires every 45 min. By 09:00 local you have: yesterday's pending replies, this-week's deliverables, anything that needs your attention before client calls.
- **Review monitoring** — scheduled scans of Google Reviews, Yelp, TripAdvisor for each client. Flags new negative reviews within an hour.
- **Pricing / menu intel** — on demand, runs a competitor sweep for a given location radius and produces a formatted summary you can forward to the client.
- **Draft communication** — paste in a client's voice memo or a long thread, ask for a "professional but warm" reply, get a draft back you can edit and send.
- **Memory that doesn't reset** — your clients' brand voice, ops quirks, prior advice, what worked, what didn't. All persisted in `memory/clients/<slug>/`.

## What's in this directory

```
examples/restaurant-consultant/
├── README.md                       (this file)
├── operator-CLAUDE.md              # drop-in replacement for agents/operator/CLAUDE.md
├── memory/
│   ├── owner.md                    # consultant profile (you fill this in on first run)
│   ├── clients/
│   │   └── _template.md            # per-client memory template
│   └── playbooks/
│       ├── review-response.md      # how to respond to negative reviews
│       ├── menu-engineering.md     # pricing/positioning analysis SOP
│       └── slow-period-marketing.md
├── saga-seed.json                  # initial epics/tasks to load on first boot
└── skills/
    ├── competitor-sweep.md         # query Google/Yelp/Apple Maps for given lat/lng radius
    ├── review-monitor.md           # scheduled scan + alert
    └── client-brief.md             # generate weekly summary for a client
```

## How to use it

After running the standard install (`bash install.sh` or the cloud-init deploy button), apply this persona:

```bash
# On the droplet, as root:
cp /opt/agent-os/claude/examples/restaurant-consultant/operator-CLAUDE.md \
   /opt/agent-os/claude/agents/operator/CLAUDE.md
cp -r /opt/agent-os/claude/examples/restaurant-consultant/memory/* \
   /opt/agent-os/claude/memory/
cp -r /opt/agent-os/claude/examples/restaurant-consultant/skills \
   /opt/agent-os/claude/agents/operator/.claude/skills

# Seed saga tasks (optional — run from operator session via mcp tools):
sudo -u agent-os jq -c '.[]' /opt/agent-os/claude/examples/restaurant-consultant/saga-seed.json | \
  while read task; do
    # Send to saga-mcp via curl SSE — easier to do from the operator session via mcp__saga-mcp__task_create
    echo "Seed task: $task"
  done

systemctl restart agent-os-operator.service
```

Then on Telegram, send your bot:

> Привет. Меня зовут [your name], я консультирую рестораны. Давай настроим систему — расскажи что ты можешь и спроси у меня про моих клиентов.

The operator will walk you through the first-run onboarding and start populating `memory/owner.md` and `memory/clients/`.

## Customisation

- **Add a client** — chat-driven. "Добавь клиента: Кафе Перейя, ул. Артилейру 12, владелец Жуан Мендес." Operator creates `memory/clients/perreira/` + a saga epic.
- **Schedule a recurring scan** — saga-mcp task with `schedule: "weekly"` tag. Heartbeat dispatcher picks it up.
- **Change the voice** — edit `operator-CLAUDE.md`. Keep the principle bullets, swap the tone instructions to match your actual writing style.

## Honest limitations

- The competitor-sweep skill uses public Google / Yelp data with rate limits — for high-frequency monitoring, plug in a paid API.
- Memory files are markdown; very large client portfolios (>30 clients with detailed history) might want to migrate to a structured store later.
- This is a starter — adjust to your actual practice. Don't try to use it without editing.
