#!/bin/bash
# dagu-run.sh — manually trigger ONE run of any Dagu DAG, on-demand.
#
# Usage: dagu-run.sh <dag-name>
#   e.g. dagu-run.sh example-heartbeat
#        dagu-run.sh dagu-heartbeat
#
# It takes the DAG name as $1 and runs `dagu start <dag>`.
#
# This is a MANUAL on-demand trigger only. It does NOT add a schedule — the
# cron schedule for every DAG lives exclusively in the DAG YAML (routines/*.yaml).
#
# DAGs with `max_active_runs: 1` treat a concurrent kick as a benign no-op —
# this script reports OK and exits 0, it does not fail. The env block mirrors
# agent-os-dagu.service so the CLI reads the same DAGs/data dir the scheduler
# does (immune to API base-path drift).

set -uo pipefail

DAG_NAME="${1:-}"
if [[ -z "$DAG_NAME" ]]; then
  echo "ERROR: usage: dagu-run.sh <dag-name> (e.g. example-heartbeat)" >&2
  exit 2
fi

DAGU_BIN="${DAGU_BIN:-/usr/local/bin/dagu}"
# Host-portable run-as user: explicit override → dagu service's rendered User=
# → current user. Avoids hardcoding an install-specific user name.
RUN_AS="${DAGU_RUN_AS:-$(systemctl show -p User --value agent-os-dagu.service 2>/dev/null)}"
RUN_AS="${RUN_AS:-$(id -un)}"

export HOME="${DAGU_HOME:-$HOME}"
export DAGU_DAGS_DIR="${DAGU_DAGS_DIR:-/opt/agent-os/claude/routines}"
export DAGU_DATA_DIR="${DAGU_DATA_DIR:-/var/lib/agent-os/dagu/data}"
export DAGU_ADMIN_DATA_DIR="${DAGU_ADMIN_DATA_DIR:-/var/lib/agent-os/dagu/data}"
export DAGU_LOG_DIR="${DAGU_LOG_DIR:-/var/lib/agent-os/dagu/logs}"
export DAGU_WORK_DIR="${DAGU_WORK_DIR:-/opt/agent-os/claude}"

if [[ ! -x "$DAGU_BIN" ]]; then
  echo "ERROR: dagu binary not found/executable at $DAGU_BIN" >&2
  exit 1
fi

# Reject unknown DAGs early with a clear message (the .yaml must exist).
if [[ ! -f "$DAGU_DAGS_DIR/$DAG_NAME.yaml" && ! -f "$DAGU_DAGS_DIR/$DAG_NAME.yml" ]]; then
  echo "ERROR: no DAG '$DAG_NAME' in $DAGU_DAGS_DIR (expected $DAG_NAME.yaml)" >&2
  exit 1
fi

# Run as the agent user (owns the data dir) when invoked as root; otherwise direct.
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
      "$DAGU_BIN" "$@"
  fi
}

out=$(run_dagu start "$DAG_NAME" 2>&1)
rc=$?

# Surface the launch line(s) so callers see what was picked up.
echo "$out" | grep -iE "launched:|Result:|already running|max_active_runs" || true

if [[ $rc -eq 0 ]]; then
  echo "OK: $DAG_NAME DAG triggered"
  exit 0
fi

# A concurrent run (max_active_runs reached) is a benign no-op, not a failure.
if echo "$out" | grep -qiE "already running|max_active_runs|active run"; then
  echo "OK: $DAG_NAME DAG already running, skipping duplicate trigger"
  exit 0
fi

echo "ERROR: dagu start $DAG_NAME failed (exit $rc):" >&2
echo "$out" >&2
exit 1
