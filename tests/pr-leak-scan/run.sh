#!/usr/bin/env bash
# Self-test for scripts/pr-leak-scan.sh. Usage:
#   tests/pr-leak-scan/run.sh        # run all cases, exit 0 if all pass, 1 if any fail
#   tests/pr-leak-scan/run.sh -v     # verbose (print scanner output per case)
#
# Each case feeds a synthetic diff to the scanner with a fixed test config and
# asserts the EXIT CODE (0 clean / 2 leak / 3 review / 1 error) plus, where it
# matters, what the output must and must NOT contain.
#
# The scanner is a security gate, so the cases below pin the properties that make
# it trustworthy rather than just "it finds a token": added-vs-removed asymmetry,
# secret masking, line numbers, and the allowlist. Credentials here are FAKE —
# syntactically valid shapes, never real.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCANNER="$REPO_ROOT/scripts/pr-leak-scan.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] || [ "${1:-}" = "--verbose" ] && VERBOSE=1

if [ ! -x "$SCANNER" ]; then
  echo "FAIL: $SCANNER missing or not executable" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Test identities — deliberately fictional (RFC 5737 / RFC 2606 reserved ranges).
CONFIG="$TMP/config.json"
cat > "$CONFIG" <<'JSON'
{
  "identity": {
    "names": ["Jane Doe", "Doe"],
    "domains": ["jane-doe.dev"],
    "handles": ["@janedoe"],
    "ips": ["203.0.113.10"],
    "literals": ["987654321"],
    "regexes": ["\\+1[\\s.-]?\\d{3}[\\s.-]?\\d{3}[\\s.-]?\\d{4}"]
  },
  "soft": {
    "hosts": ["my-vps-01"],
    "slugs": ["acme-corp"],
    "regexes": ["/opt/my-org(?:/claude)?\\b"]
  },
  "allow": ["(?i)\\bplaceholder\\b"],
  "skip_files": ["^vendor/"]
}
JSON

PASS=0
FAIL=0

# check <name> <expected_exit> <diff> [must_contain] [must_not_contain]
check() {
  local name="$1" want="$2" diff="$3" want_sub="${4:-}" deny_sub="${5:-}"
  local out rc
  out="$(printf '%s' "$diff" | PR_LEAK_SCAN_CONFIG="$CONFIG" "$SCANNER" 2>&1)"
  rc=$?

  local err=""
  [ "$rc" != "$want" ] && err="exit $rc, want $want"
  if [ -n "$want_sub" ] && ! printf '%s' "$out" | grep -qF -- "$want_sub"; then
    err="${err:+$err; }missing '$want_sub'"
  fi
  if [ -n "$deny_sub" ] && printf '%s' "$out" | grep -qF -- "$deny_sub"; then
    err="${err:+$err; }leaked '$deny_sub' into output"
  fi

  if [ -z "$err" ]; then
    PASS=$((PASS + 1))
    echo "  ok   $name"
    [ "$VERBOSE" = 1 ] && [ -n "$out" ] && printf '         %s\n' "$out"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name -- $err"
    printf '         output: %s\n' "${out:-<empty>}"
  fi
  return 0
}

# A diff header + hunk wrapper, so cases stay readable.
d() { printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,2 +1,3 @@\n%s\n' "$1" "$1" "$1" "$1" "$2"; }

echo "pr-leak-scan self-test"

# --- clean -------------------------------------------------------------------
check "clean diff -> 0" 0 \
  "$(d README.md ' context line
+A generic sentence about the installer.')"

check "no findings -> empty output" 0 \
  "$(d docs/a.md '+Nothing personal here.')" \
  "" "|"

# --- built-in secrets (CRITICAL -> 2), no config needed for these -------------
check "github token -> 2" 2 \
  "$(d src/app.js '+const t = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB";')" \
  "CRITICAL|github-token"

check "secret VALUE is masked, never printed in full" 2 \
  "$(d src/app.js '+const t = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB";')" \
  "CRITICAL|github-token" \
  "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"

check "private key block -> 2" 2 \
  "$(d id_rsa '+-----BEGIN OPENSSH PRIVATE KEY-----')" \
  "CRITICAL|private-key-block"

check "assigned secret -> 2" 2 \
  "$(d .env.example "+API_KEY='a1b2c3d4e5f6g7h8i9j0k1l2'")" \
  "CRITICAL|assigned-secret"

check "secrets caught with NO config at all" 2 \
  "$(d src/app.js '+aws = "AKIAIOSFODNN7EXAMPLE"')" \
  "CRITICAL|aws-access-key"

# --- identity from config (HIGH -> 2) ----------------------------------------
check "configured name -> 2" 2 \
  "$(d docs/x.md '+Maintained by Jane Doe.')" \
  "HIGH|identity-names"

check "configured domain -> 2" 2 \
  "$(d docs/x.md '+See https://jane-doe.dev/setup')" \
  "HIGH|identity-domains"

check "configured handle -> 2" 2 \
  "$(d docs/x.md '+ping @janedoe on telegram')" \
  "HIGH|identity-handles"

check "configured ip -> 2" 2 \
  "$(d systemd/x.service '+Host=203.0.113.10')" \
  "HIGH|identity-ips"

check "configured literal id -> 2" 2 \
  "$(d scripts/x.sh '+CHAT_ID=987654321')" \
  "HIGH|identity-literals"

check "identity regex (phone) -> 2" 2 \
  "$(d docs/x.md '+call +1 555 010 1234')" \
  "HIGH|identity-regexes"

check "real email -> 2" 2 \
  "$(d docs/x.md '+contact me at someone@realdomain.io')" \
  "HIGH|email-address"

check "example.com email is NOT a finding" 0 \
  "$(d docs/x.md '+contact user@example.com for help')"

check "noreply email is NOT a finding" 0 \
  "$(d .github/x.yml '+git config user.email 12345+bot@users.noreply.github.com')"

# --- soft / MEDIUM -> 3 ------------------------------------------------------
check "soft host alone -> 3 (review)" 3 \
  "$(d docs/x.md '+deployed on my-vps-01 last year')" \
  "MEDIUM|soft-hosts"

check "soft slug alone -> 3" 3 \
  "$(d docs/x.md '+the acme-corp workspace')" \
  "MEDIUM|soft-slugs"

check "soft path regex alone -> 3" 3 \
  "$(d routines/x.yaml '+  working_dir: /opt/my-org/claude')" \
  "MEDIUM|soft-regexes"

check "CRITICAL outranks MEDIUM -> 2" 2 \
  "$(d src/x.js '+// on my-vps-01
+const k = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB";')" \
  "CRITICAL|github-token"

# --- the added-vs-removed asymmetry (core rule) ------------------------------
check "REMOVED secret is not a leak -> 0" 0 \
  "$(d src/app.js '-const t = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB";
+const t = process.env.GH_TOKEN;')"

check "REMOVED identity is not a leak -> 0" 0 \
  "$(d docs/x.md '-Maintained by Jane Doe.
+Maintained by the community.')"

check "'+++' header is not scanned as an added line" 0 \
  "$(printf 'diff --git a/Doe b/Doe\n--- a/Doe\n+++ b/Doe\n@@ -1 +1 @@\n+clean content\n')"

# --- allowlist ---------------------------------------------------------------
check "allowlisted line is skipped -> 0" 0 \
  "$(d docs/x.md '+Jane Doe is a placeholder name in this example.')"

# --- skip_files --------------------------------------------------------------
# This scanner's own fixtures must contain fake credentials to test the matchers,
# so a built-in skip keeps the gate from flagging itself on every PR that edits
# them. Without it, pr-leak-scan-fire.sh reports a LEAK on this very file.
check "own fixtures are skipped (built-in) -> 0" 0 \
  "$(d tests/pr-leak-scan/run.sh '+  local t="ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"')"

check "example config file is skipped (built-in) -> 0" 0 \
  "$(d .pr-leak-scan.example.json '+    \"emails\": [\"jane@jane-doe.dev\"],')"

check "configured skip_files path -> 0" 0 \
  "$(d vendor/sample.js '+const k = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB";')"

check "skip is path-scoped, not global -> 2" 2 \
  "$(d src/real.js '+const k = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB";')" \
  "CRITICAL|github-token"

# --- line numbers ------------------------------------------------------------
check "reports correct new-file line number" 2 \
  "$(printf 'diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -10,3 +10,4 @@\n ctx\n ctx\n+Jane Doe was here\n ctx\n')" \
  "a.md:12"

check "line number after a removed line stays correct" 2 \
  "$(printf 'diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,3 +1,3 @@\n ctx\n-gone\n+Jane Doe was here\n')" \
  "a.md:2"

check "tracks file across multiple diffs in one stream" 2 \
  "$(printf 'diff --git a/one.md b/one.md\n--- a/one.md\n+++ b/one.md\n@@ -1 +1,2 @@\n ctx\n+clean\ndiff --git a/two.md b/two.md\n--- a/two.md\n+++ b/two.md\n@@ -1 +1,2 @@\n ctx\n+Jane Doe\n')" \
  "two.md:2"

# --- config errors -> 1 (fail closed, never silently unarmed) ----------------
badcfg="$TMP/bad.json"
echo '{ "identity": { "names": "not-a-list" } }' > "$badcfg"
out="$(printf '%s' "$(d a.md '+x')" | PR_LEAK_SCAN_CONFIG="$badcfg" "$SCANNER" 2>&1)"; rc=$?
if [ "$rc" = 1 ]; then PASS=$((PASS+1)); echo "  ok   malformed config -> 1"
else FAIL=$((FAIL+1)); echo "  FAIL malformed config -> exit $rc, want 1 ($out)"; fi

echo '{ not json' > "$badcfg"
out="$(printf '%s' "$(d a.md '+x')" | PR_LEAK_SCAN_CONFIG="$badcfg" "$SCANNER" 2>&1)"; rc=$?
if [ "$rc" = 1 ]; then PASS=$((PASS+1)); echo "  ok   invalid JSON config -> 1"
else FAIL=$((FAIL+1)); echo "  FAIL invalid JSON config -> exit $rc, want 1 ($out)"; fi

out="$("$SCANNER" /nonexistent/pr.diff 2>&1)"; rc=$?
if [ "$rc" = 1 ]; then PASS=$((PASS+1)); echo "  ok   unreadable diff -> 1"
else FAIL=$((FAIL+1)); echo "  FAIL unreadable diff -> exit $rc, want 1 ($out)"; fi

# --- NOT SCANNED -> 4 (the fail-open hole this gate closes) ------------------
# Input that is readable but is not a diff must NOT come back as CLEAN. A caller
# that sees 0 concludes "no leaks"; the truth is "nothing was examined".
check "empty input -> 4, not 0" 4 "" \
  "NOT-SCANNED|invalid-diff"

check "whitespace-only input -> 4" 4 "$(printf '\n\n  \n')"

# The real-world shape: `gh pr diff` exits 0 on a >300-file PR and writes the API
# error into the output file. Two lines of prose, no added lines, scans "clean".
check "API error body is not a clean scan -> 4" 4 \
  "$(printf '{\n  "message": "Sorry, the diff exceeded the maximum number of files (300)."\n}\n')" \
  "NOT-SCANNED|invalid-diff"

check "prose that mentions a diff is still not a diff -> 4" 4 \
  "$(printf 'The diff --git line only counts at the start of a line.\n')"

# A NOT SCANNED verdict must not be reachable for input that IS a diff, however
# boring — otherwise the gate would block everything and get switched off.
check "a valid but empty-of-findings diff is 0, not 4" 0 \
  "$(d README.md '+nothing to see here')"

# --- the shipped example config must be valid + identity-free ----------------
if printf '%s' "$(d README.md '+ordinary line')" \
     | PR_LEAK_SCAN_CONFIG="$REPO_ROOT/.pr-leak-scan.example.json" \
       "$SCANNER" >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "  ok   .pr-leak-scan.example.json loads cleanly"
else
  FAIL=$((FAIL+1)); echo "  FAIL .pr-leak-scan.example.json does not load"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
