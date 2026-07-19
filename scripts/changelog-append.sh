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
# only bullets not already present *in that section* are appended right after
# the header (no duplicate headers, no duplicate bullets). Workers: call this
# via Bash instead of Edit'ing CHANGELOG.md — Edit on a file that parallel
# workers also append to is a known conflict source (old_string drifts between
# Read and Edit, edits bounce or clobber each other).
#
# Concurrency-safe: the whole read-modify-write runs under an exclusive flock
# on <CHANGELOG>.lock. Two workers appending at the same instant used to race —
# both read the same file, both `mv` their tmp over it, the slower writer won
# and the other's bullets vanished silently. The `CHANGELOG.md merge=union`
# gitattribute covers the *other* half of the problem (concurrent branches
# merging), not this one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"
CHANGELOG="${CHANGELOG_FILE:-$REPO/CHANGELOG.md}"

[[ $# -ge 2 ]] || { echo "usage: $0 \"<title>\" \"<bullet>\" [\"<bullet>\" ...]" >&2; exit 2; }

TITLE="$1"; shift
DATE="$(date +%F)"
HEADER="## [$DATE] $TITLE"
TOTAL=$#

[[ -f "$CHANGELOG" ]] || { echo "CHANGELOG not found: $CHANGELOG" >&2; exit 1; }

# --- exclusive lock over the whole read-modify-write ------------------------
# The lock file lives beside the CHANGELOG and is not tracked (see .gitignore).
LOCKFILE="${CHANGELOG}.lock"
LOCK_WAIT="${CHANGELOG_LOCK_WAIT:-30}"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  flock -w "$LOCK_WAIT" 9 || {
    echo "changelog: could not acquire $LOCKFILE within ${LOCK_WAIT}s" >&2
    exit 1
  }
else
  # flock(1) ships with util-linux; on a host without it, degrade to the old
  # unsynchronised behaviour rather than failing the caller's whole task.
  echo "changelog: WARNING flock(1) not found — appending without a lock" >&2
fi

SECTION="$(mktemp)"; TMP="$(mktemp)"; ADD="$(mktemp)"
trap 'rm -f "$SECTION" "$TMP" "$ADD"' EXIT

if grep -qxF "$HEADER" "$CHANGELOG"; then
  # Extract ONLY today's section (header .. next "## " header or EOF), so a
  # bullet that duplicates one from an older section still lands today.
  awk -v hdr="$HEADER" '
    $0 == hdr { in_sec = 1; next }
    in_sec && /^## / { in_sec = 0 }
    in_sec { print }
  ' "$CHANGELOG" > "$SECTION"

  missing=()
  for b in "$@"; do
    line="- $b"
    grep -qxF -- "$line" "$SECTION" || missing+=("$line")
  done

  if (( ${#missing[@]} )); then
    # One rewrite for all missing bullets, inserted after the header in the
    # order they were passed.
    printf '%s\n' "${missing[@]}" > "$ADD"
    awk -v hdr="$HEADER" -v addfile="$ADD" '
      { print }
      $0 == hdr {
        while ((getline l < addfile) > 0) print l
        close(addfile)
      }
    ' "$CHANGELOG" > "$TMP" && mv "$TMP" "$CHANGELOG"
  fi
  ADDED=${#missing[@]}
else
  {
    echo ""
    echo "$HEADER"
    for b in "$@"; do echo "- $b"; done
  } >> "$CHANGELOG"
  ADDED=$TOTAL
fi

echo "changelog: '$HEADER' ($ADDED of $TOTAL bullet(s) added) -> $CHANGELOG"
