---
title: Business Analysis (configurable lenses)
summary: Analyzes current data through a configurable set of business lenses and produces concrete tasks/drafts — not reports.
read_when: Strategist is looking for opportunities in accumulated signals; need to turn data from context.md and signals.md into concrete actions.
---

# Skill: Business Analysis

Analyze data through a configurable set of business lenses. Read `memory/context.md` for current priorities.

## Configuring the lenses

The lens set is configurable via `memory/lenses.yaml`. If that file is missing, fall back to the generic 5-lens set documented below.

### `memory/lenses.yaml` format

```yaml
# memory/lenses.yaml
lenses:
  - name: signals
    description: New signals, leads, requests across connectors
    questions:
      - What new signals have appeared since the last cycle?
      - Which look like real opportunities vs noise?
  - name: blockers
    description: What's stuck and why
    questions:
      - Which tasks are blocked and on whom?
      - Can any be unblocked with a small action?
  - name: opportunities
    description: Concrete actions worth taking now
    questions:
      - What's the smallest move that would unlock value today?
  - name: performance
    description: Throughput, quality, error patterns
    questions:
      - What patterns show up in workers' results this cycle?
      - Are there recurring failures?
  - name: system-health
    description: Scheduling, queue, infra signals
    questions:
      - Are scheduled checks running on time?
      - Any anomalies in worker logs?
```

The strategist reads each lens entry and uses the `questions` as analysis prompts.

You can replace this with your own domain lenses (sales/content/network/product/profit; or marketing/sales/operations; or whatever fits your business).

## Default 5-lens fallback (no `memory/lenses.yaml`)

### 1. Signals

- New signals/leads/requests across connectors
- Which look like real opportunities vs noise

### 2. Blockers

- Which tasks are blocked and on whom
- Can any be unblocked with a small action

### 3. Opportunities

- Concrete actions worth taking now
- Smallest move that unlocks value today

### 4. Performance

- Patterns in workers' results this cycle
- Recurring failures or successes

### 5. System health

- Scheduled checks running on time
- Anomalies in worker logs

## Output format

Concrete proposals with actions, NOT reports.

**Bad:** "Found 5 posts about AI in mobile dev"
**Good:** "Draft a LinkedIn post based on the AI-in-mobile-dev trend: [text]. 3 companies for outreach: [list with reasons]"

**Bad:** "Client X mentioned they're looking for a contractor"
**Good:** "Task in queue: write X a proposal for [service], budget ~[estimate], deadline [when]. Draft message: [text]"

## Prioritization

Align analysis with current priorities from context.md:
- If focus is on sales → spend more time on sales/profit-style lenses
- If focus is on product → spend more time on product/content-style lenses
- If focus is on growth → spend more time on network/content-style lenses

Create saga tasks via `mcp__saga-mcp__task_create` only for ideas with a concrete next step.
