#!/bin/bash
# fire-step.sh — the single Dagu entry point for every check-fire step.
#
# Without it, each check routine inlines the same boilerplate in its DAG step:
#
#     command: /bin/bash /path/to/repo/scripts/check-fire.sh <id> <prio> "<desc>"
#     working_dir: /path/to/repo
#
# — the `/bin/bash` prefix, the absolute path and a `working_dir` line, copy-
# pasted across every routine. This wrapper collapses that to:
#
#     command: /path/to/repo/scripts/fire-step.sh <id> <prio> "<desc>"
#
# (no working_dir — the wrapper resolves the repo from its own location).
#
# It is a pure wrapper, not a reimplementation: every argument is forwarded
# VERBATIM to check-fire.sh, gating flags included, so the upsert identity is
# byte-for-byte what a direct call would produce.
#
# What the indirection buys, beyond the boilerplate: one cross-cutting place for
# things that must apply to ALL scheduled firing. Today that is a global pause
# switch —
#
#     touch memory/.fire-paused    # halt every scheduled check at once
#     rm    memory/.fire-paused    # resume
#
# — which beats disabling routines one by one during maintenance, and cannot be
# forgotten in the enabled-again pass. Absent file => no effect whatsoever.
# Override the path with FIRE_PAUSE_FILE.
#
# Usage (drop-in for a direct check-fire.sh invocation):
#   fire-step.sh [check-fire flags] <check-id> <priority> "<description>"
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
cd "$REPO" || exit 1

PAUSE_FILE="${FIRE_PAUSE_FILE:-$REPO/memory/.fire-paused}"
if [ -f "$PAUSE_FILE" ]; then
  echo "fire-step: skip — global pause active ($PAUSE_FILE exists; rm to resume)" >&2
  exit 0
fi

exec /bin/bash "$REPO/scripts/check-fire.sh" "$@"
