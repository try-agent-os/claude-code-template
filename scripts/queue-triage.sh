#!/bin/bash
# queue-triage.sh — read-only triage of the ClickUp todo backlog by its
# DRAIN-EXECUTABILITY, not by priority.
#
# WHY THIS EXISTS. Two independent rules decide whether a queued task ever
# moves:
#   - the launcher picks up ONLY tasks carrying the `auto-worker` tag;
#   - the drain safety-gate (scripts/lib/needs_human.py) SKIPS anything tagged
#     `needs-human`, surfacing it to a person instead.
# A task carrying NEITHER tag is in LIMBO: no worker will ever pick it AND it is
# never surfaced to a human. Each such task looks perfectly healthy on its own —
# sensible title, sitting quietly in `todo`. Only the AGGREGATE reveals the rot.
#
# This is not hypothetical: on the instance this probe was written for, a live
# count showed 100 todo / 19 auto-worker / 20 needs-human — i.e. 61 tasks, 61%
# of the backlog, structurally un-executable. Every one of them had been filed
# either before the tag-gate existed or by a generator that does not stamp the
# tag. The needs_human design is "stamped by generators PLUS backfill"; the
# backfill half is easy to never build. This probe is that missing half's eyes.
#
# It does NOT mutate anything. For every limbo task it runs the canonical policy
# (scripts/lib/needs_human.classify_risk — the SAME function task creation uses
# to decide the gate) and RECOMMENDS one of:
#   - needs-human : the task hits a risk class (operator-lifeline / reminder /
#                   public-pr ...) → must stay human-gated, surface it.
#   - auto-worker : the classifier returns None → safe to auto-drain.
# APPLYING those recommendations is deliberately a separate, human-gated step.
# Adding `needs-human` is trivially reversible and can never *cause* a run,
# whereas mass-adding `auto-worker` would unleash N workers at once — that half
# should never be automated behind someone's back.
#
# CONFIG (env):
#   AGENT_OS_HUB / REPO_ROOT     repo root (default /opt/agent-os/claude)
#   CLICKUP_API_TOKEN            ClickUp API token (required)
#   CLICKUP_TEAM_ID              ClickUp team/workspace id (required)
#   CLICKUP_SPACE_ID             space to triage (required)
#   QUEUE_TRIAGE_STATUSES        comma-separated statuses, default `todo`
#   QUEUE_TRIAGE_MANIFEST        manifest path (default /var/lib/agent-os/queue-triage.json)
#
# Output: manifest JSON at $QUEUE_TRIAGE_MANIFEST + a human digest on stdout.
# Read-only, idempotent, safe to run from a routine.
set -uo pipefail
REPO="${AGENT_OS_HUB:-${REPO_ROOT:-/opt/agent-os/claude}}"
MANIFEST="${QUEUE_TRIAGE_MANIFEST:-/var/lib/agent-os/queue-triage.json}"
STATUSES="${QUEUE_TRIAGE_STATUSES:-todo}"

# Credentials/ids are instance-specific — no sensible default exists, so fail
# loudly rather than silently triaging the wrong workspace.
TOKEN="${CLICKUP_API_TOKEN:-}"
TEAM_ID="${CLICKUP_TEAM_ID:-}"
SPACE_ID="${CLICKUP_SPACE_ID:-}"
for _v in TOKEN:CLICKUP_API_TOKEN TEAM_ID:CLICKUP_TEAM_ID SPACE_ID:CLICKUP_SPACE_ID; do
  _name="${_v%%:*}"; _env="${_v##*:}"
  if [ -z "${!_name}" ]; then
    echo "queue-triage: $_env is not set — cannot triage" >&2
    exit 2
  fi
done

# Build the statuses query string (statuses%5B%5D=todo&statuses%5B%5D=...).
QS=""
IFS=',' read -ra _ST <<<"$STATUSES"
for s in "${_ST[@]}"; do QS+="&statuses%5B%5D=${s}"; done

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT
curl -s --max-time 20 -H "Authorization: $TOKEN" \
  "https://api.clickup.com/api/v2/team/${TEAM_ID}/task?space_ids%5B%5D=${SPACE_ID}&include_closed=false&page=0${QS}" \
  >"$RESP_FILE"

# Data is handed to python via a FILE arg (argv), never stdin: `python3 - <<EOF`
# already binds stdin to the heredoc program, so a piped body would be invisible.
python3 - "$REPO" "$MANIFEST" "$STATUSES" "$RESP_FILE" <<'PYEOF'
import json, os, sys, datetime
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "lib"))
from needs_human import classify_risk, is_manual_gated

MANIFEST = sys.argv[2]
STATUSES = sys.argv[3]
RESP_FILE = sys.argv[4]

with open(RESP_FILE) as _f:
    raw = _f.read().strip()
try:
    data = json.loads(raw)
except Exception as e:
    print(f"queue-triage: bad ClickUp response: {e}", file=sys.stderr)
    sys.exit(1)
tasks = data.get("tasks", [])

def tagnames(t):
    return [x.get("name") if isinstance(x, dict) else x for x in t.get("tags", [])]

# Buckets mirror the LAUNCHER's reality (is_manual_gated wins over auto-worker):
#   gated    — is_manual_gated True: the launcher SKIPS it and it is surfaced to
#              a human. This is the HEALTHY state for a risk task.
#   flowing  — auto-worker AND not gated: the only state a worker will pick.
#   conflict — auto-worker AND gated: tag contradiction. The gate wins, so it
#              will NOT drain; the auto-worker tag is misleading dead weight
#              (smells like a generator stamping both). Informational, not urgent.
#   limbo    — neither auto-worker nor gated: the silent rot. No worker picks it,
#              no human ever sees it. classify_risk recommends the missing tag.
flowing, gated, conflict, limbo = [], [], [], []
to_nh, to_aw = [], []
for t in tasks:
    tags = tagnames(t)
    name = t.get("name") or ""
    has_aw = "auto-worker" in tags
    is_gated = is_manual_gated(name, tags)
    short = {"id": t["id"], "name": name[:80], "list": (t.get("list") or {}).get("name", "?")}
    if is_gated and has_aw:
        conflict.append(short)
    elif is_gated:
        gated.append(short)
    elif has_aw:
        flowing.append(short)
    else:
        limbo.append(short)
        desc = t.get("text_content") or t.get("description") or ""
        risk = classify_risk(name, desc, tags)
        rec = dict(short, risk_class=risk)
        if risk:
            to_nh.append(rec)
        else:
            to_aw.append(rec)

now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
manifest = {
    "generated_at": now,
    "statuses": STATUSES,
    "totals": {
        "tasks": len(tasks),
        "flowing": len(flowing),       # auto-worker, not gated — a worker will pick it
        "gated": len(gated),           # needs-human — surfaced to a person, won't drain
        "conflict": len(conflict),     # auto-worker + needs-human — gated wins, aw is dead weight
        "limbo": len(limbo),           # no tag — silent: no worker, never surfaced
    },
    "conflict_tasks": conflict,
    "limbo_recommendations": {
        "to_needs_human": to_nh,    # hits a risk class — surface, keep gated
        "to_auto_worker": to_aw,    # classifier says safe — eligible to drain
    },
}
try:
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    with open(MANIFEST, "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f"queue-triage: could not write manifest {MANIFEST}: {e}", file=sys.stderr)

# ── human digest ──────────────────────────────────────────────────────────
tot = manifest["totals"]
pct = (100 * tot["limbo"] // tot["tasks"]) if tot["tasks"] else 0
print(f"queue-triage [{STATUSES}] @ {now}")
print(f"  total={tot['tasks']}  flowing={tot['flowing']}  gated={tot['gated']}  "
      f"conflict={tot['conflict']}  LIMBO={tot['limbo']} ({pct}%)")
print(f"  limbo → recommend needs-human: {len(to_nh)}  |  recommend auto-worker: {len(to_aw)}")
if conflict:
    print("  --- CONFLICT: auto-worker + needs-human (gated wins, aw is dead weight) ---")
    for r in conflict[:10]:
        print(f"    {r['id']} {r['name']}")
    if len(conflict) > 10:
        print(f"    ... +{len(conflict)-10} more")
if to_nh:
    print("  --- limbo that should be GATED (risk class) ---")
    for r in to_nh:
        print(f"    {r['id']} [{r['risk_class']}] {r['name']}")
if to_aw:
    print("  --- limbo SAFE to auto-worker (would drain on tag) ---")
    for r in to_aw[:40]:
        print(f"    {r['id']} {r['name']}")
    if len(to_aw) > 40:
        print(f"    ... +{len(to_aw)-40} more")
PYEOF
