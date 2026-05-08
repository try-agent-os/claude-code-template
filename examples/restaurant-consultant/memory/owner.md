# Owner profile (template — fill on first run)

This file holds the consultant's profile. Operator reads it on every fresh session to know who they're talking to.

```yaml
# Replace with real values during onboarding.
name:
city:
languages:
  - ru
  - pt
  - en
working_hours:
  weekdays: "09:00-19:00 Europe/Lisbon"
  weekends: "ad-hoc"
client_count:
  active:
  monthly_avg:
priorities:
  current_month:
    - placeholder
  next_quarter:
    - placeholder
expertise:
  - menu engineering
  - review response
  - slow-period marketing
  - kitchen ops
  - staff coordination
deep_work_hours: "10:00-12:00 daily — do not disturb unless urgent"
preferred_reply_style: "short, bullet, same language as input"
```

## Notes for operator

- "Active client" = engagement with a current saga-mcp epic in `in_progress` status.
- "Priorities" change weekly; operator updates this file after the consultant says "приоритет на этой неделе — X".
- "Deep work hours" is a hard constraint — no proactive pings during this window unless urgent (review crisis, client cancelled meeting last-minute, etc.).
