#!/usr/bin/env bash
# Self-test for the scheduled-check layer: check-fire.sh, fire-step.sh,
# dep-reachable.sh, clickup_upsert.py.
#
# Why this exists: every failure mode of this layer is SILENT. A gate stuck
# closed, a pause file left behind, a mistyped dep — none of them raise; the
# check simply stops firing, and nobody notices until someone asks why the
# morning brief hasn't arrived in three weeks. So the tests pin the properties
# that make the layer trustworthy — that a skip is deliberate, that a
# misconfiguration is LOUD, that the wrapper forwards arguments untouched — not
# just "it calls the API".
#
# Fully offline: the ClickUp upsert and the dep checks are stubbed via the
# REPO_ROOT seam the scripts already honour. No token, no network, no ClickUp.
#
# Usage: tests/check-fire/run.sh
set -uo pipefail

REAL_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_FIRE="$REAL_REPO/scripts/check-fire.sh"
FIRE_STEP="$REAL_REPO/scripts/fire-step.sh"
DEP_REACHABLE="$REAL_REPO/scripts/lib/dep-reachable.sh"
UPSERT_PY="$REAL_REPO/scripts/lib/clickup_upsert.py"

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# assert_contains <label> <needle> <haystack>
assert_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1" "expected to contain [$2], got [$3]" ;;
  esac
}

# assert_not_contains <label> <needle> <haystack>
assert_not_contains() {
  case "$3" in
    *"$2"*) bad "$1" "expected NOT to contain [$2], got [$3]" ;;
    *)      ok "$1" ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fake repo: real scripts, stubbed collaborators ------------------------
# The scripts resolve their collaborators under $REPO_ROOT, so pointing
# REPO_ROOT at a fake tree swaps the ClickUp call and the dep probes for stubs
# without a single test-only flag in the production code.
FAKE="$TMP/repo"
mkdir -p "$FAKE/scripts/lib/dep-checks" "$FAKE/memory"
UPSERT_LOG="$TMP/upsert.log"
FIRE_LOG="$TMP/fire.log"

# NUL-terminates every argument (not just separates), so that after `tr` each
# argument is followed by a space and an assertion can anchor on "--tag x " —
# otherwise a match on the LAST argument would need a different form than the
# same match in the middle.
cat > "$FAKE/scripts/lib/clickup_upsert.py" <<PY
import sys
with open("$UPSERT_LOG", "a") as f:
    f.write("".join(a + "\0" for a in sys.argv[1:]) + "\n")
print("fake-task-id")
PY

# Stub check-fire, for testing fire-step's forwarding in isolation.
cat > "$FAKE/scripts/check-fire.sh" <<SH
#!/bin/bash
printf '%s\0' "\$@" >> "$FIRE_LOG"
printf '\n' >> "$FIRE_LOG"
SH
chmod +x "$FAKE/scripts/check-fire.sh"

# Dep stub whose verdict the tests control through a file.
cat > "$FAKE/scripts/lib/dep-reachable.sh" <<SH
#!/bin/bash
[ -f "$TMP/dep-\$1.down" ] && exit 1
exit 0
SH
chmod +x "$FAKE/scripts/lib/dep-reachable.sh"

last_upsert() { tr '\0' ' ' < "$UPSERT_LOG" | tail -1; }
reset_logs()  { : > "$UPSERT_LOG"; : > "$FIRE_LOG"; }

# Run check-fire against the fake repo, capturing stdout+stderr.
fire() { REPO_ROOT="$FAKE" "$CHECK_FIRE" "$@" 2>&1; }

echo "check-fire self-test"
echo
echo "check-fire.sh — misconfiguration must be loud"

reset_logs
out="$(CLICKUP_SCHEDULED_LIST_ID=L1 fire 2>&1)"; rc=$?
assert_eq "no check-id -> exit 1" "1" "$rc"
assert_contains "no check-id -> usage on stderr" "usage" "$out"

# The critical one: a check with nowhere to fire must go RED, not quietly
# succeed. A green run that created nothing is indistinguishable from a working
# check right up until someone looks for the task.
out="$(env -u CLICKUP_SCHEDULED_LIST_ID REPO_ROOT="$FAKE" \
        "$CHECK_FIRE" my-check low "desc" 2>&1)"; rc=$?
assert_eq "no list id -> exit 1 (never a silent no-op)" "1" "$rc"
assert_contains "no list id -> names the env var to set" "CLICKUP_SCHEDULED_LIST_ID" "$out"
assert_eq "no list id -> nothing upserted" "" "$(cat "$UPSERT_LOG")"

echo
echo "check-fire.sh — identity and arguments"

reset_logs
CLICKUP_SCHEDULED_LIST_ID=L1 fire my-check low "do the thing" >/dev/null 2>&1
got="$(last_upsert)"
assert_contains "fires an upsert (not a create)" "upsert" "$got"
assert_contains "passes the destination list" "--list-id L1 " "$got"
# Identity is (gen, key). If either drifts, every existing task orphans and the
# next tick starts a fresh duplicate lineage.
assert_contains "gen is 'check-fire'" "--gen check-fire " "$got"
assert_contains "key is the check id" "--key my-check " "$got"
assert_contains "title is prefixed" "--title Scheduled: my-check " "$got"
assert_contains "description is passed through" "--desc do the thing " "$got"

reset_logs
fire --list L2 my-check low "d" >/dev/null 2>&1
assert_contains "--list overrides the env" "--list-id L2 " "$(last_upsert)"

echo
echo "check-fire.sh — priority mapping (ClickUp: 1 urgent .. 4 low)"

for pair in "critical:1" "high:2" "medium:3" "low:4"; do
  word="${pair%%:*}"; num="${pair##*:}"
  reset_logs
  CLICKUP_SCHEDULED_LIST_ID=L1 fire c "$word" "d" >/dev/null 2>&1
  assert_contains "$word -> $num" "--priority $num " "$(last_upsert)"
done

reset_logs
out="$(CLICKUP_SCHEDULED_LIST_ID=L1 fire c bogus "d")"
assert_contains "unknown priority -> falls back to low" "--priority 4 " "$(last_upsert)"
assert_contains "unknown priority -> warns" "unknown priority" "$out"

echo
echo "check-fire.sh — tags are per-install routing, not hardcoded"

reset_logs
CLICKUP_SCHEDULED_LIST_ID=L1 fire c low "d" >/dev/null 2>&1
got="$(last_upsert)"
assert_contains "default tag: scheduled" "--tag scheduled " "$got"
assert_contains "default tag: source:check-fire" "--tag source:check-fire " "$got"

reset_logs
CLICKUP_SCHEDULED_LIST_ID=L1 CHECK_FIRE_TAGS="alpha, beta" fire c low "d" >/dev/null 2>&1
got="$(last_upsert)"
assert_contains "CHECK_FIRE_TAGS: first tag" "--tag alpha " "$got"
assert_contains "CHECK_FIRE_TAGS: whitespace tolerated" "--tag beta " "$got"
assert_not_contains "CHECK_FIRE_TAGS replaces the defaults" "--tag scheduled " "$got"

echo
echo "check-fire.sh — dependency gate"

reset_logs
touch "$TMP/dep-calendar.down"
out="$(CLICKUP_SCHEDULED_LIST_ID=L1 fire --require-dep calendar c low "d")"; rc=$?
# Exit 0: a skip is a deliberate outcome, not a failure. Going red here would
# train everyone to ignore a red run on the one routine most likely to be down.
assert_eq "dep down -> exit 0 (deliberate skip)" "0" "$rc"
assert_eq "dep down -> queue untouched" "" "$(cat "$UPSERT_LOG")"
assert_contains "dep down -> says which dep" "calendar" "$out"
assert_contains "dep down -> says the gate self-reopens" "auto-reopens" "$out"

reset_logs
rm -f "$TMP/dep-calendar.down"
CLICKUP_SCHEDULED_LIST_ID=L1 fire --require-dep calendar c low "d" >/dev/null 2>&1
assert_contains "dep recovered -> fires again, no manual reset" "--key c " "$(last_upsert)"

reset_logs
touch "$TMP/dep-b.down"
CLICKUP_SCHEDULED_LIST_ID=L1 fire --require-dep a --require-dep b c low "d" >/dev/null 2>&1
assert_eq "multiple deps -> ALL must pass" "" "$(cat "$UPSERT_LOG")"
rm -f "$TMP/dep-b.down"

echo
echo "fire-step.sh — pure wrapper + global pause"

step() { REPO_ROOT="$FAKE" "$FIRE_STEP" "$@" 2>&1; }
last_fire() { tr '\0' ' ' < "$FIRE_LOG" | tail -1; }

reset_logs
step --require-dep calendar my-check high "a desc with spaces" >/dev/null 2>&1
# Verbatim forwarding is the whole contract: the upsert identity a routine
# produces through the wrapper must equal a direct call's, byte for byte.
assert_contains "forwards flags verbatim" "--require-dep calendar " "$(last_fire)"
assert_contains "forwards the check id" "my-check " "$(last_fire)"
assert_contains "keeps a quoted arg as ONE argument" "a desc with spaces " "$(last_fire)"

reset_logs
touch "$FAKE/memory/.fire-paused"
out="$(step my-check low "d")"; rc=$?
assert_eq "pause file -> exit 0" "0" "$rc"
assert_eq "pause file -> nothing fires" "" "$(cat "$FIRE_LOG")"
# The message must name the file. A pause left on by accident is otherwise a
# silent, system-wide outage of every scheduled check.
assert_contains "pause -> names the file to remove" ".fire-paused" "$out"
rm -f "$FAKE/memory/.fire-paused"

reset_logs
step my-check low "d" >/dev/null 2>&1
assert_contains "pause lifted -> fires again" "my-check " "$(last_fire)"

reset_logs
: > "$TMP/custom-pause"
out="$(FIRE_PAUSE_FILE="$TMP/custom-pause" step my-check low "d")"
assert_eq "FIRE_PAUSE_FILE honoured" "" "$(cat "$FIRE_LOG")"

echo
echo "dep-reachable.sh — fail-open on unknown, dispatch on drop-in"

dep() { REPO_ROOT="$FAKE" "$DEP_REACHABLE" "$@" 2>&1; }

out="$(dep)"; rc=$?
assert_eq "no argument -> exit 1" "1" "$rc"

# Fail-open: a typo must not freeze a check forever. A gate that wrongly stays
# shut is invisible; a gate that wrongly opens costs one wasted run.
out="$(dep totally-unknown-dep)"; rc=$?
assert_eq "unknown dep -> exit 0 (fail-open)" "0" "$rc"
assert_contains "unknown dep -> warns loudly" "unknown dep" "$out"

# The dep name becomes a path component.
out="$(dep ../../etc/passwd)"; rc=$?
assert_eq "path traversal in dep name -> exit 1" "1" "$rc"
assert_contains "path traversal -> explains why" "invalid dep name" "$out"

printf '#!/bin/bash\nexit 0\n' > "$FAKE/scripts/lib/dep-checks/alive.sh"
chmod +x "$FAKE/scripts/lib/dep-checks/alive.sh"
dep alive >/dev/null 2>&1
assert_eq "drop-in check exit 0 -> reachable" "0" "$?"

printf '#!/bin/bash\necho "dep[dead]: nope" >&2\nexit 1\n' > "$FAKE/scripts/lib/dep-checks/dead.sh"
chmod +x "$FAKE/scripts/lib/dep-checks/dead.sh"
out="$(dep dead)"; rc=$?
assert_eq "drop-in check exit 1 -> unreachable" "1" "$rc"
assert_contains "drop-in stderr reaches the caller" "nope" "$out"

# A check the user wrote but forgot to chmod +x. Fail-open, but say so — the
# gate is inert and they need to know.
printf '#!/bin/bash\nexit 1\n' > "$FAKE/scripts/lib/dep-checks/unarmed.sh"
chmod -x "$FAKE/scripts/lib/dep-checks/unarmed.sh"
out="$(dep unarmed)"; rc=$?
assert_eq "non-executable drop-in -> exit 0 (fail-open)" "0" "$rc"
assert_contains "non-executable drop-in -> tells you to chmod +x" "not executable" "$out"

# The drop-in contract: these are documented as available.
printf '#!/bin/bash\n[ -n "$REPO_ROOT" ] && [ -n "$AGENT_OS_ENV_FILE" ] && [ -n "$DEP_TIMEOUT_SEC" ]\n' \
  > "$FAKE/scripts/lib/dep-checks/envcheck.sh"
chmod +x "$FAKE/scripts/lib/dep-checks/envcheck.sh"
AGENT_OS_ENV_FILE=/dev/null dep envcheck >/dev/null 2>&1
assert_eq "drop-in gets REPO_ROOT/AGENT_OS_ENV_FILE/DEP_TIMEOUT_SEC" "0" "$?"

# Built-in clickup, with no token anywhere: must not hang or crash — a clean 1.
# `env` cannot invoke the `dep` shell function, so this calls the script directly.
out="$(env -u CLICKUP_API_TOKEN -u CLICKUP_PERSONAL_TOKEN \
        REPO_ROOT="$FAKE" AGENT_OS_ENV_FILE=/dev/null \
        "$DEP_REACHABLE" clickup 2>&1)"; rc=$?
assert_eq "clickup without a token -> exit 1" "1" "$rc"
assert_contains "clickup without a token -> names the vars" "CLICKUP_API_TOKEN" "$out"

echo
echo "clickup_upsert.py — configuration is required, never guessed"

py() { env -u CLICKUP_API_TOKEN -u CLICKUP_PERSONAL_TOKEN -u CLICKUP_TEAM_ID \
        AGENT_OS_ENV_FILE=/dev/null PYTHONDONTWRITEBYTECODE=1 \
        python3 "$UPSERT_PY" "$@" 2>&1; }

out="$(py upsert --list-id L --gen g --key k --title t)"; rc=$?
assert_eq "no token -> exit 2, not a traceback" "2" "$rc"
assert_contains "no token -> names both accepted vars" "CLICKUP_PERSONAL_TOKEN" "$out"

out="$(CLICKUP_API_TOKEN=pk_fake py find --gen g --key k)"; rc=$?
assert_contains "no team id -> says so" "CLICKUP_TEAM_ID" "$out"

# Identity tag shape. This string IS the idempotency contract with ClickUp:
# change it and every managed task orphans at once.
out="$(PYTHONDONTWRITEBYTECODE=1 python3 -c "
import sys; sys.path.insert(0, '$REAL_REPO/scripts/lib')
import clickup_upsert as c
print(c._identity_tag('check-fire', 'morning-brief'))
")"
assert_eq "identity tag is upsert:<gen>:<key>" "upsert:check-fire:morning-brief" "$out"

# Token precedence, documented in .env.example.
out="$(CLICKUP_API_TOKEN=from_api CLICKUP_PERSONAL_TOKEN=from_personal \
       PYTHONDONTWRITEBYTECODE=1 python3 -c "
import sys; sys.path.insert(0, '$REAL_REPO/scripts/lib')
import clickup_upsert as c
print(c._token())
")"
assert_eq "CLICKUP_API_TOKEN wins over CLICKUP_PERSONAL_TOKEN" "from_api" "$out"

# The env file is the fallback for a systemd/Dagu context with a thin environment.
ENVF="$TMP/agent-os.env"
printf 'CLICKUP_PERSONAL_TOKEN="pk_from_file"\n' > "$ENVF"
out="$(env -u CLICKUP_API_TOKEN -u CLICKUP_PERSONAL_TOKEN \
       AGENT_OS_ENV_FILE="$ENVF" PYTHONDONTWRITEBYTECODE=1 python3 -c "
import sys; sys.path.insert(0, '$REAL_REPO/scripts/lib')
import clickup_upsert as c
print(c._token())
")"
assert_eq "falls back to the env file, quotes stripped" "pk_from_file" "$out"

echo
echo "syntax"
for f in "$CHECK_FIRE" "$FIRE_STEP" "$DEP_REACHABLE" "$REAL_REPO/scripts/lib/dep-checks/example.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
if PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile "$UPSERT_PY" 2>/dev/null; then
  ok "py_compile clickup_upsert.py"
else
  bad "py_compile clickup_upsert.py"
fi
for f in "$CHECK_FIRE" "$FIRE_STEP" "$DEP_REACHABLE"; do
  if [ -x "$f" ]; then ok "executable: $(basename "$f")"; else bad "executable: $(basename "$f")"; fi
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
