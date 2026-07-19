#!/bin/bash
# cleanup-snapshots.sh — retain operator-autocompact snapshots for 7 days.
#
# Run nightly via agent-os-operator-autocompact-cleanup.timer (kept separate
# from the detector timer for visibility). Safe to run at any frequency;
# find -mtime is idempotent.
#
# Env knobs:
#   REPO_ROOT              — repo root (default: inferred from this script)
#   AUTOCOMPACT_SNAP_DIR   — snapshot dir (default: $REPO_ROOT/memory/operator-snapshots)
#   AUTOCOMPACT_RETAIN_DAYS— retention in days (default: 7)

set -uo pipefail

# Self-locating default: this script lives at <repo>/scripts/operator-autocompact/.
# A hardcoded install path silently breaks every non-default layout.
REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SNAP_DIR="${AUTOCOMPACT_SNAP_DIR:-$REPO/memory/operator-snapshots}"
RETAIN_DAYS="${AUTOCOMPACT_RETAIN_DAYS:-7}"

[ -d "$SNAP_DIR" ] || exit 0

deleted=$(find "$SNAP_DIR" -type f -name '*.md' -mtime +"$RETAIN_DAYS" -print -delete | wc -l)
if [ "$deleted" -gt 0 ]; then
  # Log to stdout → systemd journal (unit has StandardOutput=journal).
  # NOT to a shared file: detect-and-restart.sh runs as User=root and owns
  # /var/log/agent-os/operator-autocompact.log root:root 644, so this script
  # (running as the agent user) would hit "Permission denied" on append and
  # the unit would fail on every day that had deletions.
  printf '%s cleanup: removed %s snapshots older than %s days\n' \
    "$(date -u -Iseconds)" "$deleted" "$RETAIN_DAYS"
fi
