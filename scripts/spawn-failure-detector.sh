#!/bin/bash
# spawn-failure-detector.sh — read-only probe for a CROSS-TASK worker spawn outage.
#
# WHY THIS EXISTS. A per-slug crash detector is a circuit breaker: it blocks a
# task only after the SAME slug crashes N times in a row. That is structurally
# blind to a host-level / CLI-level SPAWN outage, where MANY DIFFERENT tasks
# each fail to boot exactly ONCE. No slug ever reaches its streak threshold, so
# nothing trips.
#
# That failure class is SILENT by default: the worker-supervisor orphan-sweep
# resets each affected task back to `todo` and logs a line like
# "spawn-failed: claude never booted (no session-launched marker)" — and no
# alert fires. The fleet quietly stops doing real work while every individual
# signal still looks benign, and the outage is noticed hours later as a vague
# "why is nothing getting done".
#
# WHAT IT DOES. Scans the worker-errors log(s), counts DISTINCT slugs whose
# spawn failed within a rolling window, and alerts ONLY when a NEW cluster
# (>= THRESHOLD distinct slugs) appears — anchored on the newest event
# timestamp, so a standing cluster is not re-alerted on every tick (no flood).
# Likely causes are named in the alert (CLI auto-update broke a startup patch;
# host OOM/disk; tmux/PID-namespace issue).
#
# INPUT FORMAT. Lines in $ERRORS_DIR/*.log containing "spawn-failed", shaped as
#   YYYY-MM-DD HH:MM[:SS] | <slug> | <detail...>
# (pipe-separated; the first field is a wall-clock timestamp, the second the
# worker slug). This is what worker-supervisor.sh already writes.
#
# CONFIG (env):
#   AGENT_OS_HUB / REPO_ROOT      repo root (default /opt/agent-os/claude)
#   AGENT_OS_NOTIFY_HOOK          executable taking --source/--severity/--msg;
#                                 unset => detect-and-report only (stdout JSON)
#   SPAWN_FAILURE_MANIFEST        manifest path (default /var/lib/agent-os/spawn-failure.json)
#   SPAWN_FAILURE_WINDOW_HOURS    rolling window, default 24
#   SPAWN_FAILURE_THRESHOLD       distinct slugs that define an outage, default 3
#   SPAWN_DETECTOR_NO_NOTIFY=1    probe + manifest only, never notify (dry run/tests)
#
# Output: manifest JSON at $SPAWN_FAILURE_MANIFEST (carrying the cluster and
# last_alerted_event_ts, the dedup anchor) + a one-line JSON summary on stdout.
# Read-only apart from the manifest and one best-effort notification. Exit 0 always
# (a monitor must never flap the scheduler).
set -uo pipefail
REPO="${AGENT_OS_HUB:-${REPO_ROOT:-/opt/agent-os/claude}}"
ERRORS_DIR="${SPAWN_FAILURE_ERRORS_DIR:-$REPO/memory/worker-errors}"
# Optional alert hook. Unset => report-only (the probe still works).
NOTIFY="${AGENT_OS_NOTIFY_HOOK:-}"
MANIFEST="${SPAWN_FAILURE_MANIFEST:-/var/lib/agent-os/spawn-failure.json}"
# Rolling window (hours) and distinct-slug threshold that defines an OUTAGE.
# Normal spawn-failure rate is ~0; isolated singles days apart must NOT trip it.
WINDOW_HOURS="${SPAWN_FAILURE_WINDOW_HOURS:-24}"
THRESHOLD="${SPAWN_FAILURE_THRESHOLD:-3}"
[ ! -d "$ERRORS_DIR" ] && exit 0

python3 - "$ERRORS_DIR" "$NOTIFY" "$MANIFEST" "$WINDOW_HOURS" "$THRESHOLD" <<'PYEOF'
import datetime, json, os, pathlib, subprocess, sys

ERRORS_DIR, NOTIFY, MANIFEST, WINDOW_H, THRESH_S = sys.argv[1:6]
WINDOW = datetime.timedelta(hours=float(WINDOW_H))
THRESHOLD = int(THRESH_S)
now = datetime.datetime.now()  # naive local wall clock; log ts are wall clock too

# ---- collect recent spawn-failure events from the rolling log files ----------
# Read the two most recent monthly logs (a window can straddle a month boundary).
files = sorted(pathlib.Path(ERRORS_DIR).glob("*.log"), reverse=True)[:2]
events = []  # (datetime, slug)
for f in files:
    for line in f.read_text(errors="ignore").splitlines():
        if "spawn-failed" not in line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 2:
            continue
        ts_raw, slug = parts[0], parts[1]
        try:
            dt = datetime.datetime.strptime(ts_raw[:16], "%Y-%m-%d %H:%M")
        except ValueError:
            continue
        events.append((dt, slug))

# Events inside the window; one count per DISTINCT slug (cross-task, not streak).
windowed = [(dt, slug) for dt, slug in events if now - dt <= WINDOW]
by_slug = {}
for dt, slug in windowed:
    if slug not in by_slug or dt > by_slug[slug]:
        by_slug[slug] = dt
distinct = sorted(by_slug.items(), key=lambda kv: kv[1])
newest_ts = max((dt for dt, _ in windowed), default=None)
is_outage = len(by_slug) >= THRESHOLD

# ---- load previous manifest for the dedup anchor -----------------------------
prev = {}
try:
    with open(MANIFEST) as fh:
        prev = json.load(fh) or {}
except (OSError, json.JSONDecodeError):
    prev = {}
last_alerted = prev.get("last_alerted_event_ts")

# Alert only when an outage is present AND its newest event is newer than the
# last cluster we already alerted on (so a standing cluster is not re-flooded).
newest_iso = newest_ts.strftime("%Y-%m-%d %H:%M") if newest_ts else None
fresh = is_outage and (last_alerted is None or (newest_iso and newest_iso > last_alerted))

manifest = {
    "ts": now.strftime("%Y-%m-%dT%H:%M:%S"),
    "window_hours": float(WINDOW_H),
    "threshold": THRESHOLD,
    "distinct_slugs": len(by_slug),
    "is_outage": is_outage,
    "newest_event_ts": newest_iso,
    "cluster": [f"{dt.strftime('%Y-%m-%d %H:%M')} {slug}" for slug, dt in distinct],
    # carry forward the dedup anchor; bump it only when we actually alert below
    "last_alerted_event_ts": last_alerted,
}

notify_ok = bool(NOTIFY) and not os.environ.get("SPAWN_DETECTOR_NO_NOTIFY")
if fresh:
    lines = [
        f"[spawn-failure] {len(by_slug)} distinct workers failed to BOOT in the last "
        f"{WINDOW_H}h (threshold {THRESHOLD}) — a host/spawn-infra outage, NOT a per-task crash.",
        "A per-slug crash detector is BLIND to this (each slug failed only once).",
    ]
    for slug, dt in distinct:
        lines.append(f"  • {dt.strftime('%m-%d %H:%M')} {slug} — the agent CLI never booted")
    lines.append(
        "likely cause: the CLI auto-updated and a startup patch needs re-applying; "
        "OR host OOM/disk exhaustion; OR a tmux / PID-namespace issue.")
    lines.append(
        "check: tmux capture-pane -t worker-<slug> -p | tail (startup dialog?) ; "
        "CLI version vs last patch ; journalctl for OOM. Each task was orphan-reset to todo.")
    msg = "\n".join(lines)
    if notify_ok:
        subprocess.run([NOTIFY, "--source", "spawn-failure", "--severity", "error",
                        "--msg", msg], check=False)
    else:
        print(msg, file=sys.stderr)
    manifest["last_alerted_event_ts"] = newest_iso

try:
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(manifest, fh, indent=2)
    os.replace(tmp, MANIFEST)
except OSError as e:
    print(f"spawn-failure-detector: could not write manifest {MANIFEST}: {e}", file=sys.stderr)

print(json.dumps({
    "distinct_slugs": len(by_slug),
    "is_outage": is_outage,
    "fresh": bool(fresh),
    "alerted": bool(fresh and notify_ok),
    "cluster": manifest["cluster"],
}))
PYEOF
exit 0
