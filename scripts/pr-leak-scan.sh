#!/bin/bash
# pr-leak-scan.sh — deterministic secret / PII leak scanner for PR diffs into PUBLIC repos.
#
# WHY: an agent that opens PRs from a private hub into a public repo can leak the
# operator's personal data (secrets, names, hosts, paths) in an added line. This is
# the DETERMINISTIC gate that runs BEFORE any merge: same diff in, same verdict out,
# no LLM in the loop. An LLM auditor can add judgment on top, but the reproducible
# block/allow decision belongs here.
#
# Reads a unified diff (e.g. from `gh pr diff`) on STDIN or from a file arg and scans
# ONLY ADDED lines (`^+`, not `+++`) — those are what would land in the public repo.
# Removed lines (`^-`) are leaving the repo and are never a leak, so they're ignored.
#
# TWO PATTERN SOURCES:
#   1. Built-in SECRET patterns (CRITICAL) — generic credential shapes (tokens, keys,
#      JWTs, private-key blocks). These need no config: a leaked token is a leak for
#      everyone.
#   2. Your IDENTITY patterns (HIGH) and SOFT patterns (MEDIUM) — loaded from a config
#      file, because "personal data" is per-install. The template ships NO identities.
#      Copy .pr-leak-scan.example.json → .pr-leak-scan.json and fill in your own.
#      With no config, the scanner still runs and catches secrets.
#
# Config also takes `allow` (regexes for benign added LINES) and `skip_files`
# (regexes for whole PATHS to ignore, e.g. fixture files full of fake credentials).
#
# CONFIG lookup order: $PR_LEAK_SCAN_CONFIG → <repo-root>/.pr-leak-scan.json → none.
#
# OUTPUT: one finding per line on STDOUT, pipe-delimited and SANITISED
#   SEV|type|file:line|<excerpt with secret VALUES masked>
# SEV in CRITICAL (secrets) | HIGH (direct PII) | MEDIUM (paths/hosts/slugs to judge)
#
# EXIT CODES (binary verifier — the point of this script):
#   0  CLEAN   — no matches
#   2  LEAK    — at least one CRITICAL or HIGH match  -> block the PR
#   3  REVIEW  — only MEDIUM matches -> a human/LLM judges (generic ref vs real leak)
#   1  ERROR   — bad usage / unreadable or invalid config
#
# Secret VALUES are never printed in full — only type + file:line + a masked excerpt
# (first/last few chars). Identity matches show the matched line (that IS the finding),
# but secrets are masked so the report itself can't leak them.
#
# Usage:
#   gh pr diff <N> --repo <org/repo> | scripts/pr-leak-scan.sh
#   scripts/pr-leak-scan.sh /tmp/pr.diff
#   PR_LEAK_SCAN_CONFIG=/path/to/cfg.json scripts/pr-leak-scan.sh /tmp/pr.diff
set -uo pipefail

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//' | sed '$d'
    exit 0
    ;;
esac

SRC="${1:--}"

# The python program below arrives on THIS script's stdin (heredoc), which would
# consume the piped diff. So spool stdin to a temp file and hand python a path —
# otherwise `gh pr diff | pr-leak-scan.sh` scans an empty diff and reports CLEAN,
# i.e. the gate silently passes everything.
TMP_DIFF=""
cleanup() { [ -n "$TMP_DIFF" ] && rm -f "$TMP_DIFF"; }
trap cleanup EXIT

if [ "$SRC" = "-" ] || [ "$SRC" = "/dev/stdin" ]; then
  TMP_DIFF="$(mktemp "${TMPDIR:-/tmp}/pr-leak-scan.XXXXXX")" || exit 1
  cat > "$TMP_DIFF"
  SRC="$TMP_DIFF"
elif [ ! -r "$SRC" ]; then
  echo "pr-leak-scan: cannot read diff '$SRC'" >&2
  exit 1
fi

# Config discovery: explicit env wins, else repo root next to this script.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${PR_LEAK_SCAN_CONFIG:-$REPO_ROOT/.pr-leak-scan.json}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "pr-leak-scan: python3 required" >&2
  exit 1
fi

PYTHONDONTWRITEBYTECODE=1 python3 - "$SRC" "$CONFIG" <<'PYEOF'
import json, os, re, sys

src, config_path = sys.argv[1], sys.argv[2]

with open(src, "r", errors="replace") as f:
    diff = f.read()

SECRET, PII, SOFT = "CRITICAL", "HIGH", "MEDIUM"

# ---- built-in secret catalogue (generic, no per-install data) -----------------
# Each entry: (severity, type, compiled_regex, mask_value)
# mask_value=True -> the matched span is a credential; print only head/tail.
PATTERNS = [
    (SECRET, "github-token",         re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"), True),
    (SECRET, "openai-anthropic-key", re.compile(r"sk-(?:ant-)?[A-Za-z0-9_-]{20,}"), True),
    (SECRET, "slack-token",          re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"), True),
    (SECRET, "aws-access-key",       re.compile(r"AKIA[0-9A-Z]{16}"), True),
    (SECRET, "clickup-token",        re.compile(r"pk_[0-9]{6,}_[A-Z0-9]{20,}"), True),
    (SECRET, "google-api-key",       re.compile(r"AIza[0-9A-Za-z_-]{30,}"), True),
    (SECRET, "telegram-bot-token",   re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{30,}"), True),
    (SECRET, "private-key-block",    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"), True),
    (SECRET, "jwt",                  re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"), True),
    (SECRET, "bearer-literal",       re.compile(r"[Bb]earer\s+[A-Za-z0-9._\-]{20,}"), True),
    # generic assigned secret: key-ish name = long opaque quoted value
    (SECRET, "assigned-secret",      re.compile(r"(?i)(?:api[_-]?key|secret|token|passwd|password|access[_-]?token|client[_-]?secret)\s*[:=]\s*['\"][A-Za-z0-9_\-./+=]{16,}['\"]"), True),
]

# Real email addresses in a public repo are PII for everyone — but the usual
# placeholder/noreply shapes are not, so they're excluded here rather than by
# forcing every install to write an allow rule.
PATTERNS.append(
    (PII, "email-address",
     re.compile(r"\b[A-Za-z0-9._%+-]+@(?!(?:example|test|invalid|localhost)\.)"
                r"(?![A-Za-z0-9.-]*\bnoreply\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
     False))

# ---- per-install identity catalogue (from config) ----------------------------
# The template ships no identities on purpose: see .pr-leak-scan.example.json.
def die(msg):
    print(f"pr-leak-scan: {msg}", file=sys.stderr)
    sys.exit(1)

cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r") as f:
            cfg = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        die(f"invalid config '{config_path}': {e}")
    if not isinstance(cfg, dict):
        die(f"invalid config '{config_path}': top level must be an object")

def build(section, severity):
    """Turn a config section into patterns.

    Plain strings are regex-escaped and word-boundary matched (case-insensitive)
    so a config never needs regex literacy. `regexes` are used verbatim for the
    cases plain strings can't express (phone formats, path prefixes)."""
    block = cfg.get(section) or {}
    if not isinstance(block, dict):
        die(f"invalid config: '{section}' must be an object")
    out = []
    for key, values in block.items():
        if not isinstance(values, list):
            die(f"invalid config: '{section}.{key}' must be a list")
        for v in values:
            if not isinstance(v, str) or not v.strip():
                die(f"invalid config: '{section}.{key}' entries must be non-empty strings")
            if key == "regexes":
                try:
                    rx = re.compile(v)
                except re.error as e:
                    die(f"invalid regex in '{section}.regexes': {v!r} ({e})")
            else:
                # \b is meaningless next to a non-word char (e.g. "@handle",
                # "1.2.3.4"), so only anchor the edges that are word chars.
                esc = re.escape(v)
                left = r"\b" if v[:1].isalnum() or v[:1] == "_" else ""
                right = r"\b" if v[-1:].isalnum() or v[-1:] == "_" else ""
                rx = re.compile(f"(?i){left}{esc}{right}")
            out.append((severity, f"{section}-{key}", rx, False))
    return out

PATTERNS += build("identity", PII)
PATTERNS += build("soft", SOFT)

# ---- allowlist ---------------------------------------------------------------
# Regexes for known-benign added lines (placeholders, example blocks, docs that
# legitimately mention a pattern). An allowed line is skipped entirely.
allow_raw = cfg.get("allow") or []
if not isinstance(allow_raw, list):
    die("invalid config: 'allow' must be a list of regexes")
ALLOW = []
for v in allow_raw:
    try:
        ALLOW.append(re.compile(v))
    except re.error as e:
        die(f"invalid regex in 'allow': {v!r} ({e})")

# ---- skipped files -----------------------------------------------------------
# Path regexes whose findings are ignored wholesale. Needed for files that carry
# credential-SHAPED strings by design — this scanner's own fixtures are the
# canonical case: they must contain fake tokens to test the matchers, and without
# a skip the gate flags itself on every PR that touches them.
skip_raw = cfg.get("skip_files") or []
if not isinstance(skip_raw, list):
    die("invalid config: 'skip_files' must be a list of regexes")
# Built-in: this scanner's own fixtures, and the example config — an EXAMPLE
# identity file necessarily contains identity-shaped placeholders by design.
SKIP_FILES = [
    re.compile(r"^tests/pr-leak-scan/"),
    re.compile(r"(?:^|/)\.pr-leak-scan\.example\.json$"),
]
for v in skip_raw:
    try:
        SKIP_FILES.append(re.compile(v))
    except re.error as e:
        die(f"invalid regex in 'skip_files': {v!r} ({e})")

def mask(span: str) -> str:
    span = span.strip()
    if len(span) <= 10:
        return span[:2] + "…"
    return span[:6] + "…" + span[-4:] + f" [len={len(span)}]"

# ---- walk the diff, tracking current file + new-file line numbers -------------
findings = []
cur_file = "?"
new_lineno = 0
in_hunk = False
hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")

for raw in diff.splitlines():
    m = hunk_re.match(raw)
    if m:
        new_lineno = int(m.group(1))
        in_hunk = True
        continue
    if raw.startswith("+++ "):
        # `+++ b/path/to/file` — a header, not an added line.
        p = raw[4:].strip()
        # Strip the a/ b/ prefix, but tolerate a real path that starts with them.
        cur_file = p[2:] if p.startswith(("a/", "b/")) else p
        in_hunk = False
        continue
    if raw.startswith("--- ") or raw.startswith("diff --git "):
        in_hunk = False
        continue
    if not in_hunk:
        # Outside a hunk (index/mode/similarity lines) nothing is content.
        continue
    if raw.startswith("+"):
        added = raw[1:]
        if any(rx.search(cur_file) for rx in SKIP_FILES):
            new_lineno += 1
            continue
        if any(rx.search(added) for rx in ALLOW):
            new_lineno += 1
            continue
        loc = f"{cur_file}:{new_lineno}"
        for sev, typ, rx, is_secret in PATTERNS:
            mt = rx.search(added)
            if mt:
                excerpt = mask(mt.group(0)) if is_secret else added.strip()[:120]
                findings.append((sev, typ, loc, excerpt))
        new_lineno += 1
    elif raw.startswith("-"):
        # Removed line — does not advance the new-file counter, never a leak.
        continue
    else:
        # Context line (" ...") or "\ No newline at end of file".
        if not raw.startswith("\\"):
            new_lineno += 1

# ---- emit + exit code --------------------------------------------------------
order = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2}
findings.sort(key=lambda f: (order[f[0]], f[2]))
for sev, typ, loc, excerpt in findings:
    print(f"{sev}|{typ}|{loc}|{excerpt}")

has_block = any(f[0] in (SECRET, PII) for f in findings)
has_soft = any(f[0] == SOFT for f in findings)
if has_block:
    sys.exit(2)
if has_soft:
    sys.exit(3)
sys.exit(0)
PYEOF
