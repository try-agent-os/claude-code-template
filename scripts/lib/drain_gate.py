"""drain_gate.py — the ONE drain gate: which queued task may a worker take, now?

WHY THIS FILE EXISTS
--------------------
The worker launcher answers one question every tick: "is there work I may pick
up?". When that answer is wrong the failure is SILENT and looks exactly like
success — the tick reports "no ready pickable task" and the cron DAG stays
green while the queue sits full. Three shapes of the same class, all seen in
production:

  * a `page=0`-only queue fetch truncated the queue at 100 tasks — a scheduled
    task past that position went undelivered for weeks, DAG green throughout;
  * a pipeline step called a script that did not exist — the whole block
    vanished from the run with nothing red anywhere;
  * a batch of tasks never got the `auto-worker` opt-in tag — the top-priority
    queue idled for days while every tick logged "no ready pickable task" and
    exited 0.

The invariant of the class: **the gate drops work silently, the runner reports
success.** `scripts/drain-liveness-check.sh` is the guard that catches it, by
comparing the queue against the launch ARTIFACTS rather than against a status.

THE GUARD MUST NOT COPY THE PREDICATE. A guard carrying its own copy of
`pickable()` drifts away from the real gate, and then it masks exactly the bug
it exists to catch: it would report "no work in the queue" for the same wrong
reason the launcher did. So the gate lives HERE, and both the launcher
(`scripts/worker-launcher-tick.sh`) and the guard IMPORT it. Change the gate
once and both contours change together.

FAIL-LOUD. A queue that could not be fetched is NOT an empty queue. `strict=True`
(the guard) turns any fetch problem — HTTP error, or a pagination cap that
dropped the remainder — into `QueueError`. `strict=False` (the launcher) keeps
whatever pages it got, because partial work is still work, and raises only when
nothing usable came back.

Pagination itself is not reimplemented here either: it comes from
`scripts/lib/clickup_fetch.py`, the single paginated fetch for the worker layer.
"""

import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from clickup_fetch import fetch_tasks  # noqa: E402
from needs_human import is_manual_gated  # noqa: E402

DEFAULT_REPO = os.environ.get("REPO_ROOT", "/opt/agent-os/claude")


class QueueError(RuntimeError):
    """The queue could not be read. NOT "the queue is empty" — fail loud."""


# ────────────────────────────── config ──────────────────────────────

def _from_env_file(env_file, key):
    try:
        with open(env_file) as fh:
            for line in fh:
                if line.startswith(key + "="):
                    return line.strip().split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return None


def resolve_config(env_file="/etc/agent-os/agent-os.env"):
    """(token, team_id, space_id) from the environment, env file as fallback.

    space_id may be None — scoping the query to a space is optional.
    """
    def get(key):
        return os.environ.get(key) or _from_env_file(env_file, key)

    return get("CLICKUP_PERSONAL_TOKEN"), get("CLICKUP_TEAM_ID"), get("CLICKUP_SPACE_ID")


# ────────────────────────────── queue ──────────────────────────────

def fetch_queue(token, team_id, space_id=None, *, statuses=("todo",),
                strict=False, log=None):
    """Every `todo` task of the queue, across ALL pages.

    strict=False (launcher): partial beats nothing — pages already gathered are
      returned; QueueError only when the result is unusable (page-0 failure).
    strict=True (guard): any error OR a capped walk raises QueueError. A guard
      that mistakes "I could not read a page" for "there is no work" would
      report all-clear on precisely the outage it watches for.
    """
    result = fetch_tasks(
        token, team_id,
        statuses=list(statuses),
        space_ids=[space_id] if space_id else [],
        # Nested subtasks must be visible: without them a queue whose eligible
        # work is all nested looks empty to the launcher. Both spellings are
        # sent — ClickUp ignores the one it does not know.
        subtasks=True,
        extra_params={"include_subtasks": "true"},
        log=log, label="drain-gate")

    if strict:
        if result.error is not None:
            raise QueueError(f"queue fetch failed after {result.pages} page(s): {result.error}")
        if result.capped:
            raise QueueError("queue fetch hit the pagination cap — the remainder was "
                             "DROPPED, so the queue cannot be judged")
        return result.tasks

    if result.error is not None and not result.tasks:
        raise QueueError(f"queue fetch failed on the first page: {result.error}")
    return result.tasks


# ────────────────────────────── gate ──────────────────────────────

def _parse_task_deps(description):
    """Dep declarations out of a task description -> (host_cmds, deps)."""
    host_cmds, deps = [], []
    for line in description.splitlines():
        m_cmd = re.match(r"\s*Requires\s*\(host cmd\)\s*:\s*(.+)", line, re.IGNORECASE)
        if m_cmd:
            host_cmds.extend(c.strip() for c in m_cmd.group(1).split(",") if c.strip())
        m_dep = re.match(r"\s*Requires\s*\(dep\)\s*:\s*(.+)", line, re.IGNORECASE)
        if m_dep:
            deps.extend(d.strip() for d in m_dep.group(1).split(",") if d.strip())
    return host_cmds, deps


def _task_deps_satisfied(task_id, description, repo, say):
    """True if every declared dep is available on this host; says why if not."""
    host_cmds, deps = _parse_task_deps(description)
    for cmd in host_cmds:
        if shutil.which(cmd) is None:
            say(f"skip {task_id}: host cmd '{cmd}' not on PATH here")
            return False
    dep_check = os.path.join(repo, "scripts", "lib", "dep-reachable.sh")
    if deps and not os.access(dep_check, os.X_OK):
        # Fail OPEN: a missing checker must not silently strand the whole queue.
        say(f"WARN {task_id} declares deps but {dep_check} is missing/not "
            f"executable — not gating")
        return True
    for dep in deps:
        rc = subprocess.run(["/bin/bash", dep_check, dep], capture_output=True, text=True)
        if rc.returncode != 0:
            detail = rc.stderr.strip() or f"dep-reachable.sh exited {rc.returncode}"
            say(f"skip {task_id}: dep '{dep}' unreachable — {detail}")
            return False
    return True


def pickable(t, repo=DEFAULT_REPO, *, verbose=True, log=None):
    """May a worker take this task right now? THE gate — launcher and guard share it.

    Every branch says WHY it skipped when `verbose`. The launcher's only visible
    failure mode is "the queue looks empty", and a silent `return False` makes
    that indistinguishable from "there genuinely is no work" — the difference
    between a 20-minute diagnosis and a 20-day one. The guard passes
    verbose=False: it evaluates the whole queue and reports the aggregate.
    """
    def say(message):
        if not verbose:
            return
        if log is not None:
            log(message)
        else:
            print(f"[drain-gate] {message}", file=sys.stderr)

    name = t.get("name", "")
    tag_names = {(tag["name"] if isinstance(tag, dict) else tag)
                 for tag in (t.get("tags") or [])}

    # HUMAN GATE: `needs-human` (or `manual-only`) opts a task back OUT, even
    # when it carries `auto-worker`. Checked FIRST, before every other branch,
    # so that it holds for `Scheduled:` tasks too — a gate with an exception is
    # not a gate, and the exception would be silent. See scripts/lib/needs_human.py.
    if is_manual_gated(name, tag_names):
        say(f"skip {t.get('id')} ({name[:60]}): human gate")
        return False

    # START-DATE GATE: a task with a future start_date is deferred — skipped
    # until that wall-clock moment, then drained normally. Lets a task self-
    # activate at a set time without a one-shot cron. start_date is epoch-ms
    # (string) or null/absent; malformed → ignore the gate.
    sd = t.get("start_date")
    if sd:
        try:
            if int(sd) > int(datetime.now(timezone.utc).timestamp() * 1000):
                say(f"skip {t.get('id')} ({name[:60]}): start_date in the future")
                return False
        except (TypeError, ValueError):
            pass

    # DEPENDENCY GATE: applies to every task class (a `Scheduled:` task needing
    # a missing binary is exactly the case this exists for).
    if not _task_deps_satisfied(t.get("id"), t.get("description") or "", repo, say):
        return False

    # Scheduled cron-tasks — system-internal, keep the priority-only gate.
    prio = t.get("priority")
    prio_id = prio.get("id") if prio else None
    if name.startswith("Scheduled:"):
        return prio_id in ("1", "2", "3")

    # User tasks — require the `auto-worker` opt-in tag. ALL priorities drain
    # (urgency is ordering, not a gate); the tag is the safety valve so
    # judgment/personal tasks are never auto-grabbed.
    if "auto-worker" not in tag_names:
        say(f"skip {t.get('id')} ({name[:60]}): no auto-worker tag")
        return False
    return True


def prio_rank(t):
    """Lower = more urgent. 1=urgent, 2=high, 3=normal; unknown sinks to the bottom."""
    prio = t.get("priority")
    pid = prio.get("id") if prio else None
    try:
        return int(pid)
    except (TypeError, ValueError):
        return 99
