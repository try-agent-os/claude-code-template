#!/usr/bin/env bash
# Self-test for scripts/integration-liveness.sh + scripts/lib/gws-has-scope.sh. Usage:
#   tests/integration-liveness/run.sh        # run all cases, exit 0 if all pass, 1 if any fail
#   tests/integration-liveness/run.sh -v     # verbose (print probe output per case)
#
# HERMETIC BY CONSTRUCTION: no case touches a real integration. CLI probes run
# against fake CLIs written into a tmpdir; HTTP probes run against a throwaway
# python server on 127.0.0.1. So this passes on a clean checkout with no network,
# no credentials, and no gws installed.
#
# WHAT THESE CASES PIN: this probe is a watchdog whose failure mode is silent in
# BOTH directions — a broken matcher reports everything alive (a dead credential
# rots undetected), and an over-eager one reports a live credential dead (the
# alert becomes noise and gets muted). So the cases pin the properties that make
# the verdict trustworthy: alive/dead/inconclusive are three distinct outcomes,
# a 500 is never "dead", alerts fire only on state CHANGE, and no secret value
# ever reaches the manifest. All tokens here are FAKE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/integration-liveness.sh"
SCOPE_GATE="$REPO_ROOT/scripts/lib/gws-has-scope.sh"

VERBOSE=0
{ [ "${1:-}" = "-v" ] || [ "${1:-}" = "--verbose" ]; } && VERBOSE=1

for f in "$PROBE" "$SCOPE_GATE"; do
  [ -x "$f" ] || { echo "FAIL: $f missing or not executable" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

TMP="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0

# --- fake CLIs ---------------------------------------------------------------
# Each prints a canned status blob, standing in for a real integration CLI.
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gws-alive" <<'SH'
#!/usr/bin/env bash
echo '{"token_valid": true, "scopes": ["https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/spreadsheets"]}'
SH

cat > "$TMP/bin/gws-expired" <<'SH'
#!/usr/bin/env bash
echo '{"token_valid": false, "token_error": "invalid_grant", "scopes": []}'
SH

cat > "$TMP/bin/gws-noscope" <<'SH'
#!/usr/bin/env bash
echo '{"token_valid": true, "scopes": ["https://www.googleapis.com/auth/drive.readonly"]}'
SH

cat > "$TMP/bin/gws-garbage" <<'SH'
#!/usr/bin/env bash
echo 'command not found: totally not json'
SH

cat > "$TMP/bin/cli-ok" <<'SH'
#!/usr/bin/env bash
echo 'connection: acme  status: ACTIVE'
SH

# Exits 0 while printing 401 — the exact shape rc-only checks miss.
cat > "$TMP/bin/cli-401" <<'SH'
#!/usr/bin/env bash
echo 'ERROR: 401 Unauthorized (api key revoked)'
exit 0
SH

chmod +x "$TMP/bin"/*

# --- fake HTTP endpoint ------------------------------------------------------
# /ok -> 200, /dead -> 401, /boom -> 500. Lets the http probe be tested for real
# (headers, status mapping) with zero network.
cat > "$TMP/server.py" <<'PY'
import http.server, socketserver, sys, threading

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = {"/ok": 200, "/dead": 401, "/boom": 500}.get(self.path, 404)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{}')
    def log_message(self, *a):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    port = srv.server_address[1]
    with open(sys.argv[1], "w") as f:
        f.write(str(port))
    srv.serve_forever()
PY

python3 "$TMP/server.py" "$TMP/port" &
HTTP_PID=$!
for _ in $(seq 1 50); do
  [ -s "$TMP/port" ] && break
  sleep 0.1
done
[ -s "$TMP/port" ] || { echo "FAIL: test http server did not start" >&2; exit 1; }
PORT="$(cat "$TMP/port")"
BASE="http://127.0.0.1:$PORT"

# --- helpers -----------------------------------------------------------------
# write_config <file> <integrations-json>
write_config() {
  local file="$1" body="$2" manifest="$3"
  cat > "$file" <<JSON
{ "manifest": "$manifest", "integrations": $body }
JSON
}

# check <name> <expected_exit> <integrations-json> [must_contain] [must_not_contain] [manifest_must_contain]
# Each case gets a FRESH manifest, so "new dead" is judged against no history.
# An alive/inconclusive verdict prints no alert (only a dead one does), so its
# detail is asserted against the MANIFEST via the 6th arg rather than stdout.
check() {
  local name="$1" want="$2" body="$3" want_sub="${4:-}" deny_sub="${5:-}" manifest_sub="${6:-}"
  local cfg="$TMP/cfg.$$.json" manifest="$TMP/manifest.$$.json" out rc
  rm -f "$manifest"
  write_config "$cfg" "$body" "$manifest"
  out="$(PATH="$TMP/bin:$PATH" INTEGRATION_LIVENESS_CONFIG="$cfg" LIVENESS_NO_NOTIFY=1 \
         AGENT_OS_ENV_FILE="$TMP/nonexistent.env" "$PROBE" 2>&1)"
  rc=$?
  local err=""
  [ "$rc" != "$want" ] && err="exit $rc, want $want"
  if [ -n "$want_sub" ] && ! printf '%s' "$out" | grep -qF -- "$want_sub"; then
    err="${err:+$err; }missing '$want_sub'"
  fi
  if [ -n "$deny_sub" ] && printf '%s' "$out" | grep -qF -- "$deny_sub"; then
    err="${err:+$err; }output contained '$deny_sub'"
  fi
  if [ -n "$manifest_sub" ] && ! grep -qF -- "$manifest_sub" "$manifest" 2>/dev/null; then
    err="${err:+$err; }manifest missing '$manifest_sub'"
  fi
  if [ -z "$err" ]; then
    PASS=$((PASS + 1)); echo "  ok   $name"
    [ "$VERBOSE" = 1 ] && [ -n "$out" ] && printf '         %s\n' "$out"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name -- $err"
    printf '         output: %s\n' "${out:-<empty>}"
  fi
  rm -f "$cfg" "$manifest"
  return 0
}

# expect_rc <name> <expected_exit> <cmd...>
expect_rc() {
  local name="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok   $name"
    [ "$VERBOSE" = 1 ] && [ -n "$out" ] && printf '         %s\n' "$out"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name -- exit $rc, want $want"
    printf '         output: %s\n' "${out:-<empty>}"
  fi
  return 0
}

echo "integration-liveness self-test"

# --- unconfigured install is not a failure -----------------------------------
expect_rc "no config -> 0 (no-op, not a failure)" 0 \
  env INTEGRATION_LIVENESS_CONFIG="$TMP/does-not-exist.json" "$PROBE"

# --- command_json: the token-valid + scopes shape -----------------------------
check "command_json alive -> 0" 0 \
  '{"google": {"kind": "command_json", "argv": ["gws-alive", "auth", "status"],
     "assert": {"true": ["token_valid"], "list_contains": {"scopes": ["calendar"]}}}}' \
  '"dead": []'

check "command_json expired token -> 2 (dead, reports the error)" 2 \
  '{"google": {"kind": "command_json", "argv": ["gws-expired", "auth", "status"],
     "assert": {"true": ["token_valid"]},
     "remediation": "gws auth login"}}' \
  'invalid_grant'

# The nastiest decay: token VALID, scope silently dropped. Must still be dead.
check "command_json valid token but missing scope -> 2" 2 \
  '{"google": {"kind": "command_json", "argv": ["gws-noscope", "auth", "status"],
     "assert": {"true": ["token_valid"], "list_contains": {"scopes": ["calendar"]}}}}' \
  'scopes missing calendar'

# Unreadable status is INCONCLUSIVE, not dead — a broken probe must not cry wolf.
check "command_json non-JSON output -> 0 (inconclusive, not dead)" 0 \
  '{"google": {"kind": "command_json", "argv": ["gws-garbage", "auth", "status"],
     "assert": {"true": ["token_valid"]}}}' \
  '"dead": []'

check "command_json missing binary -> 0 (inconclusive, not dead)" 0 \
  '{"google": {"kind": "command_json", "argv": ["definitely-not-installed", "status"],
     "assert": {"true": ["token_valid"]}}}' \
  '"dead": []'

# --- command: rc + dead_patterns ---------------------------------------------
check "command rc=0 clean -> 0 (alive)" 0 \
  '{"svc": {"kind": "command", "argv": ["cli-ok", "connections", "list"]}}' \
  '"dead": []'

check "command exits 0 but prints 401 -> 2 (dead)" 2 \
  '{"svc": {"kind": "command", "argv": ["cli-401", "connections", "list"],
     "dead_patterns": ["401", "unauthorized"]}}' \
  '"new_dead": ["svc"]'

# --- http: status mapping -----------------------------------------------------
check "http 200 -> 0 (alive)" 0 \
  "{\"api\": {\"kind\": \"http\", \"url\": \"$BASE/ok\"}}" \
  '"dead": []'

check "http 401 -> 2 (dead)" 2 \
  "{\"api\": {\"kind\": \"http\", \"url\": \"$BASE/dead\",
     \"remediation\": \"rotate the key\"}}" \
  'rotate the key'

# A 500 means the SERVICE is broken, not that the credential is revoked.
# Reporting it dead would page you to rotate a key that is perfectly fine.
check "http 500 -> 0 (inconclusive, NOT dead)" 0 \
  "{\"api\": {\"kind\": \"http\", \"url\": \"$BASE/boom\"}}" \
  '"dead": []'

check "http with unset token_env -> 0 (inconclusive, not dead)" 0 \
  "{\"api\": {\"kind\": \"http\", \"url\": \"$BASE/ok\", \"token_env\": \"NO_SUCH_TOKEN_VAR\"}}" \
  '"dead": []' '' 'NO_SUCH_TOKEN_VAR not set'

# --- declared-but-not-probed --------------------------------------------------
check "not_probed -> 0, listed but never dead" 0 \
  '{"whoop": {"kind": "not_probed", "detail": "not probed (MCP-only, no CLI)"}}' \
  '"dead": []'

# --- config errors are inconclusive, never dead -------------------------------
check "unknown kind -> 0 (config error, not dead)" 0 \
  '{"svc": {"kind": "telepathy"}}' \
  '"dead": []'

check "disabled entry is skipped -> 0" 0 \
  '{"svc": {"kind": "command", "argv": ["cli-401"], "dead_patterns": ["401"], "enabled": false}}' \
  '"dead": []'

# --- one bad probe must not sink the sweep ------------------------------------
check "bad entry alongside a dead one -> 2 (sweep continues)" 2 \
  '{"broken": "not-an-object",
    "svc": {"kind": "command", "argv": ["cli-401"], "dead_patterns": ["401"]}}' \
  '"new_dead": ["svc"]'

# --- state change: alert on NEW dead only ------------------------------------
# The property that keeps the alert readable: a chronically-dead integration
# must go quiet after the first alarm, or the noise gets it muted.
state_change_case() {
  local cfg="$TMP/sc.json" manifest="$TMP/sc-manifest.json" out1 rc1 out2 rc2
  rm -f "$manifest"
  write_config "$cfg" \
    '{"svc": {"kind": "command", "argv": ["cli-401"], "dead_patterns": ["401"]}}' "$manifest"
  out1="$(PATH="$TMP/bin:$PATH" INTEGRATION_LIVENESS_CONFIG="$cfg" LIVENESS_NO_NOTIFY=1 "$PROBE" 2>&1)"; rc1=$?
  out2="$(PATH="$TMP/bin:$PATH" INTEGRATION_LIVENESS_CONFIG="$cfg" LIVENESS_NO_NOTIFY=1 "$PROBE" 2>&1)"; rc2=$?
  local err=""
  [ "$rc1" != 2 ] && err="first run exit $rc1, want 2"
  [ "$rc2" != 0 ] && err="${err:+$err; }second run exit $rc2, want 0 (already-known dead must not re-alert)"
  printf '%s' "$out2" | grep -qF '"new_dead": []' || err="${err:+$err; }second run should report no new_dead"
  # The manifest must still record it as dead — quiet is not the same as healed.
  python3 -c "
import json, sys
m = json.load(open('$manifest'))
sys.exit(0 if m.get('dead') == ['svc'] else 1)
" || err="${err:+$err; }manifest lost the dead entry"
  if [ -z "$err" ]; then
    PASS=$((PASS + 1)); echo "  ok   state change: alerts on new dead, silent on known dead"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL state change -- $err"
  fi
  rm -f "$cfg" "$manifest"
}
state_change_case

# --- recovery: dead -> alive clears the manifest ------------------------------
recovery_case() {
  local cfg="$TMP/rec.json" manifest="$TMP/rec-manifest.json" err=""
  rm -f "$manifest"
  write_config "$cfg" \
    '{"svc": {"kind": "command", "argv": ["cli-401"], "dead_patterns": ["401"]}}' "$manifest"
  PATH="$TMP/bin:$PATH" INTEGRATION_LIVENESS_CONFIG="$cfg" LIVENESS_NO_NOTIFY=1 "$PROBE" >/dev/null 2>&1
  write_config "$cfg" \
    '{"svc": {"kind": "command", "argv": ["cli-ok"], "dead_patterns": ["401"]}}' "$manifest"
  PATH="$TMP/bin:$PATH" INTEGRATION_LIVENESS_CONFIG="$cfg" LIVENESS_NO_NOTIFY=1 "$PROBE" >/dev/null 2>&1
  local rc=$?
  [ "$rc" != 0 ] && err="recovered run exit $rc, want 0"
  python3 -c "
import json, sys
m = json.load(open('$manifest'))
sys.exit(0 if m.get('dead') == [] and m['integrations']['svc']['alive'] is True else 1)
" || err="${err:+$err; }manifest did not clear the recovered integration"
  if [ -z "$err" ]; then
    PASS=$((PASS + 1)); echo "  ok   recovery: dead -> alive clears the manifest"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL recovery -- $err"
  fi
  rm -f "$cfg" "$manifest"
}
recovery_case

# --- secrets must never reach the manifest ------------------------------------
secret_case() {
  local cfg="$TMP/sec.json" manifest="$TMP/sec-manifest.json" err=""
  # A sentinel, deliberately NOT credential-shaped: the assertion only needs a
  # unique string to trace, and a realistic token shape would trip secret
  # scanners on every PR for no added coverage.
  local sentinel="liveness-selftest-sentinel-must-not-be-logged"
  rm -f "$manifest"
  write_config "$cfg" \
    "{\"api\": {\"kind\": \"http\", \"url\": \"$BASE/ok\", \"token_env\": \"LIVENESS_TEST_TOKEN\",
       \"headers\": {\"Authorization\": \"Bearer {token}\"}}}" "$manifest"
  local out
  out="$(LIVENESS_TEST_TOKEN="$sentinel" INTEGRATION_LIVENESS_CONFIG="$cfg" \
         LIVENESS_NO_NOTIFY=1 "$PROBE" 2>&1)"
  printf '%s' "$out" | grep -qF "$sentinel" && err="token value leaked into stdout"
  grep -qF "$sentinel" "$manifest" 2>/dev/null && err="${err:+$err; }token value leaked into the manifest"
  if [ -z "$err" ]; then
    PASS=$((PASS + 1)); echo "  ok   secrets: token value never reaches stdout or the manifest"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL secrets -- $err"
  fi
  rm -f "$cfg" "$manifest"
}
secret_case

# --- gws-has-scope gate -------------------------------------------------------
echo "gws-has-scope self-test"
expect_rc "scope present -> 0" 0 \
  env GWS_BIN="$TMP/bin/gws-alive" "$SCOPE_GATE" auth/calendar
expect_rc "scope tail match -> 0" 0 \
  env GWS_BIN="$TMP/bin/gws-alive" "$SCOPE_GATE" calendar spreadsheets
expect_rc "full scope URL -> 0" 0 \
  env GWS_BIN="$TMP/bin/gws-alive" "$SCOPE_GATE" https://www.googleapis.com/auth/calendar
expect_rc "missing scope -> 1" 1 \
  env GWS_BIN="$TMP/bin/gws-alive" "$SCOPE_GATE" auth/gmail.send
expect_rc "one of many missing -> 1" 1 \
  env GWS_BIN="$TMP/bin/gws-alive" "$SCOPE_GATE" calendar auth/tasks
expect_rc "read-only token lacks calendar -> 1" 1 \
  env GWS_BIN="$TMP/bin/gws-noscope" "$SCOPE_GATE" auth/calendar
# Exit 2 must stay distinct from 1: "cannot tell" is not "no permission".
expect_rc "non-JSON status -> 2 (cannot tell != no permission)" 2 \
  env GWS_BIN="$TMP/bin/gws-garbage" "$SCOPE_GATE" auth/calendar
expect_rc "gws missing -> 2" 2 \
  env GWS_BIN="$TMP/bin/definitely-not-installed" "$SCOPE_GATE" auth/calendar
expect_rc "no args -> 2 (usage)" 2 \
  env GWS_BIN="$TMP/bin/gws-alive" "$SCOPE_GATE"

echo
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
