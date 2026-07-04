#!/usr/bin/env bash
# dagu-recent-failures.sh — list ONLY genuine, recent Dagu DAG failures.
#
# WHY THIS EXISTS:
#   `dagu status <x>` reports the *last recorded* run of a DAG, with NO recency
#   filter. A DAG that failed once long ago and has not run since shows "Failed"
#   forever. That is a STALE failure, not an active one — yet a naive sweep
#   flags it as a live problem.
#
# WHAT THIS DOES:
#   Reads each DAG's latest run status straight from Dagu's on-disk journal
#   (<data>/dag-runs/<dag>/.../status.jsonl), and reports a DAG as failing ONLY
#   when BOTH hold:
#     (1) latest-run status == 2 (Failed)  — NOT 3=cancelled, 5=queued,
#         6=partial, 4=success, 1=running, 0=not-started; and
#     (2) that run started within the recency window (default 72h).
#   Stale failures (older than the window) are reported separately as
#   informational only, never as active failures.
#
# Dagu status codes (v2.7.x): 0=not-started 1=running 2=failed(error)
#   3=cancelled 4=success 5=queued 6=partial-success.
#
# Usage:
#   scripts/dagu-recent-failures.sh [--hours N] [--json] [--show-stale]
# Exit code: 0 if no ACTIVE failures, 1 if >=1 active failure (CI-friendly).

set -euo pipefail

HOURS=72
JSON=0
SHOW_STALE=0

# --- Resolve Dagu data base dir, host-portably ---------------------------
# Dagu writes its journal under <base>/dag-runs. Where <base> lives differs by
# host: a launchd/macOS default is ~/.local/share/dagu/data, while a Linux
# install keeps it at /var/lib/agent-os/dagu/data and exports DAGU_DATA_DIR
# ONLY inside the agent-os-dagu.service unit — so a worker or interactive shell
# does NOT inherit it.
#
# Resolution order (first match wins):
#   1. $DAGU_DATA_DIR if set         — explicit caller / unit env
#   2. first candidate whose dag-runs/ exists — macOS path, then Linux path
#   3. DAGU_DATA_DIR parsed from systemctl agent-os-dagu.service (Linux)
#   4. DAGU_DATA_DIR parsed from /etc/agent-os/agent-os.env (if present)
# If none yields an existing dag-runs/, fail loud with the paths we tried.
resolve_data_base() {
  if [ -n "${DAGU_DATA_DIR:-}" ]; then
    printf '%s\n' "$DAGU_DATA_DIR"
    return 0
  fi
  local c
  for c in "$HOME/.local/share/dagu/data" "/var/lib/agent-os/dagu/data"; do
    if [ -d "$c/dag-runs" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  # Authoritative on the Linux host: read the unit's exported env.
  if command -v systemctl >/dev/null 2>&1; then
    local from_unit
    from_unit="$(systemctl show agent-os-dagu.service -p Environment 2>/dev/null \
      | tr ' ' '\n' | sed -n 's/^DAGU_DATA_DIR=//p' | head -n1)"
    if [ -n "$from_unit" ] && [ -d "$from_unit/dag-runs" ]; then
      printf '%s\n' "$from_unit"
      return 0
    fi
  fi
  # Last resort: a DAGU_DATA_DIR line in the shared env file.
  if [ -r /etc/agent-os/agent-os.env ]; then
    local from_env
    from_env="$(sed -n 's/^[[:space:]]*DAGU_DATA_DIR=//p' /etc/agent-os/agent-os.env \
      | tr -d '"' | head -n1)"
    if [ -n "$from_env" ] && [ -d "$from_env/dag-runs" ]; then
      printf '%s\n' "$from_env"
      return 0
    fi
  fi
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --show-stale) SHOW_STALE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if BASE_DIR="$(resolve_data_base)"; then
  DATA_DIR="$BASE_DIR/dag-runs"
else
  echo "dagu data dir not found. Tried: \$DAGU_DATA_DIR (unset), \
$HOME/.local/share/dagu/data/dag-runs, /var/lib/agent-os/dagu/data/dag-runs, \
systemctl agent-os-dagu.service env, /etc/agent-os/agent-os.env. \
Set DAGU_DATA_DIR=<base> (the dir containing dag-runs/) to override." >&2
  exit 2
fi

if [ ! -d "$DATA_DIR" ]; then
  echo "dagu data dir not found: $DATA_DIR" >&2
  exit 2
fi

# Collect the latest run of each DAG, classify by status + recency in python.
python3 - "$DATA_DIR" "$HOURS" "$JSON" "$SHOW_STALE" <<'PY'
import sys, os, json, glob
from datetime import datetime, timezone, timedelta

data_dir, hours, as_json, show_stale = sys.argv[1], int(sys.argv[2]), sys.argv[3]=="1", sys.argv[4]=="1"
now = datetime.now(timezone.utc)
cutoff = now - timedelta(hours=hours)

STATUS = {0:"not-started",1:"running",2:"failed",3:"cancelled",4:"success",5:"queued",6:"partial"}

def parse_ts(s):
    if not s: return None
    try:
        return datetime.fromisoformat(s.replace("Z","+00:00"))
    except Exception:
        return None

active, stale, errors = [], [], []
for dag_dir in sorted(glob.glob(os.path.join(data_dir, "*"))):
    name = os.path.basename(dag_dir)
    files = sorted(glob.glob(os.path.join(dag_dir, "dag-runs", "**", "status.jsonl"), recursive=True))
    if not files:
        continue
    latest = files[-1]  # path sorts chronologically (YYYY/MM/DD/dag-run_TS_...)
    try:
        with open(latest) as fh:
            lines = [l for l in fh if l.strip()]
        rec = json.loads(lines[-1])
    except Exception as e:
        errors.append((name, str(e)))
        continue
    st = rec.get("status")
    ts = parse_ts(rec.get("startedAt") or rec.get("queuedAt") or rec.get("finishedAt"))
    # ONLY status==2 (failed) is a failure. Everything else is not.
    if st != 2:
        continue
    entry = {"dag": name, "status": STATUS.get(st, st), "startedAt": rec.get("startedAt"),
             "ageHours": round((now-ts).total_seconds()/3600,1) if ts else None}
    if ts and ts >= cutoff:
        active.append(entry)
    else:
        stale.append(entry)

if as_json:
    print(json.dumps({"windowHours": hours, "active": active, "stale": stale, "parseErrors": errors}, indent=2))
else:
    print(f"# Dagu DAG failure check — recency window: last {hours}h (now {now.isoformat()})")
    if not active:
        print(f"OK: no DAG with an ACTIVE (latest-run) failure in the last {hours}h.")
    else:
        print(f"ATTENTION: {len(active)} DAG(s) with an active recent failure:")
        for e in active:
            print(f"  - {e['dag']}: latest run FAILED at {e['startedAt']} ({e['ageHours']}h ago)")
    if stale:
        line = f"({len(stale)} stale failure(s) older than {hours}h — NOT active, ignored: " + \
               ", ".join(f"{e['dag']}@{e['startedAt']}" for e in stale) + ")"
        if show_stale or not active:
            print(line)
    if errors:
        print(f"WARN: {len(errors)} journal(s) unreadable: " + ", ".join(n for n,_ in errors))

sys.exit(1 if active else 0)
PY
