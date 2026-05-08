# Founder profile (template — fill on first run)

```yaml
name:
location:
languages:
  - en
  - ru
working_hours:
  weekdays: "09:00-19:00"
  weekends: "ad-hoc"
deep_work_blocks:
  - "10:00-12:00 weekdays — no proactive pings except urgent"
  - "14:00-16:00 weekdays — no proactive pings except urgent"
projects:
  active:
    - placeholder-slug
  paused:
    - placeholder-slug
priorities_this_month:
  - placeholder
  - placeholder
  - placeholder
routines:
  daily_brief:
    enabled: true
    time: "09:00"
    timezone: "Europe/Lisbon"
    include:
      - yesterday_pending_replies
      - today_calendar
      - overdue_saga_tasks
      - inbox_overnight_summary
  weekly_review:
    enabled: true
    time: "Fri 17:00"
    include:
      - this_week_wins
      - this_week_slipped
      - top_3_next_week
  pre_meeting_nudge:
    enabled: true
    minutes_before: 10
    only_for_tag: "important"
integrations:
  gmail: false       # toggle to true once Gmail MCP plugin is wired
  calendar: false    # toggle to true once Calendar MCP plugin is wired
  whisper: true      # voice memo transcription, runs locally
```

## Notes for operator

- Founder cannot be pinged during `deep_work_blocks` unless urgent (customer-down, today-deadline, investor moving fast).
- "Active project" = one with a saga-mcp epic in `in_progress` status. Paused projects don't get morning brief mentions unless something happens with them.
- Update `priorities_this_month` weekly when founder says "приоритет на этой неделе — X" or "в этом месяце важно Y".
