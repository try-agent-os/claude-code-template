# Routines

File-defined scheduled routines. Every `*.yaml` in this directory is a
routine: the node's reconciler reads the directory on boot and after each
repo sync, and upserts each file into its scheduler. Delete the file and the
routine is disabled on the next sync — no separate cleanup step.

## Format

```yaml
name: morning-brief
description: Short summary of what this routine does and why it exists.

on:
  schedule:
    cron: "0 8 * * 1-5"       # 5-field cron: minute hour day month weekday
    timezone: Europe/Lisbon
    catch_up: run_once        # run once if the node was down when it fired

steps:
  - name: brief
    agent:
      prompt: |
        Multiline prompt for the agent running this step. Describe the goal,
        what to read first (memory/, recent tasks, etc.), and the shape of
        the expected output.
```

- `name` — unique routine id; also used as the display name.
- `description` — one or two sentences; shows up wherever routines are listed.
- `on.schedule.cron` — standard 5-field cron expression.
- `on.schedule.timezone` — IANA timezone name the cron is evaluated in.
- `on.schedule.catch_up` — `run_once` replays a single missed firing after
  downtime instead of silently skipping it.
- `steps` — ordered list; each step names an agent and gives it a prompt.

See [`examples/routines/`](../../examples/routines/) for a complete,
realistic starting point.
