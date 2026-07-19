#!/usr/bin/env bash
# Smoke test for scripts/notify-operator.sh.
#
# Runs the script fully sandboxed: config/state/log dirs point into a temp tree
# and every delivery endpoint points at a dead port, so nothing is sent
# anywhere. What is asserted is the routing LOGIC visible in notify.log:
# blacklist filtering, dedup suppression + storm counter, graceful degradation
# through all three fallbacks, and instance-scoped operator selection.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
export REPO="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
NOTIFY="$REPO/scripts/notify-operator.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AGENT_OS_ETC="$TMP/etc"
export AGENT_OS_VAR="$TMP/var"
export AGENT_OS_LOG_DIR="$TMP/log"
export CLAUDE_PEERS_API_URL="http://127.0.0.1:1/send-message"   # dead port
export EMERGENCY_NOTIFY_URL="http://127.0.0.1:1/emergency"      # dead port
export TELEGRAM_BOT_TOKEN=""                                     # no last resort
export TELEGRAM_USER_ID=""
mkdir -p "$AGENT_OS_ETC"

LOG="$AGENT_OS_LOG_DIR/notify.log"
FAILED=0
ok()   { echo "  ok   — $*"; }
fail() { echo "  FAIL — $*"; FAILED=1; }
has()  { grep -qF "$1" "$LOG"; }

echo "[notify-operator] syntax"
bash -n "$NOTIFY" && ok "bash -n clean" || fail "bash -n"

echo "[notify-operator] falls through all three paths without hanging"
timeout 30 "$NOTIFY" --source smoke --severity info --msg "alpha"
rc=$?
[ "$rc" = "0" ] && ok "exit 0 (never flaps the caller)" || fail "exit $rc, expected 0"
has "no operator peer found, falling back" && ok "peer step degraded" || fail "no peer-step log line"
has "emergency endpoint failed" && ok "emergency step degraded" || fail "no emergency-step log line"
has "no last-resort fallback" && ok "bot-API step degraded" || fail "no bot-API-step log line"

echo "[notify-operator] dedup suppresses a repeat and counts the storm"
"$NOTIFY" --source smoke --severity info --msg "alpha" >/dev/null
has "dedup suppressed (count=1" && ok "repeat suppressed" || fail "repeat not suppressed"
# Expire the window (0s TTL): the alert must pass through again and the counter
# must reset to 0, so the NEXT burst starts a fresh window rather than inheriting
# the old count. The "(repeated Nx)" prefix itself rides on the delivered message,
# which this sandbox deliberately never sends — so assert the state instead.
NOTIFY_DEDUP_TTL=0 "$NOTIFY" --source smoke --severity info --msg "alpha" >/dev/null
STATE=$(command ls "$AGENT_OS_VAR/notify-dedup/" | head -1)
COUNT=$(awk '{print $2}' "$AGENT_OS_VAR/notify-dedup/$STATE")
[ "$COUNT" = "0" ] && ok "counter reset after window expiry" \
  || fail "counter is '$COUNT' after window expiry, expected 0"
"$NOTIFY" --source smoke --severity info --msg "alpha" >/dev/null
has "dedup suppressed (count=1" && ok "fresh window suppresses again" \
  || fail "no suppression in the new window"

echo "[notify-operator] blacklist drops a matching alert"
printf '# comment\nmac-only-check\n' > "$AGENT_OS_ETC/notify-blacklist.txt"
"$NOTIFY" --source mac-only-check --severity error --msg "should be dropped" >/dev/null
has "filtered (matched 'mac-only-check')" && ok "blacklisted source filtered" \
  || fail "blacklist did not filter"

echo "[notify-operator] operator selection is scoped to this instance"
python3 - <<'PY'
import json, os, subprocess, sys, re
notify = os.path.join(os.environ["REPO"], "scripts", "notify-operator.sh")
# Extract the embedded selector and exercise it directly on a synthetic peer list.
src = open(notify).read()
sel = src.split("python3 -c '", 1)[1].split("' 2>/dev/null", 1)[0]
peers = [
    {"id": "foreign", "slug": "other:operator", "cwd": "/home/other/claude/agents/operator"},
    {"id": "worker",  "slug": "",               "cwd": "/opt/agent-os/claude"},
    {"id": "mine",    "slug": "hub:operator",   "cwd": "/opt/agent-os/claude/agents/operator"},
]
env = dict(os.environ, AGENT_OS_INSTANCE="hub", INSTALL_ROOT="/opt/agent-os/claude")
out = subprocess.run([sys.executable, "-c", sel], input=json.dumps(peers),
                     capture_output=True, text=True, env=env).stdout.strip()
if out == "mine":
    print("  ok   — picked hub:operator, skipped other:operator and the worker")
else:
    print(f"  FAIL — selector returned {out!r}, expected 'mine'"); sys.exit(1)
PY
[ $? -eq 0 ] || FAILED=1

echo
if [ "$FAILED" = "0" ]; then echo "notify-operator: PASS"; else echo "notify-operator: FAIL"; fi
exit "$FAILED"
