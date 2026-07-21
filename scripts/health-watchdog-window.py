#!/usr/bin/env python3
"""health-watchdog-window — crash metrics over the window the watchdog ACTUALLY covers.

Failure class this exists for ("a metric that is vacuous by construction"):
the watchdog computed crash_rate/max_iter_rate/crash_streak over a HARDCODED
"last 2 hours" window. That constant was chosen when the caller fired every
30 min. Once the strategist moved to a daily schedule (routines/strategist.yaml),
the window only ever covered the two quiet hours right before the run — so the
metric was measuring an interval that by construction contained almost no
events, and reported crash_rate=0 run after run while real crash-loops were
happening OUTSIDE the window and being discarded as "stale".

A hardcoded window is not just imprecise, it is silently wrong the moment the
schedule changes, and nothing in the output says so.

Second, reinforcing layer: the strategist may run from a git worktree, while
the monthly logs under memory/worker-errors/ and memory/worker-activity/ are
gitignored. If an OLD month's log was committed before that rule and a newer
one was not, the directory in a worktree looks populated (two plausible files),
the current month is simply absent, no file-not-found is raised, and every
metric computes to zero in silence.

Three fixes, one file:
  1. WINDOW = "events since the previous watchdog run", timestamp taken from the
     last line of logs/health/watchdog.log. The window self-tunes to the real
     cadence and does not shatter at the next schedule change.
  2. PATHS are absolute against the main checkout (REPO_ROOT, default: the
     parent of this script's directory), never relative to the caller's cwd —
     a run from a worktree reads the same data as a run from the main checkout.
  3. ZERO IS AN ALARM: a missing or empty current-month log while the previous
     month is non-empty exits non-zero with an ALARM line, instead of a quiet 0.

Log formats consumed (as written by scripts/worker-supervisor.sh and
scripts/spawn-worker.sh):
  memory/worker-errors/YYYY-MM.log     "<ts> | <slug> | crashed: ... | ..."
  memory/worker-activity/YYYY-MM.log   "[<ts>] worker <slug> started (...)"

Exit codes:
  0  healthy — no anomaly over the window
  1  anomaly — crash_streak >= 3, or a rate over threshold (escalate)
  2  ALARM   — data-integrity failure (log absent/empty where data is expected);
              the metrics below cannot be trusted, do NOT report green

Usage:
  scripts/health-watchdog-window.py                    # human summary
  scripts/health-watchdog-window.py --json             # machine-readable
  scripts/health-watchdog-window.py --since 2026-01-13T00:00 --now 2026-01-15T00:00
                                                       # replay a past window
  scripts/health-watchdog-window.py --log-line         # emit the watchdog.log line
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

REPO = os.environ.get(
    "REPO_ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
ERRORS_DIR = os.path.join(REPO, "memory", "worker-errors")
ACTIVITY_DIR = os.path.join(REPO, "memory", "worker-activity")
WATCHDOG_LOG = os.path.join(REPO, "logs", "health", "watchdog.log")

# Fallback window when watchdog.log carries no parseable timestamp (first run,
# truncated log). Deliberately wide: over-reporting is recoverable, the silent
# zero this file exists to kill is not.
FALLBACK_WINDOW_HOURS = 24

CRASH_STREAK_THRESHOLD = 3
RATE_THRESHOLD = 0.40
ZOMBIE_RATE_THRESHOLD = 0.30

# "2026-01-13 15:50 | some-task-slug | crashed: orphan reset (...) | ..."
ERROR_LINE = re.compile(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2})\s*\|\s*([^|]+?)\s*\|\s*(.*)$")
# "[2026-01-21 05:05] worker some-task-slug started (task=..., ...)"
ACTIVITY_START = re.compile(r"^\[(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2})\]\s+worker\s+(\S+)\s+started\b")
# leading timestamp of a watchdog.log line, either "2026-01-11 05:04" or ISO8601
WATCHDOG_TS = re.compile(r"^(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?)(Z|[+-]\d{2}:?\d{2})?")


def parse_ts(raw: str, offset: str | None = None) -> datetime | None:
    """Parse the timestamp shapes that appear in these logs, always tz-aware (UTC)."""
    text = raw.strip().replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            naive = datetime.strptime(text, fmt)
            break
        except ValueError:
            continue
    else:
        return None
    if offset in (None, "", "Z"):
        return naive.replace(tzinfo=timezone.utc)
    sign = 1 if offset[0] == "+" else -1
    body = offset[1:].replace(":", "")
    delta = timedelta(hours=int(body[:2]), minutes=int(body[2:4]))
    return naive.replace(tzinfo=timezone.utc) - sign * delta


def month_keys(start: datetime, end: datetime) -> list[str]:
    """Every YYYY-MM the window touches — a window may straddle a month rotation."""
    keys, cursor = [], start.replace(day=1)
    while cursor <= end:
        keys.append(cursor.strftime("%Y-%m"))
        cursor = (cursor.replace(day=28) + timedelta(days=7)).replace(day=1)
    end_key = end.strftime("%Y-%m")
    if end_key not in keys:
        keys.append(end_key)
    return keys


def prev_month_key(key: str) -> str:
    year, month = (int(part) for part in key.split("-"))
    return f"{year - 1}-12" if month == 1 else f"{year}-{month - 1:02d}"


def read_lines(path: str) -> list[str]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


def last_watchdog_run() -> tuple[datetime | None, str]:
    """Timestamp of the previous watchdog run — the real lower bound of the window."""
    lines = read_lines(WATCHDOG_LOG)
    for line in reversed(lines):
        match = WATCHDOG_TS.match(line.strip())
        if match:
            stamp = parse_ts(match.group(1), match.group(2))
            if stamp:
                return stamp, "watchdog.log"
    return None, "fallback"


def integrity_check(now: datetime) -> list[str]:
    """Zero is an alarm: an absent/empty current month next to a populated previous
    month is the worktree-blindness signature, not a quiet system."""
    alarms = []
    current = now.strftime("%Y-%m")
    previous = prev_month_key(current)
    for label, directory in (("worker-errors", ERRORS_DIR), ("worker-activity", ACTIVITY_DIR)):
        if not os.path.isdir(directory):
            alarms.append(f"{label}: directory {directory} does not exist")
            continue
        current_path = os.path.join(directory, f"{current}.log")
        previous_path = os.path.join(directory, f"{previous}.log")
        current_lines = read_lines(current_path)
        previous_lines = read_lines(previous_path)
        if current_lines:
            continue
        state = "missing" if not os.path.exists(current_path) else "empty"
        if previous_lines:
            alarms.append(
                f"{label}: {current}.log {state} while {previous}.log has "
                f"{len(previous_lines)} lines — metrics would be a silent zero "
                f"(cwd={os.getcwd()}, reading {directory})"
            )
    return alarms


def collect(start: datetime, end: datetime) -> dict:
    keys = month_keys(start, end)

    errors = []
    for key in keys:
        for line in read_lines(os.path.join(ERRORS_DIR, f"{key}.log")):
            match = ERROR_LINE.match(line)
            if not match:
                continue
            stamp = parse_ts(match.group(1))
            if stamp and start <= stamp <= end:
                errors.append({"ts": stamp, "slug": match.group(2), "detail": match.group(3)})
    errors.sort(key=lambda event: event["ts"])

    starts = 0
    for key in keys:
        for line in read_lines(os.path.join(ACTIVITY_DIR, f"{key}.log")):
            match = ACTIVITY_START.match(line)
            if not match:
                continue
            stamp = parse_ts(match.group(1))
            if stamp and start <= stamp <= end:
                starts += 1

    crashed = sum(1 for e in errors if "crashed" in e["detail"])
    zombie = sum(1 for e in errors if "zombie" in e["detail"])
    max_iter = sum(1 for e in errors if "MAX_ITERATIONS" in e["detail"])

    # crash_streak: consecutive crash/zombie events per slug. auto-blocked is an
    # intervention, so it breaks the streak — otherwise one long loop reads as a
    # single unbroken run and the count stops meaning "unattended repetition".
    streaks: dict[str, int] = {}
    running: dict[str, int] = {}
    for event in errors:
        slug, detail = event["slug"], event["detail"]
        if "crashed" in detail or "zombie" in detail:
            running[slug] = running.get(slug, 0) + 1
            streaks[slug] = max(streaks.get(slug, 0), running[slug])
        elif "auto-blocked" in detail:
            running[slug] = 0

    # Workers that started is the honest denominator; if activity is silent but
    # errors are not, fall back to the error count so the rate never divides by
    # a zero that only means "the activity log did not reach us".
    total = starts if starts else len({(e["slug"], e["ts"]) for e in errors})

    def rate(count: int) -> float:
        return round(count / total, 3) if total else 0.0

    return {
        "total_workers": total,
        "worker_starts": starts,
        "error_events": len(errors),
        "crashed": crashed,
        "zombie": zombie,
        "max_iter": max_iter,
        "crash_rate": rate(crashed + zombie),
        "zombie_rate": rate(zombie),
        "max_iter_rate": rate(max_iter),
        "crash_streak": streaks,
        "worst_streak": max(streaks.values(), default=0),
        "worst_streak_slug": max(streaks, key=lambda s: streaks[s], default=None) if streaks else None,
    }


def anomalies(metrics: dict) -> list[dict]:
    found = []
    for slug, streak in sorted(metrics["crash_streak"].items(), key=lambda kv: -kv[1]):
        if streak >= CRASH_STREAK_THRESHOLD:
            found.append({"type": "crash_streak", "details": slug, "value": streak,
                          "threshold": CRASH_STREAK_THRESHOLD})
    for key, threshold in (("crash_rate", RATE_THRESHOLD), ("max_iter_rate", RATE_THRESHOLD),
                           ("zombie_rate", ZOMBIE_RATE_THRESHOLD)):
        if metrics["total_workers"] and metrics[key] >= threshold:
            found.append({"type": key, "details": "window aggregate",
                          "value": metrics[key], "threshold": threshold})
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--since", help="override window start (ISO, replay/testing)")
    parser.add_argument("--now", help="override window end (ISO, replay/testing)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--log-line", action="store_true",
                        help="print the line to append to logs/health/watchdog.log")
    args = parser.parse_args()

    end = parse_ts(args.now) if args.now else datetime.now(timezone.utc)
    if end is None:
        print(f"ALARM: unparseable --now value {args.now!r}", file=sys.stderr)
        return 2

    if args.since:
        start, source = parse_ts(args.since), "--since"
        if start is None:
            print(f"ALARM: unparseable --since value {args.since!r}", file=sys.stderr)
            return 2
    else:
        start, source = last_watchdog_run()
        if start is None:
            start = end - timedelta(hours=FALLBACK_WINDOW_HOURS)

    alarms = integrity_check(end)
    metrics = collect(start, end)
    found = anomalies(metrics)
    window_hours = round((end - start).total_seconds() / 3600, 1)

    payload = {
        "window": {"since": start.isoformat(), "until": end.isoformat(),
                   "hours": window_hours, "source": source},
        "repo_root": REPO,
        "metrics": metrics,
        "anomalies": found,
        "alarms": alarms,
    }

    if args.json:
        print(json.dumps(payload, indent=2, default=str))
    elif args.log_line:
        state = "ALARM" if alarms else ("ANOMALY" if found else "OK")
        detail = "; ".join(alarms) if alarms else " ".join(
            f"{a['type']}={a['value']}({a['details']})" for a in found) or "-"
        print(f"{end.isoformat()} | {state} | window={window_hours}h(since {start.isoformat()}, {source}) "
              f"workers={metrics['total_workers']} crash_rate={metrics['crash_rate']} "
              f"max_iter_rate={metrics['max_iter_rate']} worst_streak={metrics['worst_streak']}"
              f"({metrics['worst_streak_slug'] or '-'}) | {detail}")
    else:
        print(f"WINDOW {start.isoformat()} .. {end.isoformat()}  ({window_hours}h, source={source})")
        print(f"ROOT   {REPO}  (cwd={os.getcwd()})")
        print(f"METRICS workers={metrics['total_workers']} errors={metrics['error_events']} "
              f"crashed={metrics['crashed']} zombie={metrics['zombie']} max_iter={metrics['max_iter']}")
        print(f"RATES  crash_rate={metrics['crash_rate']} zombie_rate={metrics['zombie_rate']} "
              f"max_iter_rate={metrics['max_iter_rate']}")
        for slug, streak in sorted(metrics["crash_streak"].items(), key=lambda kv: -kv[1]):
            print(f"STREAK {slug} = {streak}")
        for alarm in alarms:
            print(f"ALARM  {alarm}")
        for item in found:
            print(f"ANOMALY {item['type']} = {item['value']} (threshold {item['threshold']}) "
                  f"-> {item['details']}")
        if not alarms and not found:
            print("OK     no anomaly over the window")

    if alarms:
        return 2
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
