# Client: {{client_name}}

Slug: `{{slug}}` (URL-safe, used in saga-mcp epic name and folder path)

## Basics

- **Address**: {{full address}}
- **Owner contact**: {{name, phone, email, Telegram username}}
- **Type**: {{cafe / casual dining / fine dining / pizzeria / bar / etc.}}
- **Cuisine**: {{specifics}}
- **Capacity**: {{seats}}
- **Hours**: {{Mon-Sun timetable}}
- **Engagement start**: {{YYYY-MM-DD}}
- **Engagement scope**: {{e.g. "menu engineering + 90-day marketing plan"}}
- **Monitoring**: enabled / disabled (controls scheduled review scans, competitor sweeps)

## Brand voice

(How the owner / venue communicates. Update with samples as you learn.)

- **Tone**: {{warm / formal / playful / confident / etc.}}
- **Pet phrases**: {{recurring expressions}}
- **Avoid**: {{things they explicitly don't say or sound like}}
- **Sample of their writing**:
  > {{paste 1-3 sentences of their actual voice}}

## Operations context

- **Kitchen**: {{head chef, prep style, signature constraints}}
- **Service**: {{table service / counter / hybrid}}
- **POS / tools**: {{Square / Toast / iiko / etc.}}
- **Suppliers**: {{key relationships, terms}}
- **Pain points**: {{what they're paying you to fix}}
- **Wins worth keeping**: {{what already works, don't break}}

## Engagement history

(Chronological log — newest at top. Operator appends after each interaction.)

### {{YYYY-MM-DD HH:MM}}
{{What happened, what was decided, action items, links to saga tasks}}

---

## Active saga epic

Epic name: `client-{{slug}}` (operator creates this on first interaction)

Recent tasks:
- {{operator queries `mcp__saga-mcp__task_list epic={{epic_id}}` and shows top 5 in-progress / due-soon}}
