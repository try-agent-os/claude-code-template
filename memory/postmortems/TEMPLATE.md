# Postmortem: <SHORT INCIDENT TITLE>

**Date:** YYYY-MM-DD
**Incident duration:** ~Xh
**Severity:** Low | Medium | High | Critical — *one-line user-facing impact*

## Symptoms

- Observable signal #1 (what someone saw, with the exact log line / error message)
- Observable signal #2
- Timeline highlights: "first noticed at X, escalated at Y"

## Root Cause

**One sentence stating the actual cause.** Then a paragraph with the technical detail —
which component, which interaction, which assumption was wrong.

## False trails (what we checked and why it didn't help)

1. **Hypothesis A** — what we tried, why we thought it would work, what actually happened
2. **Hypothesis B** — same structure
3. ...

This section is not optional. Capturing the false trails saves the next on-call from
re-running the same diagnostic loop.

## Resolution

Numbered steps that actually fixed it. Include exact commands.

```bash
# example
launchctl kickstart -k "gui/$(id -u)/com.{PROJECT_SLUG}.<service>"
```

## How to detect

Diagnostic command(s) that would have caught this faster next time. Example:

```bash
# example
lsof -i :443 | grep "<remote-host-pattern>"
```

## Lessons

1. **Concrete lesson with action** — e.g. "lsof is the first tool when investigating port conflicts"
2. **Anti-pattern to avoid** — e.g. "don't add retry logic when the symptom is two clients fighting for the same lease"
3. **Documentation/runbook to update** — name the file that should now reflect this lesson

## Follow-ups

- [ ] Saga task: `<task-id>` — long-term mitigation
- [ ] Update `memory/self-heal-runbook.md` if pattern is recurrent
- [ ] Add to `memory/learnings.md` with tag `#correction` if user feedback drove the resolution
