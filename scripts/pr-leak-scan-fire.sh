#!/bin/bash
# pr-leak-scan-fire.sh — run the deterministic leak gate over every OPEN PR in the
# PUBLIC repos you watch, and comment on the ones that would leak.
#
# WHY a routine and not just a hook: PRs into a public repo can be opened by an
# agent, a teammate, or a fork, and a diff can grow a leak in a later push. A
# scheduled sweep catches all of those without trusting anyone to run the scanner.
#
# WHAT IT DOES per open PR: `gh pr diff` -> scripts/pr-leak-scan.sh.
#   exit 2 (LEAK)        -> comment on the PR with the sanitised findings, exit
#                           non-zero at the end so the routine's failure handler
#                           alerts you.
#   exit 3 (REVIEW)      -> comment asking for a human/LLM judgement (MEDIUM only),
#                           also counted as needing attention.
#   exit 4 (NOT SCANNED) -> the diff was never actually scanned (empty, or an API
#                           error body such as the 300-file cap). Treated exactly
#                           like a failure to pass: commented and counted. A PR
#                           nobody could check must not read as a PR that came back
#                           clean — that is the whole point of the separate code.
#   exit 0 (CLEAN)       -> silent.
# The same rule covers a diff we could not fetch at all: it is counted as NOT
# SCANNED rather than skipped, so a repo-wide fetch outage cannot quietly report
# "all clean".
# It NEVER merges, closes, or approves anything — this script only reports. Merge
# automation, if you want it, belongs in a separate job that runs AFTER this gate.
#
# IDEMPOTENT: each comment carries a hidden marker with the PR's head SHA, so a
# re-run on an unchanged PR does not re-comment. A new push (new SHA) re-comments.
#
# CONFIG (all optional):
#   PR_LEAK_SCAN_ORG    org whose PUBLIC repos are swept (default: config watch.org)
#   PR_LEAK_SCAN_REPOS  space-separated org/repo list; overrides org discovery
#   PR_LEAK_SCAN_DRYRUN 1 = print findings, never comment
# Falls back to `watch.org` / `watch.repos` in .pr-leak-scan.json. With neither, it
# exits 0 with a note — an unconfigured install is not a failure.
#
# Requires: gh (authenticated), python3, jq.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCANNER="$REPO_ROOT/scripts/pr-leak-scan.sh"
CONFIG="${PR_LEAK_SCAN_CONFIG:-$REPO_ROOT/.pr-leak-scan.json}"
DRYRUN="${PR_LEAK_SCAN_DRYRUN:-0}"

export GH_PROMPT_DISABLED=1

for bin in gh python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "pr-leak-scan-fire: $bin required" >&2; exit 1; }
done
[ -x "$SCANNER" ] || { echo "pr-leak-scan-fire: $SCANNER missing/not executable" >&2; exit 1; }

cfg_get() {  # cfg_get <jq-filter> -> value or empty
  [ -f "$CONFIG" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r "$1 // empty" "$CONFIG" 2>/dev/null
}

# ---- 1. which repos to sweep -------------------------------------------------
REPOS=()
if [ -n "${PR_LEAK_SCAN_REPOS:-}" ]; then
  read -r -a REPOS <<< "$PR_LEAK_SCAN_REPOS"
else
  while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(cfg_get '.watch.repos[]')
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
  ORG="${PR_LEAK_SCAN_ORG:-$(cfg_get '.watch.org')}"
  if [ -z "$ORG" ]; then
    echo "pr-leak-scan-fire: no repos configured (set PR_LEAK_SCAN_ORG/PR_LEAK_SCAN_REPOS or watch.org in $(basename "$CONFIG")) — nothing to do"
    exit 0
  fi
  # Only PUBLIC repos: a leak into a private repo of your own is not the threat here.
  while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(
    gh repo list "$ORG" --visibility public --limit 200 \
      --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null)
  if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "pr-leak-scan-fire: no public repos found in org '$ORG' (gh auth?) — skipping" >&2
    exit 0
  fi
fi

# ---- 2. sweep open PRs -------------------------------------------------------
CHECKED=0; FLAGGED=0
SUMMARY=""

for repo in "${REPOS[@]}"; do
  while IFS=$'\t' read -r num title sha; do
    [ -z "$num" ] && continue
    CHECKED=$((CHECKED + 1))

    diff_file="$(mktemp "${TMPDIR:-/tmp}/pr-leak-diff.XXXXXX")"
    if gh pr diff "$num" --repo "$repo" > "$diff_file" 2>/dev/null; then
      # stderr carries the scanner's NOT-SCANNED explanation; keep it in $findings
      # so the reason a PR could not be checked reaches the comment.
      findings="$(PR_LEAK_SCAN_CONFIG="$CONFIG" "$SCANNER" "$diff_file" 2>&1)"
      rc=$?
    else
      # A fetch that fails outright is the same class of problem as a diff that
      # is not a diff: we have no verdict. Fail closed, do not `continue`.
      findings="could not fetch the diff for ${repo}#${num} (gh pr diff failed)"
      rc=4
    fi
    rm -f "$diff_file"
    [ "$rc" -eq 0 ] && continue
    if [ "$rc" -eq 1 ]; then
      echo "pr-leak-scan-fire: scanner error on ${repo}#${num}" >&2
      continue
    fi

    FLAGGED=$((FLAGGED + 1))
    case "$rc" in
      2) verdict="LEAK — do not merge"; icon="[BLOCK]" ;;
      3) verdict="REVIEW — MEDIUM matches only, needs a human call"; icon="[REVIEW]" ;;
      4) verdict="NOT SCANNED — no verdict, treat as unreviewed"; icon="[NOT-SCANNED]" ;;
      *) verdict="UNKNOWN scanner exit $rc — treat as unreviewed"; icon="[NOT-SCANNED]" ;;
    esac
    SUMMARY+="${icon} ${repo}#${num}: ${title}"$'\n'

    # Marker ties the comment to this exact head SHA -> no repeat comments.
    marker="<!-- pr-leak-scan:${sha} -->"
    if [ "$DRYRUN" = "1" ]; then
      echo "--- ${icon} ${repo}#${num} (${verdict})"; echo "$findings"; continue
    fi
    if gh pr view "$num" --repo "$repo" --json comments \
         -q '.comments[].body' 2>/dev/null | grep -qF "$marker"; then
      continue  # already reported for this head SHA
    fi

    if [ "$rc" -eq 4 ]; then
      intro="The leak gate could **not** read this PR's diff, so nothing was checked. This is not a clean result — re-fetch the diff (a clone-based \`git diff\` works past the API's 300-file cap) and rescan before merging."
      legend="No verdict was produced; the line below is the reason the scan could not run."
    else
      intro="This PR adds lines matching the leak catalogue. Values of any credential are masked below; the finding is the location, not the value."
      legend="\`SEV|type|file:line|excerpt\` — CRITICAL = credential, HIGH = personal data, MEDIUM = context-dependent.
Rotate anything real that appears here: it is in the PR history even if the line is removed."
    fi

    # Findings are already sanitised (secret values masked) — safe to post.
    body="${marker}
**pr-leak-scan: ${verdict}**

${intro}

\`\`\`
${findings}
\`\`\`

${legend}

<sub>Posted by \`scripts/pr-leak-scan-fire.sh\`. Re-runs stay silent until a new commit lands.</sub>"
    gh pr comment "$num" --repo "$repo" --body "$body" >/dev/null 2>&1 \
      || echo "pr-leak-scan-fire: failed to comment on ${repo}#${num}" >&2
  done < <(gh pr list --repo "$repo" --state open --json number,title,headRefOid \
            -q '.[] | "\(.number)\t\(.title)\t\(.headRefOid)"' 2>/dev/null)
done

# ---- 3. report ---------------------------------------------------------------
if [ "$FLAGGED" -eq 0 ]; then
  echo "pr-leak-scan-fire: ${CHECKED} open PR(s) across ${#REPOS[@]} repo(s) — all clean"
  exit 0
fi

echo "pr-leak-scan-fire: ${FLAGGED}/${CHECKED} open PR(s) need attention:"
printf '%s' "$SUMMARY"
# Non-zero so the routine's failure path alerts — a flagged PR must not pass quietly.
exit 2
