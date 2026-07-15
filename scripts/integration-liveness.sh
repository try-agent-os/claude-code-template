#!/usr/bin/env bash
# integration-liveness.sh — probe the LIVE status of your integrations' credentials
# and surface dead ones BEFORE agents silently 403 / return empty on them.
#
# WHY THIS EXISTS: credential decay is the most common recurring failure in an
# always-on agent fleet — OAuth tokens expire, API keys get rotated or revoked
# server-side, a consent screen drops a scope. The failure mode is SILENT: a dead
# credential just makes a downstream routine return 403/empty, and nobody notices
# for days. Worse, a task depending on it can be marked DONE while the credential
# was dead the whole time. This is the missing liveness layer: it asks every
# integration "are you actually alive right now?" on a schedule.
#
# WHAT IT DOES: runs the probes declared in .integration-liveness.json, writes a
# manifest (so other consumers read it instead of re-probing), and exits non-zero
# when the dead-set GROWS versus the previous run. Chronically-dead integrations
# do NOT re-alert every run — only state CHANGES do, so the signal stays rare
# enough to be worth reading.
#
# PROBE KINDS (all generic — declare them in config, no code change):
#   http          GET a URL with a token from the environment. Alive on ok_status
#                 (default 200), dead on dead_status (default 401/403). Point it
#                 at an auth-only endpoint (e.g. /user, /users/me) — NOT one that
#                 needs extra params, or a live key can false-flag as dead.
#   command       Run a CLI. Alive on rc 0 with no dead_patterns in the output;
#                 dead when a dead_pattern matches. Use for CLIs that exit 0 but
#                 print "401 unauthorized".
#   command_json  Run a CLI that prints a JSON status blob, then assert on it.
#                 Covers "token valid AND carries the scopes I need".
#   not_probed    Declared, never probed (e.g. integrations reachable only from
#                 an agent, with no CLI). Listed EXPLICITLY rather than silently
#                 dropped, so the manifest never implies coverage it lacks.
#
# USAGE:
#   scripts/integration-liveness.sh            # probe, write manifest, exit 2 on NEW dead
#   INTEGRATION_LIVENESS_CONFIG=x.json ...     # override config path
#   LIVENESS_NO_NOTIFY=1 ...                   # probe-and-report only, never notify
#
# EXIT: 0 = no new dead (all alive, or dead ones already known)
#       2 = at least one integration NEWLY went dead (routine's failure handler alerts)
#       1 = usage/config error
#
# SETUP: copy .integration-liveness.example.json -> .integration-liveness.json and
# declare YOUR integrations. With no config this exits 0 and does nothing — an
# unconfigured install is not a failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG="${INTEGRATION_LIVENESS_CONFIG:-$REPO/.integration-liveness.json}"
MANIFEST_DEFAULT="${LIVENESS_MANIFEST:-/var/lib/agent-os/integration-liveness.json}"
ENV_FILE="${AGENT_OS_ENV_FILE:-/etc/agent-os/agent-os.env}"
# Optional: present in some installs, absent in a bare template checkout. When it
# is missing we rely on the non-zero exit alone (the routine's failure handler).
NOTIFY="${NOTIFY_BIN:-$REPO/scripts/notify-operator.sh}"

if [ ! -f "$CONFIG" ]; then
  echo "integration-liveness: no config at $CONFIG — nothing to probe."
  echo "  Copy .integration-liveness.example.json -> .integration-liveness.json to enable."
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "integration-liveness: python3 required" >&2; exit 1; }

# NOTE: the python program is passed via a heredoc, which occupies stdin. This
# script never reads stdin, so that is safe here. (A sibling gate once shipped
# with a heredoc silently eating a piped-in diff — hence the explicit note.)
python3 - "$CONFIG" "$MANIFEST_DEFAULT" "$ENV_FILE" "$NOTIFY" <<'PYEOF'
import datetime, json, os, re, subprocess, sys, urllib.error, urllib.request

CONFIG, MANIFEST_DEFAULT, ENV_FILE, NOTIFY = sys.argv[1:5]
now = datetime.datetime.now(datetime.timezone.utc)


def die(msg):
    sys.stderr.write("integration-liveness: %s\n" % msg)
    sys.exit(1)


try:
    with open(CONFIG) as f:
        cfg = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    die("cannot read config %s: %s" % (CONFIG, e))

integrations_cfg = cfg.get("integrations") or {}
if not isinstance(integrations_cfg, dict) or not integrations_cfg:
    print("integration-liveness: config has no 'integrations' — nothing to probe.")
    sys.exit(0)

MANIFEST = cfg.get("manifest") or MANIFEST_DEFAULT


# --- secrets: read from env, else fall back to the install's env file ---------
_env_file_cache = None


def env_file_lookup(key):
    """Read KEY=value from the install's env file (agents get it via systemd,
    but an interactive/cron run may not have it exported)."""
    global _env_file_cache
    if _env_file_cache is None:
        _env_file_cache = {}
        try:
            with open(ENV_FILE) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    _env_file_cache[k.strip()] = v.strip().strip('"').strip("'")
        except OSError:
            pass
    return _env_file_cache.get(key)


def token_for(name):
    return os.environ.get(name) or env_file_lookup(name)


def resolve_bin(spec):
    """Resolve a CLI path: $BIN_ENV override -> declared path -> $PATH lookup."""
    bin_env = spec.get("bin_env")
    if bin_env and os.environ.get(bin_env):
        return os.environ[bin_env]
    argv = spec.get("argv") or []
    return argv[0] if argv else None


def run(argv, timeout):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or ""), (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except (OSError, ValueError) as e:
        return 125, "", str(e)


def meta(spec, extra=None):
    """Carry the human-facing fields through to the manifest verbatim."""
    out = {}
    for k in ("impacts", "remediation"):
        if spec.get(k):
            out[k] = spec[k]
    if extra:
        out.update(extra)
    return out


# --- probe kinds -------------------------------------------------------------
def probe_http(name, spec):
    url = spec.get("url")
    if not url:
        return {"alive": None, "detail": "config error: 'url' missing"}
    headers = {}
    token = None
    token_env = spec.get("token_env")
    if token_env:
        token = token_for(token_env)
        if not token:
            return dict({"alive": None, "detail": "%s not set" % token_env}, **meta(spec))
    for k, v in (spec.get("headers") or {}).items():
        headers[k] = v.replace("{token}", token) if token else v
    if token and not headers:
        headers["Authorization"] = spec.get("auth_header", "Bearer {token}").replace("{token}", token)
    ok_status = spec.get("ok_status") or [200]
    dead_status = spec.get("dead_status") or [401, 403]
    req = urllib.request.Request(url, headers=headers, method=spec.get("method", "GET"))
    try:
        with urllib.request.urlopen(req, timeout=spec.get("timeout", 15)) as resp:
            alive = resp.status in ok_status
            return dict({"alive": alive, "detail": "HTTP %s" % resp.status}, **meta(spec))
    except urllib.error.HTTPError as e:
        if e.code in dead_status:
            return dict({"alive": False, "detail": "HTTP %s (key expired/revoked server-side)" % e.code},
                        **meta(spec))
        # Any other HTTP error is inconclusive, NOT dead — a 500 or a 400 from a
        # changed API contract must not be reported as a revoked credential.
        return dict({"alive": None, "detail": "HTTP %s (inconclusive)" % e.code}, **meta(spec))
    except Exception as e:  # noqa: BLE001 — network failure class is broad on purpose
        return dict({"alive": None, "detail": "probe error: %s" % e}, **meta(spec))


def probe_command(name, spec):
    argv = list(spec.get("argv") or [])
    if not argv:
        return {"alive": None, "detail": "config error: 'argv' missing"}
    argv[0] = resolve_bin(spec) or argv[0]
    rc, out, err = run(argv, spec.get("timeout", 25))
    blob = (out + err).lower()
    dead_patterns = [p.lower() for p in (spec.get("dead_patterns") or [])]
    hit = next((p for p in dead_patterns if p in blob), None)
    if hit:
        return dict({"alive": False, "detail": "matched dead pattern '%s'" % hit}, **meta(spec))
    if rc == 0:
        return dict({"alive": True, "detail": spec.get("alive_detail", "ok")}, **meta(spec))
    return dict({"alive": None, "detail": "probe inconclusive (rc=%s)" % rc}, **meta(spec))


def probe_command_json(name, spec):
    argv = list(spec.get("argv") or [])
    if not argv:
        return {"alive": None, "detail": "config error: 'argv' missing"}
    argv[0] = resolve_bin(spec) or argv[0]
    rc, out, err = run(argv, spec.get("timeout", 20))
    if not out.strip():
        return dict({"alive": None, "detail": "%s produced no output" % " ".join(argv)}, **meta(spec))
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return dict({"alive": None, "detail": "%s output is not JSON" % " ".join(argv)}, **meta(spec))
    if not isinstance(data, dict):
        return dict({"alive": None, "detail": "status JSON is not an object"}, **meta(spec))

    assertions = spec.get("assert") or {}
    problems = []

    # "true": ["token_valid"] — these keys must be truthy.
    for key in assertions.get("true") or []:
        if not data.get(key):
            reason = data.get(spec.get("error_key", "token_error")) or "unknown"
            problems.append("%s is false (%s)" % (key, reason))

    # "list_contains": {"scopes": ["calendar"]} — each wanted item must appear as
    # a substring of some element (scopes are full URLs; we match the tail).
    for key, wanted in (assertions.get("list_contains") or {}).items():
        have = data.get(key) or []
        if not isinstance(have, list):
            problems.append("%s is not a list" % key)
            continue
        missing = [w for w in wanted if not any(w in str(s) for s in have)]
        if missing:
            problems.append("%s missing %s (have %d)" % (key, ", ".join(missing), len(have)))

    if problems:
        return dict({"alive": False, "detail": "; ".join(problems)}, **meta(spec))
    detail = spec.get("alive_detail", "ok")
    for key in (assertions.get("list_contains") or {}):
        detail += " (%s=%d)" % (key, len(data.get(key) or []))
    return dict({"alive": True, "detail": detail}, **meta(spec))


def probe_not_probed(name, spec):
    return dict({"alive": None,
                 "detail": spec.get("detail", "not probed (no CLI probe available)")},
                **meta(spec))


KINDS = {
    "http": probe_http,
    "command": probe_command,
    "command_json": probe_command_json,
    "not_probed": probe_not_probed,
}

# --- run every probe ---------------------------------------------------------
integrations = {}
for name, spec in integrations_cfg.items():
    if not isinstance(spec, dict):
        integrations[name] = {"alive": None, "detail": "config error: entry is not an object"}
        continue
    if spec.get("enabled") is False:
        continue
    fn = KINDS.get(spec.get("kind"))
    if not fn:
        integrations[name] = {"alive": None,
                              "detail": "config error: unknown kind %r (want %s)"
                                        % (spec.get("kind"), "/".join(sorted(KINDS)))}
        continue
    try:
        integrations[name] = fn(name, spec)
    except Exception as e:  # noqa: BLE001 — one bad probe must not sink the sweep
        integrations[name] = {"alive": None, "detail": "probe crashed: %s" % e}

dead = sorted([k for k, v in integrations.items() if v.get("alive") is False])

# --- compare to the previous run --------------------------------------------
prev_dead = []
try:
    with open(MANIFEST) as f:
        prev_dead = (json.load(f) or {}).get("dead", [])
except (OSError, json.JSONDecodeError):
    prev_dead = []
new_dead = [d for d in dead if d not in prev_dead]

manifest = {
    "checked_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "integrations": integrations,
    "dead": dead,
}
try:
    parent = os.path.dirname(MANIFEST)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as f:
        json.dump(manifest, f, indent=2)
    os.replace(tmp, MANIFEST)  # atomic: a reader never sees a half-written manifest
except OSError as e:
    sys.stderr.write("integration-liveness: cannot write manifest %s: %s\n" % (MANIFEST, e))

# --- alert only on NEW deaths ------------------------------------------------
# A chronically-dead integration must not re-alert every run, or the alert becomes
# noise and gets ignored — which is exactly how a dead credential survives.
#
# LIVENESS_NO_NOTIFY=1 suppresses only the operator MESSAGE, never the report: the
# findings still go to stdout for report-only callers (a pre-cutover check on a
# fresh host, an ad-hoc dry run) that consume the output directly and would find an
# alert redundant. Staying silent here would hide the findings from the very caller
# that asked for them.
if new_dead:
    lines = ["[integration-liveness] NEW dead integration(s) detected:"]
    for k in new_dead:
        v = integrations[k]
        line = "  - %s: %s" % (k, v.get("detail", ""))
        if v.get("impacts"):
            line += "\n    impacts: %s" % ", ".join(v["impacts"])
        if v.get("remediation"):
            line += "\n    fix: %s" % v["remediation"]
        lines.append(line)
    still = [d for d in dead if d not in new_dead]
    if still:
        lines.append("  (still dead: %s)" % ", ".join(still))
    msg = "\n".join(lines)
    print(msg)
    if not os.environ.get("LIVENESS_NO_NOTIFY") and os.path.isfile(NOTIFY) and os.access(NOTIFY, os.X_OK):
        subprocess.run([NOTIFY, "--source", "integration-liveness", "--severity", "warn",
                        "--msg", msg], check=False)

print(json.dumps({"dead": dead, "new_dead": new_dead}))
# Non-zero so the routine's failure path alerts — a credential that just died must
# not pass quietly. Already-known dead ones keep exit 0 (no repeat alarm).
sys.exit(2 if new_dead else 0)
PYEOF
