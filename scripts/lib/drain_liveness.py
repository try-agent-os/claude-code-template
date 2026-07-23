"""drain_liveness.py — core of the drain liveness guard.

The logic lives in a module (not inside scripts/drain-liveness-check.sh) so it
can be PROVEN by a test (scripts/lib/test_drain_liveness.py) against synthetic
queues. Without that, a negative test is impossible: on a healthy install the
queue is honestly empty, so "hide the artifacts and run it" stays green and
proves nothing — a discrepancy needs a starving task AND no launches AT THE
SAME TIME. A guard whose detection cannot be demonstrated is the same green lie
it was built to catch, one floor up.

The `pickable()` predicate is NOT duplicated here: it is imported from
drain_gate.py, the module the launcher itself picks tasks with (see WHY there).
"""

import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from drain_gate import (QueueError, fetch_queue, pickable, prio_rank,  # noqa: E402
                        resolve_config)
from slugify import slugify  # noqa: E402

# The launch artifact written by scripts/spawn-worker.sh into
# memory/worker-activity/YYYY-MM.log:
#   [2026-07-17 05:10] worker <task-id> started (backend=..., model=..., timeout=45min)
ARTIFACT_RE = re.compile(r"^\[([\d\-]+ [\d:]+)\]\s+worker\s+\S+\s+started")


def build_contours(token, team_id, space_id, repo):
    """The live contours. The test builds its own, with fake queues.

    One contour per drain loop. A fork that runs a second launcher (a separate
    queue with its own worker pool) appends its contour here — with its own
    queue callable, session prefix and artifact regex — and gets the same guard.
    """
    return [
        {
            "name": "workers",
            "queue": lambda: fetch_queue(token, team_id, space_id, strict=True),
            "pickable": lambda t: pickable(t, repo, verbose=False),
            "window_h": float(os.environ.get("DRAIN_WINDOW_H", "3")),
            "artifact_re": ARTIFACT_RE,
            "session_prefix": "worker-",
            "cap": int(os.environ.get("WORKER_CAP", "10")),
            "queue_label": f"team {team_id}" + (f" / space {space_id}" if space_id else ""),
            # SECOND PREDICATE — opt-in, and off by default on purpose. It fires
            # when the gate rejects EVERY open task. That is an anomaly only
            # where the queue is declared fully autonomous; on an install where
            # `auto-worker` is opt-in, "N open tasks, 0 pickable" is the normal
            # resting state (untagged == deliberately parked) and alerting on it
            # would cry wolf on every healthy run. Turn on with
            # DRAIN_ALERT_ALL_REJECTED=1 once every queued task is meant to drain.
            "alert_all_rejected": os.environ.get("DRAIN_ALERT_ALL_REJECTED") == "1",
        },
    ]


def last_launch(contour, since, activity_dir, now):
    """Timestamp of the contour's most recent launch at/after `since`, else None.

    Reads the current and previous month — the window may cross a month border.
    """
    months = {now.strftime("%Y-%m"), (now - timedelta(days=32)).strftime("%Y-%m")}
    latest = None
    for month in sorted(months):
        path = os.path.join(activity_dir, f"{month}.log")
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                hit = contour["artifact_re"].match(line)
                if not hit:
                    continue
                try:
                    ts = datetime.strptime(hit.group(1), "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc)
                except ValueError:
                    continue
                if ts >= since and (latest is None or ts > latest):
                    latest = ts
    return latest


def created_at(t):
    """date_created as an aware datetime; None when the field is absent/malformed."""
    try:
        return datetime.fromtimestamp(int(t.get("date_created")) / 1000, timezone.utc)
    except (TypeError, ValueError):
        return None


def _running(session):
    return subprocess.run(["tmux", "has-session", "-t", session],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def _active_count(prefix):
    out = subprocess.run(["tmux", "ls"], capture_output=True, text=True).stdout
    return sum(1 for line in out.splitlines() if line.startswith(prefix))


def _fmt_listing(tasks, with_tags=False):
    out = []
    for t in tasks:
        link = f"- [{t['name']}](https://app.clickup.com/t/{t['id']})"
        if with_tags:
            tags = sorted({(x["name"] if isinstance(x, dict) else x) for x in (t.get("tags") or [])})
            out.append(f"{link} — tags: {tags or 'none'}")
        else:
            out.append(f"{link} — priority {prio_rank(t)}")
    return "\n".join(out)


def evaluate(contour, now, activity_dir, running=_running, active_count=_active_count):
    """Judge one contour. -> (discrepancy|None, human-readable line).

    FAIL-LOUD: QueueError propagates. A queue that could not be read must never
    read as "the queue is empty" — that is the failure mode this guard exists for.
    """
    c = contour
    since = now - timedelta(hours=c["window_h"])
    tasks = c["queue"]()          # QueueError propagates deliberately

    # Who is actually waiting: passes the gate + is not already running + is
    # older than the window. The age filter kills the "filed five minutes ago"
    # false positive.
    starved = []
    for t in tasks:
        if not c["pickable"](t):
            continue
        if running(c["session_prefix"] + slugify(t.get("name", ""))):
            continue
        created = created_at(t)
        if created is not None and created > since:
            continue
        starved.append(t)

    live = active_count(c["session_prefix"])

    # PREDICATE 2: the gate rejected EVERYTHING. Signature of the missing-tag
    # incident: pickable=0, the tick logs "no ready pickable task" and reports
    # success. Predicate 1 is silent here — there really are no pickable tasks —
    # which is exactly why this one has to exist separately.
    open_old = [t for t in tasks if (created_at(t) or now) <= since]
    if c.get("alert_all_rejected") and open_old and not any(c["pickable"](t) for t in tasks):
        return ({
            "contour": c["name"], "kind": "all_rejected", "count": len(open_old),
            "window_h": c["window_h"], "live": live, "cap": c["cap"],
            "queue_label": c["queue_label"],
            "listing": _fmt_listing(sorted(open_old, key=prio_rank)[:5], with_tags=True),
        }, f"DISCREPANCY [{c['name']}]: {len(open_old)} open task(s) older than "
           f"{c['window_h']:g}h and the gate lets through NOT ONE (pickable=0) — "
           f"work is being dropped silently")

    if not starved:
        return (None, f"OK [{c['name']}]: no starving tasks "
                      f"(pickable + not running + older than {c['window_h']:g}h — none)")

    # Legitimate explanation for the idle: every slot is busy.
    if live >= c["cap"]:
        return (None, f"OK [{c['name']}]: {len(starved)} task(s) waiting but the cap is hit "
                      f"({live}/{c['cap']} workers alive) — idle explained")

    launched = last_launch(c, since, activity_dir, now)
    if launched:
        return (None, f"OK [{c['name']}]: {len(starved)} task(s) queued, last launch "
                      f"{launched:%Y-%m-%d %H:%M} UTC (inside the {c['window_h']:g}h window)")

    # PREDICATE 1: there is work, there is a free slot, there were no launches.
    return ({
        "contour": c["name"], "kind": "no_launches", "count": len(starved),
        "window_h": c["window_h"], "live": live, "cap": c["cap"],
        "queue_label": c["queue_label"],
        "listing": _fmt_listing(sorted(starved, key=prio_rank)[:5]),
    }, f"DISCREPANCY [{c['name']}]: {len(starved)} pickable task(s) waiting "
       f"(queue {c['queue_label']}), workers alive {live}/{c['cap']}, "
       f"and launches in the last {c['window_h']:g}h — NONE")


def task_text(d):
    """(title, description) of the task filed for discrepancy `d`."""
    if d["kind"] == "all_rejected":
        title = (f"drain idle: contour {d['contour']} — the gate lets through NONE of "
                 f"{d['count']} task(s) (pickable=0, {d['window_h']:g}h)")
        desc = (
            f"`scripts/drain-liveness-check.sh` caught the \"green DAG + empty logs\" class "
            f"in its second shape: the queue ({d['queue_label']}) holds {d['count']} open "
            f"task(s) older than {d['window_h']:g}h, and the launcher gate lets through NOT "
            f"ONE — pickable=0. The tick meanwhile honestly logs 'no ready pickable task' "
            f"and reports success.\n\n"
            f"This install declares that every queued task drains, so \"not a single task "
            f"passes the gate\" is an anomaly, not parking.\n\n"
            f"Tasks and their tags (top by priority):\n{d['listing']}\n\n"
            f"Scope: find why the gate rejects all of them (most often a missing "
            f"`auto-worker` tag, a `needs-human` tag left behind, or an unmet declared "
            f"dependency; the predicate is `scripts/lib/drain_gate.py:pickable`). Fix the "
            f"cause and confirm with an actual worker launch.\n\n"
            f"Criteria: the contour launches workers again; `bash scripts/drain-liveness-check.sh` "
            f"exits 0 for this contour.\n\nTimeout: 60"
        )
        return title, desc

    title = (f"drain idle: contour {d['contour']} — "
             f"{d['count']} task(s) queued, 0 launches in {d['window_h']:g}h")
    desc = (
        f"`scripts/drain-liveness-check.sh` caught the \"green DAG + empty logs\" class: the "
        f"drain contour **{d['contour']}** launched NOT ONE worker in the last "
        f"{d['window_h']:g}h, while the queue ({d['queue_label']}) holds {d['count']} task(s) "
        f"that pass the launcher gate (pickable), are not running right now, and are older "
        f"than the window. Slots are free: {d['live']}/{d['cap']} workers alive.\n\n"
        f"So the tick either never ran, or dropped the work silently and reported success.\n\n"
        f"Starving tasks (top by priority):\n{d['listing']}\n\n"
        f"Scope: find WHY the gate/tick is not taking these tasks (DAG journal, the tick's "
        f"stderr, the predicate in `scripts/lib/drain_gate.py`), fix the cause, confirm with "
        f"an actual launch.\n\n"
        f"Criteria: the contour launches workers again; `bash scripts/drain-liveness-check.sh` "
        f"exits 0 for this contour.\n\nTimeout: 60"
    )
    return title, desc


def file_task(repo, d, title, desc, dry_run=False, log=print):
    """One task per contour, forever: dedup key drain-idle:<contour> (upsert)."""
    if dry_run:
        log(f"[dry-run] would file a task: {title}")
        return
    rc = subprocess.run(
        ["/bin/bash", f"{repo}/scripts/lib/file-finding-task.sh",
         "--monitor", "drain-liveness",
         "--key", f"drain-idle:{d['contour']}",
         "--title", title, "--desc", desc,
         "--priority", "1", "--cwd", repo, "--tag", "drain-liveness"],
        capture_output=True, text=True)
    if rc.returncode != 0:
        print(f"WARN: could not file a task for {d['contour']}: {rc.stderr.strip()}",
              file=sys.stderr)
    else:
        log(f"filed: {rc.stdout.strip()}")


def main(repo, dry_run=False, quiet=False):
    def log(msg):
        if not quiet:
            print(msg)

    env_file = os.environ.get("AGENT_OS_ENV_FILE", "/etc/agent-os/agent-os.env")
    token, team_id, space_id = resolve_config(env_file)
    if not token or not team_id:
        print("FAIL-LOUD: task backend token / team id not found — cannot judge queue state",
              file=sys.stderr)
        return 2

    activity_dir = os.environ.get("DRAIN_ACTIVITY_DIR", f"{repo}/memory/worker-activity")
    now = datetime.now(timezone.utc)
    contours = build_contours(token, team_id, space_id, repo)

    discrepancies = []
    for c in contours:
        try:
            d, line = evaluate(c, now, activity_dir)
        except QueueError as e:
            print(f"FAIL-LOUD [{c['name']}]: {e}", file=sys.stderr)
            return 2
        log(line)
        if d:
            discrepancies.append(d)

    for d in discrepancies:
        title, desc = task_text(d)
        file_task(repo, d, title, desc, dry_run=dry_run, log=log)

    print(f"SUMMARY: contours={len(contours)} discrepancies={len(discrepancies)}"
          + (" (dry-run)" if dry_run else ""))
    return 1 if discrepancies else 0
