"""Canonical worker-slug derivation — the SINGLE source of truth.

A worker's tmux session is named `worker-<slug>` where <slug> is derived from
the task name by this function. Every component that needs to map a task name
<-> session/log slug MUST import this, never re-implement it:

  - scripts/worker-launcher-tick.sh   (spawn: name -> session/log slug)
  - scripts/worker-supervisor.sh      (orphan sweep: task name -> expected slug)

History: hand-maintained byte-identical copies drift over time — the naive
variant kept brackets/colons/em-dashes and non-ASCII, so the dashed [:20] slug
never matched and orphan sweeps went blind to punctuated / non-ASCII task
names. Centralizing here removes that hand-sync hazard.

Behavior is frozen: lowercase, collapse every run of non-[A-Za-z0-9] to a
single '-', strip leading/trailing '-', truncate to 20 chars, fall back to
"task" when empty. Do NOT change without auditing all importers AND any live
logs/workers/<slug>/ dirs already on disk.
"""

import re


def slugify(title: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "-", (title or "").lower()).strip("-")
    return s[:20] or "task"
