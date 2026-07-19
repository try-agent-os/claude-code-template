#!/usr/bin/env python3
"""drain-doctor — is the worker queue actually drainable, and if not, WHY?

Failure class this exists for ("green DAG, dead pipe"): a control-plane gate
silently freezes the whole queue while every monitor keeps reporting success.
The `workers` DAG goes green on a tick that picked nothing — "no pickable task"
and "queue healthy, nothing due" are indistinguishable from the outside. Three
observed mechanisms, none of which ever turned a check red:

  * a routine step called a script that was never committed   (phantom ship)
  * a batch of real work carried no `auto-worker` tag         (drain idle at #1)
  * `needs-human` stamps outlived the policy that set them    (queue frozen for
                                                               weeks)

That last one is the sharpest argument for this file. The gate is stamped at
task-GENERATION time and stored as a tag, so it is a snapshot of policy as it
stood that day. When `needs_human.classify_risk()` stops treating a class as
risky, the code changes but already-stamped tasks do not: the classifier says
"safe" while the frozen tag still says "gated". A write-only fix — and a queue
holding a single pickable task can sit that way indefinitely, including (as
actually happened) a queue-triage task that was itself frozen by the freeze it
was created to describe.

So this reports two things the launcher already knows and throws away:
  1. pickable count — the single number that is ~0 through every such incident
  2. per-task skip reason, using the launcher's OWN predicate (imported, not
     reimplemented — a second copy would drift and lie in a new way)

and it flags STALE STAMPS: tasks tagged `needs-human` that current
classify_risk() would not stamp today. That is the backward-propagation the tag
design lacks — policy edits reach new tasks automatically, old ones only
through this check.

Exit codes: 0 = healthy, 1 = frozen (pickable==0 while queue non-empty) or stale
stamps present. Non-zero is what makes the DAG finally go red.

Configuration (nothing is hardcoded — same convention as clickup.sh):
  CLICKUP_API_TOKEN   personal token (falls back to CLICKUP_PERSONAL_TOKEN)
  CLICKUP_TEAM_ID     team/workspace id — required, the task search is team-scoped
  CLICKUP_SPACE_ID    space to inspect — optional, unset means the whole team
  DRAIN_DOCTOR_SURFACE_TAGS
                      comma-separated tags marking a `needs-human` stamp as a
                      deliberate surface-to-a-person ask rather than a risk
                      gate, exempt from stale-stamp sweeps (default "proposal")
Any of these may live in the env file instead (AGENT_OS_ENV_FILE, default
/etc/agent-os/agent-os.env).

Usage:
  scripts/drain-doctor.py              # human summary
  scripts/drain-doctor.py --json       # machine-readable
  scripts/drain-doctor.py --fix-stale  # also UNSTAMP stale needs-human tags
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

# `_setting` is the ONE env/env-file resolution chain in this repo (process env
# wins over the env file). Imported rather than re-implemented: a second copy of
# the token lookup is how instances end up authenticating as the wrong identity.
from clickup_upsert import _setting as setting, _token as clickup_token  # noqa: E402
from needs_human import NEEDS_HUMAN_TAGS, classify_risk, is_manual_gated  # noqa: E402

# Below this, "few pickable tasks" is just an empty queue, not a freeze.
QUEUE_DEPTH_FLOOR = 10


def _tag_names(task: dict) -> set[str]:
    return {t["name"] if isinstance(t, dict) else t for t in task.get("tags") or ()}


def fetch_todo(token: str) -> list[dict]:
    """All todo pages. ClickUp hard-caps 100/page and a real queue exceeds it —
    a page-0-only fetch is how a scheduled task sitting at global position 134
    goes undelivered for weeks. Same trap, same fix as the launcher."""
    team = setting("CLICKUP_TEAM_ID")
    if not team:
        raise RuntimeError(
            "CLICKUP_TEAM_ID is not set (export it or add it to the env file) — "
            "the task search is team-scoped."
        )
    space = setting("CLICKUP_SPACE_ID")
    base = (
        f"https://api.clickup.com/api/v2/team/{urllib.parse.quote(team)}/task"
        f"?statuses[]=todo&include_closed=false&include_subtasks=true"
    )
    if space:
        base += f"&space_ids[]={urllib.parse.quote(space)}"
    out: list[dict] = []
    for page in range(20):
        req = urllib.request.Request(f"{base}&page={page}", headers={"Authorization": token})
        with urllib.request.urlopen(req, timeout=30) as resp:
            batch = json.loads(resp.read()).get("tasks", [])
        out.extend(batch)
        if len(batch) < 100:
            break
    return out


def skip_reason(task: dict) -> str | None:
    """Why the launcher will not pick this task. None = pickable.

    Mirrors worker-launcher-tick.pickable() for the tag/gate half only; the
    host/deps halves live in the launcher's own closures and are not importable.
    Those produce loud stderr already — the tag gates are the silent ones, and
    the silent ones are the whole point of this tool. Gate ORDER matches the
    launcher: the human gate is checked first, before every other branch.
    """
    tags = _tag_names(task)
    name = task.get("name", "")
    if is_manual_gated(name, tags):
        return "needs-human (manual gate)"
    sd = task.get("start_date")
    if sd:
        try:
            if int(sd) > int(datetime.now(timezone.utc).timestamp() * 1000):
                return "start_date in the future"
        except (TypeError, ValueError):
            pass
    if name.startswith("Scheduled:"):
        prio = task.get("priority")
        pid = prio.get("id") if prio else None
        return None if pid in ("1", "2", "3") else f"scheduled task, priority={pid} not in 1-3"
    if "auto-worker" not in tags:
        return "no auto-worker tag"
    return None


# `needs-human` is overloaded — it carries TWO intents that look identical on a
# task and must not be conflated:
#   (a) risk-gate      — classify_risk() stamped it; retiring a risk class makes
#                        the stamp stale, and backfilling it is this tool's job.
#   (b) surface-to-me  — a proposal is tagged so the operator shows it to a
#                        person. classify_risk() knows nothing about intent (b)
#                        and will always call it "safe", so a naive sweep would
#                        strip the tag off every proposal and silently delete
#                        the ask. Intent (b) tasks carry an exempt tag below.
# They are not drain-blockers either way: none carry `auto-worker`.
# Instances that name their surface-to-a-person tag differently override the
# set via DRAIN_DOCTOR_SURFACE_TAGS (comma-separated).
_SURFACE_INTENT_TAGS = {
    t.strip() for t in (setting("DRAIN_DOCTOR_SURFACE_TAGS") or "proposal").split(",") if t.strip()
}


def stale_stamp(task: dict) -> bool:
    """Tagged needs-human as a RISK GATE, but today's policy would not stamp it."""
    tags = _tag_names(task)
    if not tags & NEEDS_HUMAN_TAGS:
        return False
    if tags & _SURFACE_INTENT_TAGS:
        return False  # intent (b) — deliberate, not stale
    residual = tags - NEEDS_HUMAN_TAGS
    return classify_risk(task.get("name", ""), task.get("description") or "", residual) is None


def unstamp(token: str, task_id: str, tag: str) -> bool:
    req = urllib.request.Request(
        f"https://api.clickup.com/api/v2/task/{task_id}/tag/{urllib.parse.quote(tag)}",
        headers={"Authorization": token},
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status == 200
    except urllib.error.URLError:
        return False


def main() -> int:
    as_json = "--json" in sys.argv
    fix = "--fix-stale" in sys.argv

    try:
        token = clickup_token()
        tasks = fetch_todo(token)
    except RuntimeError as exc:
        print(f"[drain-doctor] {exc}", file=sys.stderr)
        return 1

    pickable, blocked, stale = [], [], []
    for t in tasks:
        reason = skip_reason(t)
        (pickable if reason is None else blocked).append((t, reason))
        if stale_stamp(t):
            stale.append(t)

    # The freeze predicate: a deep queue that nobody can pull from. The state
    # that persisted for weeks before this file existed, and never once went red.
    frozen = len(pickable) == 0 and len(tasks) >= QUEUE_DEPTH_FLOOR

    fixed = []
    if fix and stale:
        for t in stale:
            removed = [tag for tag in _tag_names(t) & NEEDS_HUMAN_TAGS
                       if unstamp(token, t["id"], tag)]
            if removed:
                fixed.append(t["id"])

    if as_json:
        print(json.dumps({
            "todo_total": len(tasks),
            "pickable": len(pickable),
            "frozen": frozen,
            "stale_stamps": [{"id": t["id"], "name": t["name"]} for t in stale],
            "unstamped": fixed,
            "blocked_by_reason": {
                r: sum(1 for _, rr in blocked if rr == r)
                for r in sorted({rr for _, rr in blocked if rr})
            },
        }, ensure_ascii=False, indent=2))
    else:
        print(f"=== drain-doctor === todo={len(tasks)} pickable={len(pickable)}")
        if frozen:
            print(f"!! FROZEN: {len(tasks)} todo tasks, ZERO pickable — the drain is dead")
        reasons: dict[str, int] = {}
        for _, r in blocked:
            if r:
                reasons[r] = reasons.get(r, 0) + 1
        for r, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"  blocked: {n:>3}  {r}")
        if stale:
            print(f"\n!! STALE STAMPS: {len(stale)} task(s) carry needs-human "
                  f"but current policy says safe:")
            for t in stale:
                print(f"   {t['id']}  {t['name'][:66]}")
            print("   -> rerun with --fix-stale to unstamp")
        if fixed:
            print(f"\n   unstamped {len(fixed)}: {', '.join(fixed)}")
        if not frozen and not stale:
            print("  OK — queue is drainable, no stale stamps")

    return 1 if (frozen or (stale and not fixed)) else 0


if __name__ == "__main__":
    sys.exit(main())
