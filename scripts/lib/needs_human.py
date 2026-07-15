"""needs_human — single source of truth for the drain safety-gate.

An autonomous queue drains tasks into workers without anyone watching. Most
tasks are safe to hand a worker. A few are not, and the queue cannot tell the
difference on its own — so this module answers one question in one place:

    may a worker take this task, or does a human have to look first?

THE SIGNAL IS A TAG, NOT A NAME. Enforcement (`is_manual_gated`) matches only
the `needs-human` tag (`manual-only` is accepted as a synonym). Nothing else
gates. That constraint is the whole design, and it is worth stating why:

  - A tag is reversible by a human. Once a gated task has been reviewed and
    approved, removing the tag releases it. A gate that also matched on the
    task's NAME could never be released that way — the name still matches, so
    the task re-blocks forever and the only way out is to rename it. We shipped
    that bug: a name-matched class silently froze a whole class of tasks for
    weeks. Nothing went red; the queue just quietly stopped draining that class.
  - One signal means one place to look. When a task is not draining, the answer
    is `is_manual_gated()` and the tag list — not a fuzzy name heuristic running
    over the queue on every tick.

WHERE THE HEURISTIC LIVES. The keyword classes below (`classify_risk`) run at
task GENERATION time, not at drain time: a generator decides once, deterministically,
and stamps the tag; a human can see the tag and undo it. Running the same
heuristic in the launcher would re-introduce exactly the name-matching gate
described above, and would misfire on a safe task that merely mentions a gated
component in passing.

FAIL-CLOSED. `classify_risk` errs toward catching. A false positive costs a
human glance; a false negative hands a worker something it should not have had.

RISK CLASSES
  - operator-lifeline: the running agent's own life-support (chat transport,
    auth/token refresh, watchdog, restart layer, peer broker). A worker
    refactoring the live agent's life-support can cut the channel it reports
    through, or kill the session it is running in.
  - reminder: the task is FOR the human, not for a worker. It carries an action
    only a person can take (pay an invoice, move a domain, make a call).

WIRING (both ends import this module so the policy lives in exactly one place):
  - scripts/worker-launcher-tick.sh -> is_manual_gated()  (enforcement)
  - your task generators             -> classify_risk()    (generation)

WHAT THIS IS NOT. This gate is not a code-review or leak gate. It runs against a
task, where no diff exists yet, so it cannot inspect what a worker will write.
Guards that need a diff (e.g. scanning a PR for secrets before merge) belong at
the PR, not here.
"""
from __future__ import annotations

# Canonical tags marking a task "do not auto-drain — a human reviews first, and
# a worker runs it only after they remove the tag". `manual-only` is a synonym.
NEEDS_HUMAN_TAGS = {"needs-human", "manual-only"}

# operator-lifeline / self-modifying keywords. Matched against name+desc of a
# generated task (short, specific) — NOT against worker prompts.
_LIFELINE_HAY = (
    "telegram-mcp",
    "oauth-refresh",
    "oauth refresh",
    "claude auth",
    "claude-auth",
    "operator-watchdog",
    "operator watchdog",
    "operator restart",
    "restart-layer",
    "restart layer",
    "auto-compact",
    "auto compact",
    "claude-peers broker",
    "peers broker",
)

# reminder / task-meant-for-the-human signals.
_REMINDER_PREFIXES = ("reminder:", "self:")
_REMINDER_HAY = ("source:user", "self-task", "self task")

# Escape hatch for the operator-lifeline class. The lifeline heuristic protects
# the LIVE agent's life-support. A task that legitimately works ON a transport
# or restart layer as its subject matter — rather than on the running agent's
# own — tags itself `lifeline-exempt` and is judged on the remaining classes.
# Without this, any task whose scope merely names a lifeline component is stamped
# `needs-human` and silently waits for a human who has no reason to expect it.
_LIFELINE_EXEMPT_TAGS = {"lifeline-exempt"}


def _tagset(tags) -> set[str]:
    out = set()
    for t in tags or ():
        name = t.get("name") if isinstance(t, dict) else t
        if name:
            out.add(str(name))
    return out


def classify_risk(name: str, desc: str = "", tags=()) -> str | None:
    """Return the risk-class id of a task, or None if it is safe to auto-drain.

    Risk classes: 'tagged' | 'operator-lifeline' | 'reminder'. Call this at task
    GENERATION time to decide whether to stamp the `needs-human` tag; see the
    module docstring for why it does not belong in the launcher.
    """
    tagset = _tagset(tags)
    if tagset & NEEDS_HUMAN_TAGS:
        return "tagged"
    name_l = (name or "").strip().lower()
    hay = f"{name}\n{desc}".lower()

    if name_l.startswith(_REMINDER_PREFIXES) or any(k in hay for k in _REMINDER_HAY):
        return "reminder"
    if not (tagset & _LIFELINE_EXEMPT_TAGS) and any(k in hay for k in _LIFELINE_HAY):
        return "operator-lifeline"
    return None


def is_manual_gated(name: str, tags=()) -> bool:
    """Launcher enforcement gate: should pickable() SKIP this task?

    Purely tag-based — the canonical signal stamped by generators. Deliberately
    does NOT run the keyword heuristic above: that lives only at generation time
    so the gate stays releasable by removing the tag, and never misfires on a
    safe task that mentions a gated component in passing.

    `name` is accepted for call-site symmetry with classify_risk() and for
    logging; it is intentionally not matched against.
    """
    return bool(_tagset(tags) & NEEDS_HUMAN_TAGS)


if __name__ == "__main__":
    # CLI for bash callers: prints the risk class (or empty) given name + desc
    # + space/comma-separated tags.
    import argparse

    p = argparse.ArgumentParser(description="needs-human risk classifier")
    p.add_argument("--name", required=True)
    p.add_argument("--desc", default="")
    p.add_argument("--tags", default="", help="comma/space-separated tag names")
    p.add_argument(
        "--mode",
        choices=("classify", "gated"),
        default="classify",
        help="classify -> print risk class or empty; gated -> print 1/0",
    )
    a = p.parse_args()
    tag_list = [t for t in a.tags.replace(",", " ").split() if t]
    if a.mode == "gated":
        print("1" if is_manual_gated(a.name, tag_list) else "0")
    else:
        print(classify_risk(a.name, a.desc, tag_list) or "")
