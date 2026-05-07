#!/usr/bin/env bash
# Hook test runner. Usage:
#   tests/hooks/run.sh             # run all fixtures, exit 0 if all pass, 1 if any fail
#   tests/hooks/run.sh fixture.json # run one fixture
#   tests/hooks/run.sh -v          # verbose output
#
# Each fixture is a JSON file with:
#   - hook payload fields (Claude Code passes via stdin)
#   - "_test" object: { hook: "<name>", expected_exit: N, expected_stderr_contains: "...", args: [...] }
#
# Runner pipes fixture content (sans _test) to .claude/hooks/<name>.sh, captures exit + stderr,
# compares against _test expectations.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.claude/hooks"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

VERBOSE=0
SINGLE_FIXTURE=""

for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *.json) SINGLE_FIXTURE="$arg" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

# Color
if [ -t 1 ]; then
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  CYAN="$(tput setaf 6)"
  RESET="$(tput sgr0)"
else
  RED="" ; GREEN="" ; YELLOW="" ; CYAN="" ; RESET=""
fi

PASS=0
FAIL=0
TOTAL=0
FAILED_NAMES=""

run_fixture() {
  local fixture="$1"
  local name="$(basename "$fixture" .json)"

  TOTAL=$((TOTAL + 1))

  local payload="$(jq 'del(._test)' "$fixture")"
  local hook="$(jq -r '._test.hook' "$fixture")"
  local expected_exit="$(jq -r '._test.expected_exit // 0' "$fixture")"
  local expected_stderr="$(jq -r '._test.expected_stderr_contains // empty' "$fixture")"
  local args_json="$(jq -c '._test.args // []' "$fixture")"

  if [ -z "$hook" ] || [ "$hook" = "null" ]; then
    printf '%s%s%s %s — missing _test.hook field\n' "$YELLOW" "[SKIP]" "$RESET" "$name"
    return
  fi

  local hook_script="$HOOKS_DIR/${hook}.sh"
  if [ ! -x "$hook_script" ]; then
    printf '%s%s%s %s — hook script not executable: %s\n' "$RED" "[FAIL]" "$RESET" "$name" "$hook_script"
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
    return
  fi

  # Build args as a flat string (bash 3.2 + set -u safe; no empty-array expansion gotcha)
  local args_str
  args_str="$(jq -r '.[]' <<< "$args_json" | tr '\n' ' ')"

  # Run hook with payload via stdin, capture stdout/stderr/exit
  local stdout_file
  local stderr_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  local actual_exit=0

  # CLAUDE_PROJECT_DIR set to repo root so hooks can resolve relative paths.
  # eval used here so args_str expands as separate words (we control the JSON content, no injection risk).
  CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    eval "\"\$hook_script\" $args_str" \
      > "$stdout_file" \
      2> "$stderr_file" \
      <<< "$payload" \
    || actual_exit=$?

  local stdout_content="$(cat "$stdout_file")"
  local stderr_content="$(cat "$stderr_file")"
  rm -f "$stdout_file" "$stderr_file"

  # Compare exit code
  local ok=1
  local reason=""

  if [ "$actual_exit" != "$expected_exit" ]; then
    ok=0
    reason="exit=$actual_exit expected=$expected_exit"
  fi

  # Compare stderr contains
  if [ -n "$expected_stderr" ]; then
    if ! printf '%s' "$stderr_content" | grep -qF "$expected_stderr"; then
      ok=0
      reason="${reason:+$reason; }stderr missing '$expected_stderr'"
    fi
  fi

  if [ "$ok" -eq 1 ]; then
    printf '%s%s%s %s\n' "$GREEN" "[PASS]" "$RESET" "$name"
    PASS=$((PASS + 1))
    if [ "$VERBOSE" -eq 1 ]; then
      [ -n "$stdout_content" ] && echo "  stdout: $stdout_content" | head -c 200
      echo
    fi
  else
    printf '%s%s%s %s — %s\n' "$RED" "[FAIL]" "$RESET" "$name" "$reason"
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
    if [ "$VERBOSE" -eq 1 ]; then
      echo "  stderr: $stderr_content"
      echo "  stdout: $stdout_content"
    fi
  fi
}

# Main
if [ -n "$SINGLE_FIXTURE" ]; then
  if [ ! -f "$SINGLE_FIXTURE" ]; then
    echo "fixture not found: $SINGLE_FIXTURE" >&2
    exit 1
  fi
  run_fixture "$SINGLE_FIXTURE"
else
  printf '%sRunning hook tests%s from %s\n\n' "$CYAN" "$RESET" "$FIXTURES_DIR"
  for fixture in "$FIXTURES_DIR"/*.json; do
    [ -f "$fixture" ] || continue
    run_fixture "$fixture"
  done
fi

echo
printf '%sResults%s: %s%d pass%s, %s%d fail%s, %d total\n' \
  "$CYAN" "$RESET" \
  "$GREEN" "$PASS" "$RESET" \
  "${RED}${FAIL:+$RED}" "$FAIL" "$RESET" \
  "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  printf '\nFailed:%s\n' "$FAILED_NAMES"
  exit 1
fi
exit 0
