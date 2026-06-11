#!/usr/bin/env bash
# changelog-append.sh — append a dated section to CHANGELOG.md without Edit-storms.
#
# Usage:
#   scripts/changelog-append.sh "<title>" "<bullet>" ["<bullet>" ...]
#
# Appends:
#   ## [YYYY-MM-DD] <title>
#   - <bullet>
#   ...
#
# Idempotent by meaning: if today's "## [date] <title>" header already exists,
# only bullets not already present verbatim are appended right after that
# section (no duplicate headers, no duplicate bullets). Workers: call this via
# Bash instead of Edit'ing CHANGELOG.md — Edit on a file that parallel workers
# also append to is a known conflict source (old_string drifts between Read
# and Edit, edits bounce or clobber each other).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"
CHANGELOG="${CHANGELOG_FILE:-$REPO/CHANGELOG.md}"

[[ $# -ge 2 ]] || { echo "usage: $0 \"<title>\" \"<bullet>\" [\"<bullet>\" ...]" >&2; exit 2; }

TITLE="$1"; shift
DATE="$(date +%F)"
HEADER="## [$DATE] $TITLE"

[[ -f "$CHANGELOG" ]] || { echo "CHANGELOG not found: $CHANGELOG" >&2; exit 1; }

if grep -qxF "$HEADER" "$CHANGELOG"; then
  # Header exists — insert missing bullets right after the header line.
  for b in "$@"; do
    line="- $b"
    if ! grep -qxF -- "$line" "$CHANGELOG"; then
      tmp="$(mktemp)"
      awk -v hdr="$HEADER" -v add="$line" '
        { print }
        $0 == hdr { print add }
      ' "$CHANGELOG" > "$tmp" && mv "$tmp" "$CHANGELOG"
    fi
  done
else
  {
    echo ""
    echo "$HEADER"
    for b in "$@"; do echo "- $b"; done
  } >> "$CHANGELOG"
fi

echo "changelog: '$HEADER' ($# bullet(s)) -> $CHANGELOG"
