---
name: event-correlation
description: Links an event from any connector (gmail, calendar, telegram, task tracker, transcripts) to a contact in memory/contacts/ and writes it into the contact's Timeline. Called after every scan.
type: procedure
read_when: After every connector scan (gmail, telegram, calendar, etc.); when a new event mentions a known contact; "log {name} timeline that {event}".
---

# Event Correlation — AgentOS Procedure

## When to call

- After every scan: gmail-triage, telegram-scan, calendar check, task-tracker sync, meeting transcripts
- When a new event mentions a known contact
- Manually: "log in {name}'s timeline that {event}"

## Steps

### 1. Identify the contact

For each event (email, meeting, task, message, transcript) determine which contact it relates to.

Use the `## Matching` section in the contact file:

| Match field | How to check |
|-------------|--------------|
| `emails:` | sender/recipient domain or address |
| `telegram:` | @username of the message author |
| `keywords:` | name, company, product in subject/body |
| `linkedin:` | URL in the message |

Contact registry: `../memory/contacts/` (all files).

### 2. Find the contact file

Path: `../memory/contacts/{slug}.md`

Slug = first-last name, lowercase, hyphenated. Examples:
- John Smith → `john-smith.md`
- Anna Petrova → `anna-petrova.md`

**If the file does not exist** and the contact matters (client, lead, partner, network) — create a new file from the template (see below), then call the `contact-enrichment` skill.

**Do NOT create** files for: spammers, internal team contacts, automated systems (GitHub bot, task-tracker bot, transcript notifications).

### 3. Check for duplicates

Before writing — review the contact's `## Timeline` section.

Do not write if there's already an entry with the same date and source.

Check: is there an entry `### {YYYY-MM-DD} ... [{source}]`?

### 4. Write to the Timeline

Add an entry to the `## Timeline` section (newest entries on top, in reverse-chronological order):

```
### YYYY-MM-DD HH:MM [source]
One-sentence description of the event.
```

Sources:
- `email` — Gmail message
- `telegram` — Telegram message
- `calendar` — Google Calendar event
- `tracker` — task or change in your task tracker
- `docusign` — document signed
- `transcript` — meeting transcript
- `linkedin` — LinkedIn activity
- `scan` — discovered during scanning (no direct event)

Example entries:

```
### 2026-04-02 14:30 [email]
Wrote about project status, asking for a deadline update.

### 2026-04-01 10:00 [calendar]
Discovery Call — 45 min. Discussed MVP requirements.

### 2026-03-28 16:20 [telegram]
Mentioned looking at AgentOS for their team (in a community chat).
```

### 5. Update status (if needed)

If the event changes the contact's status — update the `## Status` section:

```markdown
## Status
- **Pipeline:** COLD | OUTREACH | DISCOVERY | PROPOSAL | DEAL | PARTNER | INACTIVE
- **Next step:** {what needs to happen}
- **Last update:** YYYY-MM-DD
```

Status update triggers:
- Reply received to outreach → OUTREACH → DISCOVERY
- Discovery call held → DISCOVERY → PROPOSAL
- Contract signed → DEAL
- Long silence → INACTIVE

### 6. Update people.md (optional)

If the event is significant (new deal, status change, key agreement) — add a brief entry to `../memory/people.md` for the corresponding contact.

## New contact template

```markdown
# {First Last} ({Company})

## Contact
- **Full name:**
- **Company:**
- **Role:**
- **Telegram:**
- **Email:**
- **LinkedIn:**
- **Source:** how we found them

## Status
- **Pipeline:** COLD
- **Next step:**
- **Last update:** YYYY-MM-DD

## Matching
- emails: domain.com, name@domain.com
- telegram: @username
- keywords: Company, Name, Product

## Connections
- **Shared chats:**
- **Shared meetings:**
- **Introduced by:**
- **Knows:**

## Timeline

### YYYY-MM-DD HH:MM [source]
First detection / mention.
```

## Result

- `../memory/contacts/{slug}.md` — Timeline and Status updated
- `../memory/people.md` — updated (if there was a significant event)
- If a new contact was created — `contact-enrichment` skill is launched (in background)

## Rules

- Contact files are the source of truth for interaction history
- `memory/people.md` stays as an index (links + brief status); the timeline lives in the contact file
- When asked "what's up with {name}?" — read the contact file, return status + recent timeline entries
- Do NOT create files for: spammers, internal team, autobots
- After updates: git commit + push (together with other cycle changes)
