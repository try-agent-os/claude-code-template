#!/usr/bin/env python3
"""test_drain_liveness.py — proof that the guard actually DETECTS.

Why a unit test and not "hide logs/ and run it against the live queue": a
discrepancy needs a starving task AND no launches at the same time. On a healthy
install there are no starving tasks, so hiding the artifacts yields a green run
that proves nothing — and "the run was green, so it works" is precisely the
class of self-deception this guard exists to catch. Hence a synthetic queue,
while the window and the artifacts are real files in a temp directory.

Both halves are asserted, because either one alone is worthless:
  * NEGATIVE — a pickable task exists and there are no launches in the window
    → the guard shouts (a discrepancy is returned, and the wrapper exits 1);
  * POSITIVE CONTROL — same queue, a launch artifact inside the window
    → the guard stays silent. Without this half, a guard that always shouts
    would pass the negative test.

Run: python3 scripts/lib/test_drain_liveness.py   (exit 0 = every case passed)
"""

import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from drain_liveness import ARTIFACT_RE, evaluate, task_text
from drain_gate import QueueError

NOW = datetime(2026, 7, 17, 12, 0, tzinfo=timezone.utc)
OLD = int((NOW - timedelta(hours=48)).timestamp() * 1000)   # older than any window
FRESH = int((NOW - timedelta(minutes=5)).timestamp() * 1000)

FAILS = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name
          + (f"\n        {detail}" if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def task(tid="t1", name="A task", created=OLD, tags=("auto-worker",), prio="1"):
    return {"id": tid, "name": name, "date_created": str(created),
            "tags": [{"name": t} for t in tags],
            "priority": {"id": prio}, "status": {"status": "to do"}}


def contour(tasks, *, pickable=lambda t: True, window_h=3, cap=10,
            alert_all_rejected=False):
    return {"name": "test-contour", "queue": lambda: list(tasks), "pickable": pickable,
            "window_h": window_h, "artifact_re": ARTIFACT_RE, "session_prefix": "worker-",
            "cap": cap, "queue_label": "test queue", "alert_all_rejected": alert_all_rejected}


def activity(lines):
    """Temp artifact directory holding a worker-activity log for the month."""
    d = tempfile.mkdtemp(prefix="drain-test-")
    with open(os.path.join(d, "2026-07.log"), "w") as fh:
        fh.write("".join(lines))
    return d


NONE_RUNNING = lambda s: False          # noqa: E731
NO_WORKERS = lambda p: 0                # noqa: E731


# ─── NEGATIVE TEST (the core): queue not empty, no artifacts in the window ────
empty_dir = tempfile.mkdtemp(prefix="drain-empty-")
d, line = evaluate(contour([task()]), NOW, empty_dir,
                   running=NONE_RUNNING, active_count=NO_WORKERS)
check("NEGATIVE: pickable task + empty artifact dir → discrepancy",
      d is not None and d["kind"] == "no_launches", f"got: {line}")

stale = activity(["[2026-07-01 03:00] worker old started (backend=x)\n"])
d, line = evaluate(contour([task()]), NOW, stale,
                   running=NONE_RUNNING, active_count=NO_WORKERS)
check("NEGATIVE: artifact exists but is OLDER than the window → discrepancy",
      d is not None and d["kind"] == "no_launches", f"got: {line}")

# ─── POSITIVE CONTROL: same conditions + a fresh artifact → silence ───────────
fresh_ts = (NOW - timedelta(hours=1)).strftime("%Y-%m-%d %H:%M")
ok_dir = activity([f"[{fresh_ts}] worker recent started (backend=x)\n"])
d, line = evaluate(contour([task()]), NOW, ok_dir,
                   running=NONE_RUNNING, active_count=NO_WORKERS)
check("CONTROL: fresh artifact inside the window → OK (else the guard always shouts)",
      d is None, f"got: {line}")

# ─── False positives the guard must NOT produce ───────────────────────────────
d, _ = evaluate(contour([task(created=FRESH)]), NOW, empty_dir,
                running=NONE_RUNNING, active_count=NO_WORKERS)
check("no false positive: task younger than the window (filed 5 min ago) → OK", d is None)

d, _ = evaluate(contour([task()]), NOW, empty_dir,
                running=NONE_RUNNING, active_count=lambda p: 10)
check("no false positive: cap hit (10/10 workers) → idle explained", d is None)

d, _ = evaluate(contour([task()]), NOW, empty_dir,
                running=lambda s: True, active_count=lambda p: 1)
check("no false positive: the task is already running in tmux → OK", d is None)

d, _ = evaluate(contour([]), NOW, empty_dir,
                running=NONE_RUNNING, active_count=NO_WORKERS)
check("no false positive: the queue really is empty → OK", d is None)

d, _ = evaluate(contour([task(tags=())], pickable=lambda t: False), NOW, empty_dir,
                running=NONE_RUNNING, active_count=NO_WORKERS)
check("no false positive: opt-in queue (alert_all_rejected=False) — 0 pickable is normal → OK",
      d is None)

# ─── PREDICATE 2: the gate rejected EVERYTHING (missing-tag incident) ─────────
d, line = evaluate(contour([task(tags=()), task(tid="t2", tags=())],
                           pickable=lambda t: False, alert_all_rejected=True),
                   NOW, ok_dir, running=NONE_RUNNING, active_count=NO_WORKERS)
check("all_rejected: open tasks exist, pickable=0 → discrepancy",
      d is not None and d["kind"] == "all_rejected", f"got: {line}")

d, _ = evaluate(contour([task()], pickable=lambda t: True, alert_all_rejected=True),
                NOW, ok_dir, running=NONE_RUNNING, active_count=NO_WORKERS)
check("no false positive: at least one pickable task → all_rejected stays silent", d is None)

d, _ = evaluate(contour([task(created=FRESH, tags=())], pickable=lambda t: False,
                        alert_all_rejected=True),
                NOW, ok_dir, running=NONE_RUNNING, active_count=NO_WORKERS)
check("no false positive: every rejected task is younger than the window → OK", d is None)

# ─── FAIL-LOUD: a queue error is not an empty queue ───────────────────────────
def boom():
    raise QueueError("backend 500")

try:
    evaluate(dict(contour([]), queue=boom), NOW, empty_dir,
             running=NONE_RUNNING, active_count=NO_WORKERS)
    check("FAIL-LOUD: a queue error propagates instead of reading as 'empty'", False,
          "evaluate swallowed QueueError")
except QueueError:
    check("FAIL-LOUD: a queue error propagates instead of reading as 'empty'", True)

# ─── The artifact regex matches what spawn-worker.sh actually writes ──────────
real_line = ("[2026-07-17 05:10] worker drain-liveness-guard started "
             "(backend=86caw0vmh, model=claude-opus-4-8, timeout=60min)\n")
check("artifact regex matches the real spawn-worker.sh line", bool(ARTIFACT_RE.match(real_line)))
check("artifact regex ignores unrelated lines",
      not ARTIFACT_RE.match("[2026-07-17 05:10] supervisor swept 3 orphans\n"))

# ─── The filed task text makes sense for both kinds ───────────────────────────
for kind in ("no_launches", "all_rejected"):
    title, desc = task_text({"contour": "workers", "kind": kind, "count": 3, "window_h": 3,
                             "live": 0, "cap": 10, "queue_label": "q", "listing": "- x"})
    check(f"task_text({kind}): title and body non-empty, no leftover placeholders",
          bool(title) and "Criteria:" in desc and "{" not in title)

print()
if FAILS:
    print(f"RESULT: FAILED ({len(FAILS)}): {', '.join(FAILS)}")
    sys.exit(1)
print("RESULT: OK — every case passed (detection + no false positives + fail-loud)")
