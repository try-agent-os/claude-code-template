---
title: System Self-Improvement
summary: Manages pattern confidence (decay/boost/promotion/archival), runs performance review from performance.md, and meta-review of AgentOS every 30 heartbeat cycles.
read_when: Regular strategist cycle; need to update pattern confidence and check patterns-staging.md and performance.md.
---

# Skill: System Self-Improvement

Framework for improving AgentOS based on accumulated data.

## Pattern confidence

Working with `memory/patterns.md`:

### Decay

Pattern with `last_used` > 7 days ago → confidence -= 0.05
- Floor: 0.3 (won't drop below, except via archival)
- Check the date of last use

### Boost

Pattern used successfully (task done, result confirmed) → confidence += 0.05
- Cap: 1.0 (won't exceed)
- Update `last_used` to today

### Promotion

Conditions: confidence >= 0.9 AND used >= 5 times
- Create a task in memory/queue.md: "Add pattern X to the CLAUDE.md of agent Y"
- Priority: LOW
- Requires user confirmation (changing CLAUDE.md = architectural decision)

### Archival

Condition: confidence < 0.3
- Move the pattern to `## Archive` in patterns.md
- Add reason: "confidence dropped below threshold, unused N days"

## Performance review

Check the latest entries in `memory/performance.md`:
- Recurring failures (the same error 2+ times) → create a fix task
- Tasks taking longer than expected → review scope decomposition
- Successful patterns → boost confidence

### performance.md entry format

```
### YYYY-MM-DD HH:MM — task title
- **Type:** skill_task | strategist | manual
- **Result:** done | partial | blocked | failed
- **Time:** expected vs actual
- **Insight:** what we learned
```

## Validate Staging

Check `memory/patterns-staging.md` for patterns ready to be promoted into `memory/patterns.md`.

### Promotion criteria

1. **Quantity:** `confirmed_in` contains 2+ different tasks/sources
2. **Confidence:** `confidence >= 0.7`
3. **OR** Strategist manually verified the pattern

### Algorithm

1. Read `memory/patterns-staging.md` — find all patterns under `## Staging`
2. For each pattern:
   - If criteria met → **promote**: add to the corresponding section of `memory/patterns.md` (format: `- Description | confidence: X.X | last_used: YYYY-MM-DD | source: staging | used: N | failed: 0`)
   - If criteria not met → keep in staging (don't delete)
   - If pattern is clearly wrong or contradicts known learnings → delete with a comment in the git commit
3. After promotion — remove the promoted pattern from staging
4. If there are no patterns — skip this step

### Anti-promotion

Do NOT promote if:
- Pattern describes a one-off event, not a generalizable rule
- Pattern contradicts entries in `memory/learnings.md`
- `confirmed_in` contains the same source restated

## Meta-review (heartbeat_count % 30)

Extended analysis, output to `memory/meta-reviews/{YYYY-MM-DD}.md`:

1. **Schedule compliance** — are all checks running at the expected cadence? Any gaps?
2. **Pipeline health** — is the pipeline growing? Discovery working? Conversion?
3. **Blocked aging** — any tasks blocked > 3 days? Why? What to do?
4. **Context accuracy** — does context.md match reality? Are priorities current?
5. **Pattern effectiveness** — which patterns work (high confidence, frequently used)? Which don't (low confidence, rare)? Any new informal patterns?

Meta-review format:

```
# Meta-review YYYY-MM-DD

## System health: X/10

## Schedule compliance
...

## Pipeline health
...

## Blocked tasks
...

## Context accuracy
...

## Pattern effectiveness
...

## Recommendations
1. ...
2. ...
3. ...
```
