#!/bin/bash
# dep-reachable.sh — is dependency <dep> alive right now?
#
# The preflight gate behind check-fire's --require-dep. Answers one question with
# an exit code, cheaply enough to run on every cron tick.
#
# Usage: dep-reachable.sh <dep>
#   exit 0 = reachable (or unknown — see fail-open below)
#   exit 1 = unreachable, reason on stderr
#
# Built in:
#   clickup   one authenticated GET /user against the REST API
#
# Everything else is a drop-in: create scripts/lib/dep-checks/<dep>.sh, make it
# executable, exit 0/1. It is then usable as `--require-dep <dep>` with no change
# here. Integrations are per-install (your calendar backend is not everyone's),
# so they live as files rather than as branches in a case statement that grows
# forever. The check receives REPO_ROOT and AGENT_OS_ENV_FILE in its environment.
#
# Example — scripts/lib/dep-checks/calendar.sh:
#   #!/bin/bash
#   exec "$REPO_ROOT/scripts/calendar-agenda.sh" --today >/dev/null 2>&1
#
# **Unknown dep => exit 0 (fail-open), with a warning.** A typo in a routine must
# not silently freeze that check forever; a missing gate at worst wastes one run,
# while a mistakenly-closed gate is invisible until someone asks why the check
# stopped firing weeks ago. Loud-and-running beats quiet-and-stopped here.
#
# Config:
#   AGENT_OS_ENV_FILE   env file to read tokens from, default /etc/agent-os/agent-os.env
#   DEP_TIMEOUT_SEC     network probe timeout, default 10
set -uo pipefail

DEP="${1:-}"
if [ -z "$DEP" ]; then
  echo "dep-reachable: usage: dep-reachable.sh <dep>" >&2
  exit 1
fi

REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ENV_FILE="${AGENT_OS_ENV_FILE:-/etc/agent-os/agent-os.env}"
TIMEOUT="${DEP_TIMEOUT_SEC:-10}"

_env_value() {
  # $1 = key. Env var wins; the env file is the fallback.
  local key="$1" val="${!1:-}"
  if [ -z "$val" ] && [ -f "$ENV_FILE" ]; then
    val="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'" || true)"
  fi
  printf '%s' "$val"
}

check_clickup() {
  local tok
  tok="$(_env_value CLICKUP_API_TOKEN)"
  [ -n "$tok" ] || tok="$(_env_value CLICKUP_PERSONAL_TOKEN)"
  if [ -z "$tok" ]; then
    echo "dep-reachable[clickup]: no token — set CLICKUP_API_TOKEN or CLICKUP_PERSONAL_TOKEN in the environment or $ENV_FILE" >&2
    return 1
  fi
  python3 -c "
import sys, urllib.request, urllib.error
req = urllib.request.Request('https://api.clickup.com/api/v2/user',
                             headers={'Authorization': sys.argv[1]})
try:
    with urllib.request.urlopen(req, timeout=float(sys.argv[2])) as r:
        sys.exit(0 if r.status == 200 else 1)
except urllib.error.HTTPError as e:
    print(f'dep-reachable[clickup]: HTTP {e.code}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'dep-reachable[clickup]: {e}', file=sys.stderr)
    sys.exit(1)
" "$tok" "$TIMEOUT"
}

case "$DEP" in
  clickup) check_clickup ;;
  *)
    # Drop-in check. The name is a path component, so refuse anything that could
    # escape scripts/lib/dep-checks/.
    case "$DEP" in
      *[!a-zA-Z0-9_-]*)
        echo "dep-reachable: invalid dep name '$DEP' (allowed: letters, digits, '-', '_')" >&2
        exit 1
        ;;
    esac
    custom="$REPO/scripts/lib/dep-checks/$DEP.sh"
    if [ -x "$custom" ]; then
      REPO_ROOT="$REPO" AGENT_OS_ENV_FILE="$ENV_FILE" DEP_TIMEOUT_SEC="$TIMEOUT" \
        exec "$custom"
    fi
    if [ -f "$custom" ]; then
      echo "dep-reachable: '$custom' exists but is not executable (chmod +x it) — fail-open (exit 0)" >&2
      exit 0
    fi
    echo "dep-reachable: unknown dep '$DEP' — no built-in check and no $custom — fail-open (exit 0)" >&2
    exit 0
    ;;
esac
