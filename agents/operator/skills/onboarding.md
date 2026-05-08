---
name: onboarding
description: First-run onboarding flow for new AgentOS installation. Trigger when memory/owner.md does not exist OR onboarding_state.completed_at IS NULL for this user. Do NOT trigger if owner.md exists and onboarding is marked done.
---

# Operator Onboarding Skill

This skill runs automatically on first boot after installing AgentOS via the template install.sh.

**Goal:** meet the owner, gather minimal context for productive work, demonstrate baseline value, offer a choice of setup direction.

---

## Triggering

On every boot, the operator checks:

```
1. Does memory/owner.md exist?
   - NO → first_run = true → invoke onboarding skill
   - YES → check onboarding_state in SQLite (see schema below)

2. SELECT * FROM onboarding_state WHERE user_id = {admin_chat_id} AND completed_at IS NULL
   - Row exists (NULL completed_at) → onboarding not finished → resume from current phase
   - No row → INSERT, phase = "welcome" → start flow
   - completed_at IS NOT NULL → onboarding complete → skip
```

**Multi-admin:** onboard each admin separately by their chat_id. Each gets their own row in onboarding_state.

**Important:** on a fresh AgentOS install the operator must initiate the dialog in Telegram — don't wait for the user's first message. Start onboarding automatically on boot.

---

## Phase 1 — Welcome + minimal value

Send immediately upon detecting first_run. No delay.

```
Hi! I'm your AgentOS operator.

Here's what I can do right now:
• Sort your inbox — forward me any email
• Set reminders — "remind me at 5pm to call X"
• Search your files and documents
• Transcribe voice messages

Let's get acquainted quickly — takes 2-3 minutes. Then we get to work.

What's your name / what should I call you?
```

Update onboarding_state: phase = "survey", survey_step = 1.

---

## Phase 2 — Survey (4 questions, one at a time)

**Rule:** ask one question at a time. Don't dump the whole form at once. After each answer — save to onboarding_state.survey_answers (JSON), move to next question.

### Question 1 (after receiving the name):
```
Nice to meet you, {name}!

What do you do? Brief answer — profession, roles, projects.
```

### Question 2 (after occupation answer):
```
Got it. What are your 2-3 main goals for the next month?
```

### Question 3 (after goals):
```
Great. Which projects are currently active — what are you working on right now?
```

### After the 3rd answer:
Save data to `memory/owner.md` (create file from template). Move to Phase 3.

**SQLite survey_answers format:**
```json
{
  "name": "...",
  "occupation": "...",
  "goals": ["...", "..."],
  "active_projects": ["...", "..."]
}
```

---

## Phase 3 — Direction menu

After saving survey data, send the menu. NOT a linear scenario — the user picks their priority.

```
{name}, profile saved. Choose what to set up first:

1. Productivity
   Singularity + Calendar + Gmail + morning briefing

2. Email
   Gmail OAuth → inbox sorting, auto-classification, draft replies

3. Calendar & reminders
   Google Calendar + Singularity + morning/evening rituals

4. Docs & notes
   Google Drive, Docs, knowledge search

5. Work chats
   Telegram parsing + Slack/Linear if applicable

6. Jump straight to work
   Skip setup — let's solve a specific task right now

Reply with a number or the name.
```

**Handling response:**
- 1 / "productivity" → invoke productivity setup flow (future skill: productivity-setup)
- 2 / "email" → invoke gmail setup flow (future skill: gmail-setup)
- 3 / "calendar" → invoke calendar setup (skill: calendar-management, extend for setup)
- 4 / "docs" → invoke docs setup flow (future skill: docs-setup)
- 5 / "chats" → invoke chats setup flow (future skill: chats-setup)
- 6 / "work" / "skip" → skip to Phase 4 lifehacks, mark onboarding done

Update onboarding_state: phase = "menu", completed_flows = [] (empty array).

**After selection:** launch the corresponding setup flow (or say "we'll set that up a bit later — I'll create a task and remind you" if the flow isn't implemented yet), then move to Phase 4.

---

## Phase 4 — Quick lifehacks

After the selected setup completes (or is skipped) — send the lifehacks list.

```
A few things worth knowing:

• Forward me any email or task — I'll break it down and suggest what to do
• "Remind me at 5pm to X" — I'll put it in Singularity
• Voice messages are fine — I'll transcribe and process them
• Emoji reaction on my message = confirmation without text
• Just write what you need — I'll figure it out

Ready to work. What are we doing?
```

Update onboarding_state: phase = "done", completed_at = NOW().

---

## Wrap-up

After Phase 4:
1. Confirm `memory/owner.md` was written correctly
2. `UPDATE onboarding_state SET completed_at = CURRENT_TIMESTAMP WHERE user_id = {chat_id}`
3. Never show the onboarding flow to this user again

---

## Handling interruptions

If the user asks a question or gives a task mid-onboarding:
1. Answer / complete the task
2. After completing — gently return: "Shall we continue? Just one question left."
3. If the user ignores the return twice → set phase = "skipped", finish

---

## Onboarding commands

Handle at any point in the conversation:

| Command | Action |
|---------|--------|
| `/skip onboarding` | Skip onboarding. UPDATE onboarding_state SET current_phase = 'skipped', completed_at = CURRENT_TIMESTAMP. Reply: "Got it, skipping. If you want to come back — type /profile edit". |
| `/profile` or `/profile view` | Show current profile from memory/owner.md. |
| `/profile edit` | Start profile editing: ask the same 4 survey questions and rewrite memory/owner.md. Can be triggered any time, onboarding_state is not checked. |
| `/profile reset` | Clear memory/owner.md and onboarding_state → next boot will start onboarding fresh. |

---

## Setup flows (future skills)

These flows are marked as future dependencies. On first run if a flow isn't implemented — say:
"[Name] setup we'll do a bit later — I'll create a task and remind you."

| Flow | Trigger | Status |
|------|---------|--------|
| productivity-setup | choice 1 | planned |
| gmail-setup | choice 2 | planned |
| calendar-management | choice 3 | partial (skill exists) |
| docs-setup | choice 4 | planned |
| chats-setup | choice 5 | planned |

---

## SQLite schema

Use the operator's DB (typically `agents/operator/operator.db`).
Full schema: [`agents/operator/docs/onboarding-schema.sql`](../../docs/onboarding-schema.sql)

```sql
CREATE TABLE IF NOT EXISTS onboarding_state (
  user_id INTEGER PRIMARY KEY,
  current_phase TEXT NOT NULL DEFAULT 'welcome',
  survey_step INTEGER DEFAULT 1,
  survey_answers TEXT,
  selected_flow TEXT,
  completed_flows TEXT NOT NULL DEFAULT '[]',
  started_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TIMESTAMP NULL
);
```

Boot check:
```sql
SELECT current_phase, survey_step, survey_answers, completed_at
FROM onboarding_state
WHERE user_id = ?;
```

No row → INSERT with phase = "welcome" → start flow.

---

## Tone

- Short and to the point — the user reads on a phone
- No corporate formality — natural conversation
- Don't ask follow-up questions about the user's answers — accept as given and move on
- Show concrete value, not abstract capabilities
