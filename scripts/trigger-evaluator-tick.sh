#!/bin/bash
# trigger-evaluator-tick.sh — DAG entry point for event-driven trigger evaluation.
#
# Reads every trigger YAML file from memory/triggers/, queries the event bus for
# each enabled trigger, and creates a task when the condition is met.
#
# Composable trigger architecture:
#   event-source-watcher  ->  event-bus.db  ->  trigger-evaluator  ->  task
#
# Token-free: pure bash + Python, no LLM is invoked. Idempotency comes from
# scripts/lib/clickup_upsert.py (key `gen:trigger-evaluator` + `key:<tid>`),
# so a re-run updates the existing task instead of creating a duplicate.
#
# Task routing is deployment-specific and comes from the environment — nothing
# is hardcoded here:
#   AGENTOS_TRIGGER_LIST_MAP      JSON object mapping an epic name to a target
#                                 list id, e.g.
#                                 '{"Research":"1234","Scheduled Checks":"5678"}'
#   AGENTOS_TRIGGER_DEFAULT_LIST  list id used when a trigger's epic_name is not
#                                 in the map (optional; without it, unmapped
#                                 triggers are skipped with a warning)

set -uo pipefail

REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TRIGGERS_DIR="$REPO/memory/triggers"
EVENT_BUS="$REPO/scripts/event-bus.py"
UPSERT="$REPO/scripts/lib/clickup_upsert.py"

[ ! -d "$TRIGGERS_DIR" ] && { echo "no triggers dir"; exit 0; }

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 - "$TRIGGERS_DIR" "$EVENT_BUS" "$UPSERT" "$NOW_ISO" <<'PYEOF'
import datetime, json, os, pathlib, subprocess, sys
import yaml

TRIGGERS_DIR, EVENT_BUS, UPSERT, NOW_ISO = sys.argv[1:5]

# Epic name -> target list id. Deployment-specific, supplied via env.
try:
    LIST_BY_EPIC = json.loads(os.environ.get("AGENTOS_TRIGGER_LIST_MAP", "{}"))
except ValueError as e:
    print(f"AGENTOS_TRIGGER_LIST_MAP is not valid JSON: {e}")
    LIST_BY_EPIC = {}
DEFAULT_LIST = os.environ.get("AGENTOS_TRIGGER_DEFAULT_LIST", "")

PRIO_NUM = {"critical": 1, "high": 2, "medium": 3, "low": 4}
now = datetime.datetime.strptime(NOW_ISO, "%Y-%m-%dT%H:%M:%SZ")

TRIGGER_FILES = sorted(pathlib.Path(TRIGGERS_DIR).glob("*.yaml"))

for tf in TRIGGER_FILES:
    if tf.name == "README.md":
        continue

    try:
        rule = yaml.safe_load(tf.read_text())
    except Exception as e:
        print(f"skip {tf.name}: parse error: {e}")
        continue

    if not rule or not rule.get("enabled", False):
        continue

    tid         = rule["id"]
    source      = rule["source"]
    condition   = rule.get("condition", {})
    metric      = condition.get("metric")
    op_str      = condition.get("op", ">=")
    threshold   = float(condition.get("threshold", 0))
    aggregate   = condition.get("aggregate", "max")   # max | latest | count
    window_h    = float(condition.get("time_window_hours", 1))
    debounce_m  = float(rule.get("debounce_minutes", 60))
    action      = rule.get("action", {})

    if not metric:
        print(f"skip {tid}: no metric defined")
        continue

    # --- Debounce check ---
    fired_at_raw = subprocess.run(
        ["python3", EVENT_BUS, "fired-at", tid],
        capture_output=True, text=True
    ).stdout.strip()

    if fired_at_raw and fired_at_raw != "null":
        try:
            fired_dt = datetime.datetime.strptime(fired_at_raw, "%Y-%m-%dT%H:%M:%SZ")
            age_m = (now - fired_dt).total_seconds() / 60
            if age_m < debounce_m:
                print(f"skip {tid}: debounce ({age_m:.0f}m < {debounce_m}m)")
                continue
        except ValueError:
            pass

    # --- Query event bus ---
    if aggregate == "count":
        raw = subprocess.run(
            ["python3", EVENT_BUS, "count", source, metric, "--hours", str(window_h)],
            capture_output=True, text=True
        ).stdout.strip()
        try:
            agg_value = float(raw)
        except ValueError:
            print(f"skip {tid}: invalid count output: {raw!r}")
            continue

    elif aggregate == "latest":
        raw = subprocess.run(
            ["python3", EVENT_BUS, "latest", source, metric],
            capture_output=True, text=True
        ).stdout.strip()
        if raw == "null" or not raw:
            print(f"skip {tid}: no events (latest)")
            continue
        try:
            evt = json.loads(raw)
            # For 'latest', also check that the event is within the time window
            evt_dt = datetime.datetime.strptime(evt["ts"], "%Y-%m-%dT%H:%M:%SZ")
            age_h = (now - evt_dt).total_seconds() / 3600
            if age_h > window_h:
                print(f"skip {tid}: latest event too old ({age_h:.1f}h > {window_h}h)")
                continue
            agg_value = float(evt["value"]) if evt.get("value") is not None else None
        except (ValueError, KeyError) as e:
            print(f"skip {tid}: parse error: {e}")
            continue

    else:  # aggregate == "max" (default)
        raw = subprocess.run(
            ["python3", EVENT_BUS, "max", source, metric, "--hours", str(window_h)],
            capture_output=True, text=True
        ).stdout.strip()
        if raw == "null" or not raw:
            print(f"skip {tid}: no events in window (max)")
            continue
        try:
            agg_value = float(raw)
        except ValueError:
            print(f"skip {tid}: invalid max output: {raw!r}")
            continue

    if agg_value is None:
        print(f"skip {tid}: null value")
        continue

    # --- Evaluate condition ---
    OPS = {
        ">=": lambda a, b: a >= b,
        "<=": lambda a, b: a <= b,
        ">":  lambda a, b: a > b,
        "<":  lambda a, b: a < b,
        "==": lambda a, b: a == b,
        "!=": lambda a, b: a != b,
    }
    check = OPS.get(op_str)
    if check is None:
        print(f"skip {tid}: unknown op {op_str!r}")
        continue

    if not check(agg_value, threshold):
        print(f"skip {tid}: condition not met ({agg_value} {op_str} {threshold} = False)")
        continue

    # --- Condition met: create the task (idempotent upsert) ---
    print(f"FIRE {tid}: {agg_value} {op_str} {threshold} OK")

    title       = action.get("title", f"Triggered: {tid}")
    epic_name   = action.get("epic_name", "")
    priority    = action.get("priority", "medium")
    description = action.get("description", f"Trigger {tid} fired at {NOW_ISO}").strip()

    list_id = LIST_BY_EPIC.get(epic_name, DEFAULT_LIST)
    if not list_id:
        print(f"  skip {tid}: no list id for epic {epic_name!r} "
              f"(set AGENTOS_TRIGGER_LIST_MAP / AGENTOS_TRIGGER_DEFAULT_LIST)")
        continue
    prio = str(PRIO_NUM.get(priority, 3))

    res = subprocess.run(
        ["python3", UPSERT, "upsert",
         "--list-id", list_id, "--gen", "trigger-evaluator", "--key", tid,
         "--title", title, "--desc", description, "--priority", prio,
         "--tag", "triggered", "--tag", f"source:{tid}"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        print(f"  upsert failed for {tid}: {res.stderr.strip()}")
    else:
        print(f"  upserted task '{title}' -> {res.stdout.strip()}")

    # Record the fire time for debounce
    subprocess.run(
        ["python3", EVENT_BUS, "set-fired", tid, NOW_ISO, str(agg_value)],
        check=False,
    )

print("trigger-evaluator-tick done")
PYEOF

exit 0
