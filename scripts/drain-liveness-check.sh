#!/usr/bin/env bash
# drain-liveness-check.sh — liveness guard for the drain contours: "the queue is
# not empty, and there were no launches for N hours" → files a task.
#
# WHY: a green DAG is not proof that work is happening. Three incidents of one
# class, all with nothing red anywhere:
#   * a `page=0`-only queue fetch truncated the queue at 100 tasks — a scheduled
#     task past that position went undelivered for weeks;
#   * a pipeline step called a script that did not exist — the block silently
#     vanished from every run;
#   * a batch of tasks never received the `auto-worker` opt-in tag — the
#     top-priority queue idled while each tick logged "no ready pickable task"
#     and exited 0.
# The invariant of the class: THE GATE DROPS WORK SILENTLY, THE RUNNER REPORTS
# SUCCESS.
#
# Why a DAG status cannot catch it: the DAG is honestly green — the tick ran and
# concluded there was no work. It is catchable only by ARTIFACT: there is a
# pickable task in the queue, and the number of launches in the window is zero.
#
# THE GATE IS NOT COPIED. `pickable()` comes from scripts/lib/drain_gate.py —
# the same module the launcher itself picks tasks with. A copied predicate would
# drift from the original, and then this guard would silently repeat the
# launcher's mistake ("there is no work") — masking the exact bug it must catch.
#
# THE ARTIFACT is memory/worker-activity/YYYY-MM.log — append-only lines written
# by scripts/spawn-worker.sh at launch time. Not logs/workers/<slug>/: that
# directory is recreated (rm -rf + mkdir) on every run, so its mtime lies about
# when a worker last started.
#
# FAIL-LOUD: a failure to read the queue NEVER turns into "the queue is empty" —
# that is exit 2, not a quiet green.
#
# The logic lives in scripts/lib/drain_liveness.py (a module, so the detection
# can be proven by scripts/lib/test_drain_liveness.py). This file is only the
# wrapper.
#
# Exit codes:
#   0 — every contour is alive (or the idle is explained: cap hit / already
#       running / queue empty)
#   1 — a discrepancy was found (task filed, details on stdout)
#   2 — FAIL-LOUD: queue unreachable / token missing — the idle cannot be judged
#
# Usage: drain-liveness-check.sh [--dry-run] [--quiet]
# Env:
#   DRAIN_WINDOW_H            hours without a launch that count as idle (default 3)
#   DRAIN_ALERT_ALL_REJECTED  1 → also alert when the gate rejects every open
#                             task (only for a queue declared fully autonomous)
#   DRAIN_ACTIVITY_DIR        override the artifact directory (tests)
#   WORKER_CAP                worker slots, mirrors worker-launcher-tick.sh (default 10)
set -uo pipefail

REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

DRY_RUN=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --quiet)   QUIET=1 ;;
    *) echo "drain-liveness-check: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO" "$DRY_RUN" "$QUIET" <<'PYEOF'
import sys

REPO, DRY_RUN, QUIET = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"

# Any unhandled error = exit 2 (FAIL-LOUD), NOT 1. Otherwise Python's default
# exit 1 is indistinguishable from "a discrepancy was found", and a broken guard
# would read as a firing one — the very class this script catches.
def _fail_loud(exc_type, exc, tb):
    import os, traceback
    traceback.print_exception(exc_type, exc, tb)
    print("FAIL-LOUD: unexpected error — cannot judge drain state", file=sys.stderr)
    os._exit(2)

sys.excepthook = _fail_loud

sys.path.insert(0, f"{REPO}/scripts/lib")
from drain_liveness import main

sys.exit(main(REPO, dry_run=DRY_RUN, quiet=QUIET))
PYEOF
