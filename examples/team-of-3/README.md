# Example: Team of 3

A pre-built AgentOS persona for a small team (founder + 2 operators / co-founders / partners). The operator is shared — multiple Telegram users message it, it disambiguates, routes work, and keeps each person's context separate without losing the team-level shared state.

## Who this is for

- **Three humans**, Telegram-natives, want a shared agent that doesn't get confused about who's asking.
- Use cases: small consulting practice (founder + 2 senior consultants), early-stage startup (CEO + CTO + ops lead), creative team (director + 2 producers).
- You want one Telegram bot, three Telegram accounts authorised, and the operator to know who's who.

## What it does out of the box

- **Per-user memory** alongside team memory — operator distinguishes between Vasily's pending tasks and Yulia's pending tasks, but they share the same project epics.
- **Mention-aware routing** — "@yulia could you reply to {customer}" creates a saga task assigned to Yulia, pings her, and tracks acknowledgement.
- **Shared morning brief** at the configured hour — same digest across the team, but per-user "your pending" sections.
- **Decision log** — anything tagged "решение / decision" goes to `memory/team/decisions.md` with date + author + rationale, so future-team has the receipts.
- **Conflict-free**: if two people message about the same thing, operator notices and surfaces the duplication ("Vasily спросил то же 2 часа назад").

## What's in this directory

```
examples/team-of-3/
├── README.md
├── operator-CLAUDE.md              # drop-in agents/operator/CLAUDE.md — multi-human aware
├── memory/
│   ├── team/
│   │   ├── members.md              # authoritative member list with roles
│   │   ├── decisions.md            # team-level decision log
│   │   └── shared-priorities.md    # week / month priorities (everyone reads + writes)
│   ├── members/
│   │   ├── _template.md            # per-member profile template
│   │   └── (vasily.md, yulia.md, ... created on first run)
│   └── routines/
│       ├── shared-morning-brief.md
│       └── decision-capture.md
└── saga-seed.json                  # 6-step team-onboarding epic
```

## How to use it

1. Copy operator-CLAUDE.md + memory/* to the install (same pattern as the other examples).
2. **Get every team member to `/start` the bot.** Wizard captures their `user_id` and seeds them as `status='allowed'` in telegram-mcp's users table. Operator then prompts each one for their profile (name, role, working hours, expertise) and saves to `memory/members/<slug>.md`.
3. Restart operator. From then on, every incoming message has a `user_id` — operator looks up `members/<slug>.md`, knows who they are, scopes responses appropriately.

## Things this example does well

- **Disambiguation** — when Vasily says "сделай X for {project}" and Yulia is on the same project, operator knows whose initiative this is.
- **Decision capture** — never again "wait, did we decide to ship X or not?" Operator catches the moment and persists.
- **Polite asymmetry** — different members can have different working hours / quiet hours; operator respects each.

## Things it doesn't solve (yet)

- Team-level analytics (who's working on what, hours / week per project) — needs an extra layer.
- Conflict resolution between members ("Vasily сказал ship, Yulia сказала wait") — operator surfaces the conflict, doesn't decide.
- Authentication / RBAC beyond Telegram chat-id allowlist. If you want fine-grained "Yulia can't approve > $X" rules, that's separate.
