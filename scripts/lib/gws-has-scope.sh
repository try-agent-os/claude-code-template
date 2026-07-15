#!/usr/bin/env bash
# gws-has-scope.sh — exit 0 if the current Google (gws) OAuth token carries ALL given scopes.
#
# Usage: scripts/lib/gws-has-scope.sh <scope> [<scope> ...]
#   A scope may be a full URL or just its tail (e.g. "auth/calendar", "calendar").
#
# Exit: 0 = every requested scope present
#       1 = at least one missing (the missing list goes to stderr)
#       2 = cannot read auth status at all (gws absent / not logged in / not JSON)
#
# WHY THIS EXISTS: an OAuth token can be perfectly VALID and still be useless for
# what you need — the consent screen granted read-only scopes, or a re-consent
# quietly dropped one. The symptom is a 403 ACCESS_TOKEN_SCOPE_INSUFFICIENT deep
# inside a routine, long after the cron already spawned an agent that cannot
# possibly succeed. Use this as a PRECONDITION GATE so the fleet does not spawn
# work against a dependency it has no permission to touch:
#
#   scripts/lib/gws-has-scope.sh auth/calendar || exit 0   # skip, don't fail
#
# The gate is self-healing: re-consent with the missing scope and it opens on the
# next run with no code change. Exit 2 is deliberately distinct from 1 so a caller
# can tell "no permission" (a real gate) from "cannot tell" (a broken probe).
#
# See also scripts/integration-liveness.sh, which probes the same status blob on a
# schedule and alerts when a scope disappears. This script is the synchronous gate;
# that one is the background watchdog.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") <scope> [<scope> ...]" >&2
  exit 2
fi

GWS="${GWS_BIN:-$(command -v gws 2>/dev/null || echo gws)}"
command -v python3 >/dev/null 2>&1 || { echo "gws-has-scope: python3 required" >&2; exit 2; }

STATUS="$("$GWS" auth status 2>/dev/null)"
[ -n "$STATUS" ] || { echo "gws-has-scope: cannot read '$GWS auth status'" >&2; exit 2; }

printf '%s' "$STATUS" | python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.stderr.write("gws-has-scope: auth status is not JSON\n")
    sys.exit(2)
if not isinstance(data, dict):
    sys.stderr.write("gws-has-scope: auth status is not an object\n")
    sys.exit(2)

have = data.get("scopes") or []
want = sys.argv[1:]
# Scopes are full URLs; a caller may pass a tail ("auth/calendar") or the whole URL.
missing = [w for w in want if not any(w == s or str(s).endswith(w) or w in str(s) for s in have)]
if missing:
    sys.stderr.write("missing gws scopes: " + ", ".join(missing) + "\n")
    sys.exit(1)
sys.exit(0)
' "$@"
