#!/usr/bin/env bash
# proposals-pending-test.sh — fixture test for the frontmatter-aware proposal-queue
# scan. Builds a throwaway directory holding exactly the classes of file the old
# `grep -l "status: pending"` lied about, and prints the delta baseline → fixed.
#
# The gate is NOT that the script parses (`bash -n` would be just as green on a
# script that fixes nothing). The gate is that THE PHANTOMS ARE GONE while the one
# live pending proposal survives. Both halves are printed.
#
# Usage: scripts/proposals-pending-test.sh   → exit 0 = PASS, exit 1 = FAIL
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/proposals-pending.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# (1) the live pending proposal — the ONLY correct answer
cat > "$FIX/2026-07-22-real-pending.md" <<'EOF'
---
date: 2026-07-22
task_id: 0000abcde
agent: heartbeat
file: agents/heartbeat/strategist-prompt.md
status: pending
---
## Proposal
A live proposal, waiting for a decision.
EOF

# (2) the README format template: an example line in the body, no frontmatter at all
cat > "$FIX/README.md" <<'EOF'
# Proposals

Frontmatter format:

    status: pending
EOF

# (3) a batch review: quotes `status: pending` in its prose
cat > "$FIX/REVIEW-2026-07-21.md" <<'EOF'
# Batch review

Reviewed 6 proposals with `status: pending` (the README was a false grep hit).
EOF

# (4) an ALREADY APPLIED proposal that PROPOSES a frontmatter with a pending status
#     inside its `### After` block — the nastiest class: a `^status:` anchor still
#     catches it, because the quoted line starts a line too
cat > "$FIX/2026-07-16-applied-with-example.md" <<'EOF'
---
date: 2026-07-16
agent: heartbeat
status: applied
---
## Change
### After
```markdown
---
date: YYYY-MM-DD
status: pending
---
```
EOF

# (5) an archived proposal that is genuinely `pending` — archive/ is NOT the queue,
#     so it must never surface, while a recursive grep happily returns it
mkdir -p "$FIX/archive"
cat > "$FIX/archive/2026-07-10-archived-pending.md" <<'EOF'
---
date: 2026-07-10
agent: operator
status: pending
---
## Proposal
Parked in the archive; not part of the live queue.
EOF

echo "=== BASELINE: grep -l \"status: pending\" (the old queue scan) ==="
base="$(grep -l "status: pending" "$FIX"/*.md 2>/dev/null || true)"
base_n=$(printf '%s' "$base" | grep -c . || true)
printf '%s\n' "$base" | sed "s|$FIX/|  • |"
echo "  baseline pending: $base_n  (expected 4: 1 live + 3 phantoms)"

echo
echo "=== BASELINE-2: grep -l '^status: pending' minus README (the 'hardened' grep) ==="
base2="$(grep -l '^status: pending' "$FIX"/*.md 2>/dev/null | grep -v '/README.md' || true)"
base2_n=$(printf '%s' "$base2" | grep -c . || true)
printf '%s\n' "$base2" | sed "s|$FIX/|  • |"
echo "  baseline-2 pending: $base2_n  (expected 2: the live one + the '### After' example)"

echo
echo "=== BASELINE-3: grep -rl \"status: pending\" (recursive — archive/ leaks in) ==="
base3="$(grep -rl "status: pending" "$FIX" 2>/dev/null || true)"
base3_n=$(printf '%s' "$base3" | grep -c . || true)
printf '%s\n' "$base3" | sed "s|$FIX/|  • |"
echo "  baseline-3 pending: $base3_n  (expected 5: the 4 above + archive/)"

echo
echo "=== FIXED: scripts/proposals-pending.sh (frontmatter-only, top level only) ==="
fixed="$("$SUT" --dir "$FIX" 2>&1 || true)"
fixed_n=$(printf '%s' "$fixed" | grep -c . || true)
printf '%s\n' "$fixed" | sed "s|$FIX/|  • |"
echo "  fixed pending: $fixed_n  (expected 1)"

echo
fail=0
[[ "$base_n"  == "4" ]] || { echo "FAIL: baseline expected 4, got $base_n"; fail=1; }
[[ "$base2_n" == "2" ]] || { echo "FAIL: baseline-2 expected 2, got $base2_n"; fail=1; }
[[ "$base3_n" == "5" ]] || { echo "FAIL: baseline-3 expected 5, got $base3_n"; fail=1; }
[[ "$fixed_n" == "1" ]] || { echo "FAIL: fixed expected 1, got $fixed_n"; fail=1; }
[[ "$fixed" == "$FIX/2026-07-22-real-pending.md" ]] \
  || { echo "FAIL: fixed returned something other than the live proposal: $fixed"; fail=1; }
# archive/ must not surface under any mode
printf '%s\n' "$fixed" | grep -q '/archive/' \
  && { echo "FAIL: an archive/ proposal leaked into the pending queue"; fail=1; }
"$SUT" --dir "$FIX" --all 2>&1 | grep -q '/archive/' \
  && { echo "FAIL: an archive/ proposal leaked into --all"; fail=1; }

# Negative invariants: --all neither loses files that have a status nor invents them
all_n="$("$SUT" --dir "$FIX" --all 2>&1 | grep -c . || true)"
[[ "$all_n" == "2" ]] || { echo "FAIL: --all expected 2 files with frontmatter, got $all_n"; fail=1; }
applied_n="$("$SUT" --dir "$FIX" --status applied --count 2>&1)"
[[ "$applied_n" == "1" ]] || { echo "FAIL: --status applied expected 1, got $applied_n"; fail=1; }
# An empty queue is not an error
"$SUT" --dir "$(mktemp -d)" >/dev/null 2>&1 || { echo "FAIL: an empty directory exited non-zero"; fail=1; }

if (( fail )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS — phantoms 3→0, archive/ excluded (recursive grep 5 → scan 1), live pending kept"
exit 0
