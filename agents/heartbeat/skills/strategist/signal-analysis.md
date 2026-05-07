---
title: Signal Analysis
summary: Framework for processing signals from memory/signals.md — scoring, grouping into patterns in patterns.md, conversion into tasks and opportunities, with verification of high-potential signals.
read_when: New signals have accumulated in signals.md; need to set priority and create tasks for high-potential signals.
---

# Skill: Signal Analysis

Analytical framework for processing signals in `memory/signals.md`.

## Signal types

| Type | Description | Example |
|------|-------------|---------|
| lead | Potential client | DM inquiry, mention of budget |
| trend | Market trend | Rising demand for AI integrations |
| request | Request from client/contact | "Can you do X?" |
| problem | A problem you can solve | Complaint in chat about a tool |
| idea | Idea for product/content | Topic for a post, feature for a service |

## Scoring

- **high** — clear lead, direct request, concrete need with budget
- **med** — indirect signal, interest without specifics, relevant trend
- **low** — background noise, general discussion, far from current focus

## Grouping

Related signals → pattern:

- 2+ signals on the same topic → create/update a pattern in `memory/patterns.md`
- Format: `### Pattern: name`, confidence = 0.5 (initial), sources = list of signals
- Existing pattern + new signal → confidence += 0.1

## Conversion to tasks

Signals with cumulative score >= 3 (or one high) → create a task in `memory/queue.md`:

- Scope: concrete, numbered steps
- Acceptance criteria: how to know it's done
- Context: links to source signals

## Creating opportunities

Format in `memory/opportunities.md`:

```
### OPP-NNN: Title
- **Source:** signal or pattern
- **Potential:** high/med/low
- **Next step:** concrete action
- **Created:** YYYY-MM-DD
- **Status:** active | dismissed | converted
```

Numbering: find the last OPP-NNN, increment by +1.

## Aging opportunities

- Opportunity active > 72h with no movement → decision:
  - New data appeared → update next step
  - No new data, still relevant → escalate (task in memory/queue.md)
  - No longer relevant → dismiss with reason

## HIGH-trigger

A high-potential signal (clear lead, direct request with budget) → first VERIFY:

| Signal source | What to check |
|---------------|--------------|
| Telegram | Gmail in the last 24h for keywords from the event |
| Gmail | Contact timeline + Telegram signals.md |
| Web/scan | signals.md for duplicates + tracker pipeline |

If the signal is VERIFIED (confirmed by at least one additional source):
→ create opportunity + HIGH task immediately

If the signal is SOLO (one source only, no cross-confirmation):
→ create a [MED] task "Verify signal: {name}" in queue.md
→ log it in signals.md tagged "unverified, source: {source}"
→ Do NOT create an opportunity, do NOT alert the user

Exception: a direct request from an existing client → HIGH immediately, no waiting.
