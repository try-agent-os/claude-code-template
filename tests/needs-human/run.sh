#!/usr/bin/env bash
# needs_human drain safety-gate test runner. Usage:
#   tests/needs-human/run.sh        # exit 0 if all pass, 1 if any fail
#   tests/needs-human/run.sh -v     # verbose (print every case)
#
# WHY THIS EXISTS: this gate decides whether the autonomous queue hands a task to
# a worker or holds it for a human. Both of its failure modes are SILENT:
#
#   - Over-gating: a class of tasks stops draining. Nothing crashes, nothing logs
#     an error, no health check goes red — the queue just quietly stops picking
#     them up, and the backlog is only noticed weeks later. We shipped exactly
#     this once, by matching on task NAME instead of the tag.
#   - Under-gating: a task that needed a human goes to a worker instead, and the
#     first sign of trouble is the damage.
#
# Neither shows up in a monitor, so the policy is pinned by tests and run on
# every PR. The two directions locked below:
#   1. the tag is the ONLY enforcement signal, so removing it always releases a
#      reviewed task;
#   2. the operator-lifeline and reminder classes still catch at generation time.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PYTHONPATH="$REPO_ROOT/scripts/lib" VERBOSE="$VERBOSE" python3 - <<'PY'
import os, sys
import needs_human as nh

VERBOSE = os.environ.get("VERBOSE") == "1"
fails = []


def case(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got={got!r} want={want!r}")
    if VERBOSE or not ok:
        print(("  ok   " if ok else "  FAIL ") + label)


# --- 1. the tag is the ONE enforcement signal --------------------------------
case("gate: needs-human tag gates",
     nh.is_manual_gated("Refactor the restart layer", ["needs-human", "auto-worker"]), True)
case("gate: manual-only synonym gates",
     nh.is_manual_gated("whatever", ["manual-only"]), True)
case("gate: untagged safe task drains",
     nh.is_manual_gated("Fix worker-supervisor state dir", ["auto-worker"]), False)
case("gate: dict-shaped tags (backend API shape) gate",
     nh.is_manual_gated("x", [{"name": "needs-human"}]), True)
case("gate: no tags at all drains",
     nh.is_manual_gated("Fix worker-supervisor state dir"), False)
# A reviewed task must be releasable by removing the tag ALONE. A gate that also
# matched the name could never release it — the name still matches, so the task
# re-blocks forever. That bug froze a whole class of tasks for weeks.
case("gate: untagging a lifeline-named task actually releases it",
     nh.is_manual_gated("Refactor telegram-mcp reply-guard", ["auto-worker"]), False)
case("gate: enforcement ignores the keyword heuristic entirely",
     nh.is_manual_gated("Reminder: pay the invoice", ["auto-worker"]), False)
# The gate is name-agnostic in BOTH directions: no name can gate an untagged
# task, and no name can exempt a tagged one. The launcher relies on this to gate
# system `Scheduled:` tasks with the same rule as everything else — a gate with
# an exception is not a gate, and the exception would be silent.
case("gate: a tagged 'Scheduled:' system task is gated like any other",
     nh.is_manual_gated("Scheduled: nightly backlog sweep", ["needs-human"]), True)

# --- 2. generation-time classes that MUST catch ------------------------------
case("classify: telegram-mcp is lifeline",
     nh.classify_risk("Refactor telegram-mcp reply-guard", "", []), "operator-lifeline")
case("classify: claude auth is lifeline",
     nh.classify_risk("Fix claude auth token refresh", "", []), "operator-lifeline")
case("classify: peers broker is lifeline",
     nh.classify_risk("Restart claude-peers broker", "", []), "operator-lifeline")
case("classify: lifeline keyword in DESC (not name) still catches",
     nh.classify_risk("Tidy up a helper", "touches the operator-watchdog unit", []), "operator-lifeline")
case("classify: 'Reminder:' prefix is reminder",
     nh.classify_risk("Reminder: renew the domain", "", []), "reminder")
case("classify: 'self:' prefix is reminder",
     nh.classify_risk("self: call the accountant", "", []), "reminder")
case("classify: source:user is reminder",
     nh.classify_risk("Move domains", "source:user", []), "reminder")
case("classify: explicit needs-human tag wins",
     nh.classify_risk("anything at all", "", ["needs-human"]), "tagged")
case("classify: plain internal task is safe",
     nh.classify_risk("Fix worker-supervisor state dir", "", []), None)

# --- 3. lifeline exemption ---------------------------------------------------
# A task whose SUBJECT is a transport is not the running agent's own lifeline.
case("classify: lifeline-exempt tag exempts from lifeline",
     nh.classify_risk("receiver telegram-mcp transport", "", ["lifeline-exempt"]), None)
case("classify: exempt tag does NOT exempt reminder",
     nh.classify_risk("Reminder: ping the client", "", ["lifeline-exempt"]), "reminder")

if fails:
    print(f"\nFAILED {len(fails)}:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("needs-human: all cases passed")
sys.exit(0)
PY
