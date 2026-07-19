#!/bin/bash
# trigger-worker-now.sh — immediately trigger one worker lifecycle cycle via the Dagu CLI.
#
# Usage: trigger-worker-now.sh
#
# Triggers the 'workers' DAG (collect -> launch) without waiting for the next
# 5-min cron tick. Dagu enforces max_active_runs: 1 — safe to call even if a
# cycle is already running.
#
# Uses the `dagu` CLI rather than the HTTP API on purpose: once Dagu sits behind
# a reverse proxy the API moves under DAGU_BASE_PATH and a hardcoded
# POST /api/v1/dags/workers/start returns HTTP 405. The CLI talks to the local
# data dir directly and is immune to base-path / API-version drift. The env
# defaults below mirror the Dagu service unit so the CLI reads the same DAGs and
# data the scheduler does.

set -uo pipefail

DAGU_BIN="${DAGU_BIN:-/usr/local/bin/dagu}"
DAG_NAME="${DAG_NAME:-workers}"
REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Host-portable run-as user, resolved in order: explicit override -> the User=
# rendered into the Dagu service unit on this host -> the invoking user. The
# unit runs as whatever user the deployment configured; do NOT hardcode a
# username here — on a host where that user does not exist every call dies with
# "sudo: unknown user ...".
RUN_AS="${DAGU_RUN_AS:-$(systemctl show -p User --value agent-os-dagu.service 2>/dev/null)}"
RUN_AS="${RUN_AS:-$(id -un)}"

export HOME="${DAGU_HOME:-$HOME}"
export DAGU_DAGS_DIR="${DAGU_DAGS_DIR:-$REPO/routines}"
export DAGU_DATA_DIR="${DAGU_DATA_DIR:-/var/lib/agent-os/dagu/data}"
export DAGU_ADMIN_DATA_DIR="${DAGU_ADMIN_DATA_DIR:-/var/lib/agent-os/dagu/data}"
export DAGU_LOG_DIR="${DAGU_LOG_DIR:-/var/lib/agent-os/dagu/logs}"
export DAGU_WORK_DIR="${DAGU_WORK_DIR:-$REPO}"
export TZ="${TZ:-UTC}"

if [[ ! -x "$DAGU_BIN" ]]; then
  echo "ERROR: dagu binary not found/executable at $DAGU_BIN" >&2
  exit 1
fi

# Run as the user that owns the data dir when invoked as someone else; otherwise direct.
run_dagu() {
  if [[ "$(id -un)" == "$RUN_AS" ]]; then
    "$DAGU_BIN" "$@"
  else
    sudo -u "$RUN_AS" env \
      HOME="$HOME" \
      DAGU_DAGS_DIR="$DAGU_DAGS_DIR" \
      DAGU_DATA_DIR="$DAGU_DATA_DIR" \
      DAGU_ADMIN_DATA_DIR="$DAGU_ADMIN_DATA_DIR" \
      DAGU_LOG_DIR="$DAGU_LOG_DIR" \
      DAGU_WORK_DIR="$DAGU_WORK_DIR" \
      TZ="$TZ" \
      "$DAGU_BIN" "$@"
  fi
}

out=$(run_dagu start "$DAG_NAME" 2>&1)
rc=$?

# Surface the launch line(s) so callers see what was picked up.
echo "$out" | grep -iE "launched:|Result:|already running|max_active_runs" || true

if [[ $rc -eq 0 ]]; then
  echo "OK: workers DAG triggered"
  exit 0
fi

# A concurrent run (max_active_runs=1) is a benign no-op, not a failure.
if echo "$out" | grep -qiE "already running|max_active_runs|active run"; then
  echo "OK: workers DAG already running, skipping duplicate trigger"
  exit 0
fi

echo "ERROR: dagu start $DAG_NAME failed (exit $rc):" >&2
echo "$out" >&2
exit 1
