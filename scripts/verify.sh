#!/usr/bin/env bash
# AgentOS deployment healthcheck.
#
# Run this after install.sh (or any time you suspect drift) to verify that the
# template is actually working: binaries, settings hierarchy, services,
# plugins, hooks, env file, state dirs, MCP brokers.
#
# Exit code:
#   0  all checks passed
#   1  at least one check failed
#
# Usage:
#   scripts/verify.sh                  # pretty colored output (default)
#   scripts/verify.sh --verbose        # show every command + its output
#   scripts/verify.sh --quiet          # exit code only, no stdout
#   scripts/verify.sh --json           # machine-readable JSON report
#   scripts/verify.sh --minimal        # skip MCP/operator/heartbeat checks
#                                      # (matches install.sh --minimal)
#   scripts/verify.sh --fix            # try to repair benign issues
#                                      # (missing dirs, wrong perms, etc.)
#   scripts/verify.sh --help           # this help
#
# Compatible with bash 3.2 (macOS default). No mapfile, no read -d, no [[
# regex, no associative arrays.
#
# License: MIT — see LICENSE.

# NOTE: deliberately NO `set -e` — we want every check to run even if one
# fails. We do use `-uo pipefail` so unset vars and broken pipes are caught.
set -uo pipefail

###############################################################################
# Globals
###############################################################################

SCRIPT_VERSION="0.1.0"

# Tally counters
VERIFY_PASSED=0
VERIFY_FAILED=0
VERIFY_WARNED=0
VERIFY_SKIPPED=0
VERIFY_FIXED=0

# Mode flags
MODE_VERBOSE=0
MODE_QUIET=0
MODE_JSON=0
MODE_MINIMAL=0
MODE_FIX=0

# JSON accumulator (we collect events as JSON-ish lines, dump at end).
# bash 3.2 has no jq dependency for output assembly — we hand-build.
JSON_EVENTS=""

# Project dir resolution
#
# Order: explicit env var > script-relative repo root > current working dir.
# The script lives at <repo>/scripts/verify.sh, so the parent of the script's
# directory is the repo root in any standard install. Walking up from the
# script's location lets `sudo bash /opt/agent-os/claude/scripts/verify.sh`
# work without the caller having to export CLAUDE_PROJECT_DIR — previously
# the pwd fallback resolved PROJECT_DIR to /root and every plugin/hooks check
# emitted a misleading FAIL/WARN against paths that never existed.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  _verify_self="${BASH_SOURCE[0]:-$0}"
  if [ -f "$_verify_self" ]; then
    _verify_self_dir="$(cd "$(dirname -- "$_verify_self")" 2>/dev/null && pwd)"
    if [ -n "${_verify_self_dir:-}" ] && [ -d "${_verify_self_dir}/../plugins" ]; then
      PROJECT_DIR="$(cd "${_verify_self_dir}/.." && pwd)"
    else
      PROJECT_DIR="$(pwd)"
    fi
    unset _verify_self_dir
  else
    PROJECT_DIR="$(pwd)"
  fi
  unset _verify_self
fi

# OS detection
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME_S" in
  Linux)  OS="linux" ;;
  Darwin) OS="macos" ;;
  *)      OS="other" ;;
esac

# Colors (degrade gracefully if no TTY or no tput)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_GREEN="$(tput setaf 2 2>/dev/null || echo)"
  C_RED="$(tput setaf 1 2>/dev/null || echo)"
  C_YELLOW="$(tput setaf 3 2>/dev/null || echo)"
  C_BLUE="$(tput setaf 4 2>/dev/null || echo)"
  C_DIM="$(tput dim 2>/dev/null || echo)"
  C_BOLD="$(tput bold 2>/dev/null || echo)"
  C_RESET="$(tput sgr0 2>/dev/null || echo)"
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

###############################################################################
# Arg parsing
###############################################################################

print_help() {
  sed -n '2,/^# License:/p' "$0" | sed 's/^# \{0,1\}//;$d'
}

for arg in "$@"; do
  case "$arg" in
    --verbose|-v) MODE_VERBOSE=1 ;;
    --quiet|-q)   MODE_QUIET=1 ;;
    --json)       MODE_JSON=1; MODE_QUIET=1 ;;
    --minimal)    MODE_MINIMAL=1 ;;
    --fix)        MODE_FIX=1 ;;
    --help|-h)    print_help; exit 0 ;;
    --version)    echo "verify.sh $SCRIPT_VERSION"; exit 0 ;;
    *) echo "verify.sh: unknown flag: $arg (try --help)" >&2; exit 1 ;;
  esac
done

###############################################################################
# Output primitives
###############################################################################

# emit <kind> <section> <message> [hint]
# kind: PASS|FAIL|WARN|SKIP|FIX|INFO
emit() {
  local kind="$1"
  local section="$2"
  local msg="$3"
  local hint="${4:-}"

  # Tally
  case "$kind" in
    PASS) VERIFY_PASSED=$((VERIFY_PASSED + 1)) ;;
    FAIL) VERIFY_FAILED=$((VERIFY_FAILED + 1)) ;;
    WARN) VERIFY_WARNED=$((VERIFY_WARNED + 1)) ;;
    SKIP) VERIFY_SKIPPED=$((VERIFY_SKIPPED + 1)) ;;
    FIX)  VERIFY_FIXED=$((VERIFY_FIXED + 1)) ;;
  esac

  # JSON: accumulate
  if [ "$MODE_JSON" = "1" ]; then
    # crude JSON-string escape: backslash, quote, newline
    local esc_msg esc_hint
    esc_msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    esc_hint=$(printf '%s' "$hint" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    local event="{\"kind\":\"$kind\",\"section\":\"$section\",\"message\":\"$esc_msg\",\"hint\":\"$esc_hint\"}"
    if [ -z "$JSON_EVENTS" ]; then
      JSON_EVENTS="$event"
    else
      JSON_EVENTS="$JSON_EVENTS,$event"
    fi
    return 0
  fi

  # Quiet: suppress stdout (counters still tally; exit code reflects pass/fail)
  if [ "$MODE_QUIET" = "1" ]; then
    return 0
  fi

  # Pretty
  local prefix
  case "$kind" in
    PASS) prefix="${C_GREEN}[PASS]${C_RESET}" ;;
    FAIL) prefix="${C_RED}[FAIL]${C_RESET}" ;;
    WARN) prefix="${C_YELLOW}[WARN]${C_RESET}" ;;
    SKIP) prefix="${C_DIM}[SKIP]${C_RESET}" ;;
    FIX)  prefix="${C_BLUE}[FIX ]${C_RESET}" ;;
    INFO) prefix="${C_BLUE}[INFO]${C_RESET}" ;;
    *)    prefix="[$kind]" ;;
  esac
  printf '  %s %s\n' "$prefix" "$msg"
  if [ -n "$hint" ]; then
    printf '         %s%s%s\n' "$C_DIM" "$hint" "$C_RESET"
  fi
}

section() {
  if [ "$MODE_QUIET" = "1" ]; then return 0; fi
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"
}

verbose() {
  if [ "$MODE_VERBOSE" = "1" ] && [ "$MODE_QUIET" = "0" ]; then
    printf '         %s%s%s\n' "$C_DIM" "$1" "$C_RESET"
  fi
}

###############################################################################
# Helpers
###############################################################################

# version_ge <a> <b> — true if a >= b (semver-ish, dot-separated numbers)
version_ge() {
  local a="$1" b="$2"
  # bail out fast if equal or empty
  [ "$a" = "$b" ] && return 0
  [ -z "$a" ] && return 1
  [ -z "$b" ] && return 0
  # use sort -V if available (Linux + macOS 10.15+ via /usr/bin/sort)
  if printf '%s\n%s\n' "$a" "$b" | sort -V >/dev/null 2>&1; then
    local lower
    lower=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)
    [ "$lower" = "$b" ]
  else
    # poor-man comparison: split on dots, compare numerically
    local IFS=.
    set -- $a; local a1=${1:-0} a2=${2:-0} a3=${3:-0}
    set -- $b; local b1=${1:-0} b2=${2:-0} b3=${3:-0}
    if [ "$a1" -gt "$b1" ]; then return 0; fi
    if [ "$a1" -lt "$b1" ]; then return 1; fi
    if [ "$a2" -gt "$b2" ]; then return 0; fi
    if [ "$a2" -lt "$b2" ]; then return 1; fi
    if [ "$a3" -ge "$b3" ]; then return 0; fi
    return 1
  fi
}

# strip_v <string> — drop leading 'v' if any (for "v1.2.3" -> "1.2.3")
strip_v() { printf '%s' "$1" | sed 's/^v//'; }

# json_field <file> <jq-expr> — read field from JSON file via jq, "" on failure
json_field() {
  local f="$1" expr="$2"
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$f" ] || return 1
  jq -r "$expr // empty" "$f" 2>/dev/null
}

# valid_json <file>
valid_json() {
  local f="$1"
  [ -f "$f" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq empty "$f" >/dev/null 2>&1
  else
    # fallback: python if present
    if command -v python3 >/dev/null 2>&1; then
      python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" >/dev/null 2>&1
    else
      # last resort: file exists and is non-empty
      [ -s "$f" ]
    fi
  fi
}

# port_listening <port> — true if anything listens on 127.0.0.1:port
port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(:|\.)${port}\$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep -E "[\.:]${port}[^0-9]" | grep -q LISTEN
  else
    return 2  # cannot determine
  fi
}

# http_ok <url> — true if curl returns 2xx within 3s
http_ok() {
  local url="$1"
  curl -fsS --max-time 3 "$url" >/dev/null 2>&1
}

# is_root
is_root() { [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; }

# fix_mkdir_700 <dir>
fix_mkdir_700() {
  local d="$1"
  if [ "$MODE_FIX" = "1" ] && [ ! -d "$d" ]; then
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null \
      && emit FIX "fix" "created $d (mode 700)" || true
  fi
}

###############################################################################
# Section 1 — Binary & version
###############################################################################

check_binaries() {
  section "Binary & version"

  # claude
  if command -v claude >/dev/null 2>&1; then
    local cv
    cv="$(claude --version 2>/dev/null | head -1 | awk '{print $1}')"
    cv="$(strip_v "$cv")"
    verbose "claude --version: $cv"
    if [ -n "$cv" ]; then
      emit PASS "binary" "claude installed (version $cv)"
    else
      emit WARN "binary" "claude installed, but --version output unparseable" "Try: claude --version"
    fi

    # Compare against minimumVersion in managed-settings.template.json
    local tpl="${PROJECT_DIR}/managed-settings.template.json"
    if [ -f "$tpl" ]; then
      local min
      min="$(json_field "$tpl" '.minimumVersion')"
      if [ -n "$min" ] && [ -n "$cv" ]; then
        if version_ge "$cv" "$min"; then
          emit PASS "binary" "claude $cv >= managed minimumVersion $min"
        else
          emit FAIL "binary" "claude $cv < managed minimumVersion $min" \
            "Upgrade: apt-get update && apt-get install --only-upgrade claude-code"
        fi
      fi
    fi
  else
    emit FAIL "binary" "claude not on PATH" \
      "Install via apt repo: see install.sh step 5"
  fi

  # bun (used by claude-peers plugin)
  if command -v bun >/dev/null 2>&1; then
    local bv
    bv="$(bun --version 2>/dev/null)"
    emit PASS "binary" "bun $bv"
  elif [ -x "/home/agent-os/.bun/bin/bun" ]; then
    local bv
    bv="$(/home/agent-os/.bun/bin/bun --version 2>/dev/null)"
    emit PASS "binary" "bun $bv (in agent-os home, not on \$PATH)"
  elif [ "$MODE_MINIMAL" = "1" ]; then
    emit SKIP "binary" "bun not required for --minimal"
  else
    emit FAIL "binary" "bun not on PATH" \
      "Install: curl -fsSL https://bun.sh/install | bash"
  fi

  # python3
  if command -v python3 >/dev/null 2>&1; then
    local pv
    pv="$(python3 --version 2>&1 | awk '{print $2}')"
    if version_ge "$pv" "3.10.0"; then
      emit PASS "binary" "python3 $pv"
    else
      emit WARN "binary" "python3 $pv < 3.10 (some plugins assume newer)"
    fi
  else
    emit WARN "binary" "python3 not on PATH"
  fi

  # node (saga-mcp)
  if command -v node >/dev/null 2>&1; then
    local nv
    nv="$(strip_v "$(node --version 2>/dev/null)")"
    if version_ge "$nv" "20.0.0"; then
      emit PASS "binary" "node $nv"
    else
      emit WARN "binary" "node $nv < 20 (saga-mcp expects Node 20 LTS)"
    fi
  elif [ "$MODE_MINIMAL" = "1" ]; then
    emit SKIP "binary" "node not required for --minimal"
  else
    emit FAIL "binary" "node not on PATH" \
      "Install Node 20 LTS — see install.sh step 4"
  fi

  # jq (used by hooks + verify itself)
  if command -v jq >/dev/null 2>&1; then
    emit PASS "binary" "jq $(jq --version 2>/dev/null)"
  else
    emit FAIL "binary" "jq not on PATH" \
      "apt install jq (Linux) or brew install jq (macOS)"
  fi

  # curl (used by hooks + this script)
  if command -v curl >/dev/null 2>&1; then
    emit PASS "binary" "curl present"
  else
    emit FAIL "binary" "curl not on PATH"
  fi
}

###############################################################################
# Section 2 — OS detection
###############################################################################

check_os() {
  section "OS environment"

  if is_root; then
    emit FAIL "os" "running as root — verify.sh refuses for safety" \
      "Re-run as the agent-os user: sudo -u agent-os $(basename "$0")"
    return 0
  fi
  emit PASS "os" "running as non-root user $(id -un 2>/dev/null || echo '?')"

  case "$OS" in
    linux)
      emit PASS "os" "OS detected: Linux"
      # systemctl --user works?
      if command -v systemctl >/dev/null 2>&1; then
        emit PASS "os" "systemctl present"
      else
        emit FAIL "os" "systemctl not found (template requires systemd)"
      fi
      # bubblewrap (sandbox)
      if command -v bwrap >/dev/null 2>&1; then
        emit PASS "os" "bubblewrap (bwrap) present"
      else
        emit WARN "os" "bubblewrap not installed" \
          "Sandbox.failIfUnavailable=true in managed-settings — install: apt install bubblewrap"
      fi
      # socat (sandbox helper)
      if command -v socat >/dev/null 2>&1; then
        emit PASS "os" "socat present"
      else
        emit WARN "os" "socat not installed" \
          "Required by sandboxed claude — install: apt install socat"
      fi
      ;;
    macos)
      emit PASS "os" "OS detected: macOS"
      if command -v launchctl >/dev/null 2>&1; then
        emit PASS "os" "launchctl present"
      else
        emit FAIL "os" "launchctl missing on macOS"
      fi
      ;;
    *)
      emit WARN "os" "unrecognized OS '$UNAME_S' — verify.sh will skip OS-specific checks"
      ;;
  esac
}

###############################################################################
# Section 3 — Settings hierarchy
###############################################################################

check_settings() {
  section "Settings hierarchy"

  # managed settings location depends on OS
  local managed=""
  case "$OS" in
    linux) managed="/etc/claude-code/managed-settings.json" ;;
    macos) managed="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
  esac

  if [ -n "$managed" ]; then
    if [ -f "$managed" ]; then
      if valid_json "$managed"; then
        emit PASS "settings" "managed settings: $managed (valid JSON)"

        # check expected keys
        local key
        for key in channelsEnabled allowedChannelPlugins enabledPlugins minimumVersion; do
          local v
          v="$(json_field "$managed" ".$key")"
          if [ -n "$v" ]; then
            verbose ".$key = $v"
            emit PASS "settings" "managed.$key set"
          else
            emit WARN "settings" "managed.$key missing" \
              "Re-run install.sh to refresh /etc/claude-code/managed-settings.json"
          fi
        done

        # sandbox.enabled
        local sb
        sb="$(json_field "$managed" '.sandbox.enabled')"
        if [ "$sb" = "true" ]; then
          emit PASS "settings" "managed.sandbox.enabled = true"
        else
          emit WARN "settings" "managed.sandbox.enabled is '$sb' (expected true)"
        fi
      else
        emit FAIL "settings" "managed settings file invalid JSON: $managed" \
          "Inspect with: jq . '$managed'"
      fi
    else
      emit FAIL "settings" "managed settings missing: $managed" \
        "Re-run install.sh — it installs this file in step 13"
    fi
  fi

  # user settings
  local user_s="${HOME}/.claude/settings.json"
  if [ -f "$user_s" ]; then
    if valid_json "$user_s"; then
      emit PASS "settings" "user settings: $user_s (valid JSON)"
    else
      emit FAIL "settings" "user settings invalid JSON: $user_s"
    fi
  else
    emit WARN "settings" "user settings missing: $user_s" \
      "Optional — Claude Code creates it on first run"
  fi

  # project settings
  local proj_s="${PROJECT_DIR}/.claude/settings.json"
  if [ -f "$proj_s" ]; then
    if valid_json "$proj_s"; then
      emit PASS "settings" "project settings: ${proj_s/$HOME/~} (valid JSON)"
    else
      emit FAIL "settings" "project settings invalid JSON: $proj_s"
    fi
  else
    emit WARN "settings" "no .claude/settings.json in project (cwd=$PROJECT_DIR)"
  fi
}

###############################################################################
# Section 4 — Authentication
###############################################################################

check_auth() {
  section "Authentication"

  local creds_file="${HOME}/.claude/.credentials.json"

  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    emit PASS "auth" "CLAUDE_CODE_OAUTH_TOKEN set in env"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    emit PASS "auth" "ANTHROPIC_API_KEY set in env (Console-billed)"
  elif [ -f "$creds_file" ]; then
    emit PASS "auth" "credentials file: ${creds_file/$HOME/~}"
  else
    # check env file too
    local env_file=""
    case "$OS" in
      linux) env_file="/etc/agent-os/agent-os.env" ;;
    esac
    if [ -n "$env_file" ] && [ -r "$env_file" ] \
        && grep -qE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=.+' "$env_file" 2>/dev/null; then
      emit PASS "auth" "auth credentials in $env_file"
    elif [ "$OS" = "macos" ]; then
      # On macOS Claude stores OAuth in Keychain. We can't introspect from
      # bash without a trusted prompt, so report INFO not FAIL.
      emit WARN "auth" "no auth in env / file (macOS uses Keychain — usually fine)" \
        "Verify with: claude --version --print 'echo ok'"
    else
      emit FAIL "auth" "no auth credentials found" \
        "Set CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, or run 'claude setup-token'"
    fi
  fi
}

###############################################################################
# Section 5 — services (systemd or launchd)
###############################################################################

check_services_linux() {
  if [ "$MODE_MINIMAL" = "1" ]; then
    emit SKIP "services" "--minimal: skipping systemd checks"
    return 0
  fi

  # We probe well-known unit names. If none are loaded, that may be fine for
  # template-only checkout — emit SKIP. If at least one is loaded, the
  # template is "installed" and we do strict checks on the rest.
  local any_loaded=0
  local u
  for u in agent-os-saga.service agent-os-operator.service \
           agent-os-dispatcher.timer agent-os-dispatcher.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 \
       && [ -n "$(systemctl show -p Id "$u" 2>/dev/null | grep -v '^Id=$')" ]; then
      any_loaded=1
      break
    fi
  done

  if [ "$any_loaded" = "0" ]; then
    emit SKIP "services" "no agent-os-*.service unit files installed yet" \
      "Run install.sh on a Linux box to render units to /etc/systemd/system/"
    return 0
  fi

  # saga
  if systemctl is-active --quiet agent-os-saga.service 2>/dev/null; then
    emit PASS "services" "agent-os-saga.service active"
  else
    emit FAIL "services" "agent-os-saga.service NOT active" \
      "journalctl -u agent-os-saga.service -n 50"
  fi

  # operator (only if not minimal)
  if systemctl list-unit-files agent-os-operator.service >/dev/null 2>&1; then
    if systemctl is-active --quiet agent-os-operator.service 2>/dev/null; then
      emit PASS "services" "agent-os-operator.service active"
    else
      emit FAIL "services" "agent-os-operator.service NOT active" \
        "journalctl -u agent-os-operator.service -n 50"
    fi
  fi

  # dispatcher.timer
  if systemctl list-unit-files agent-os-dispatcher.timer >/dev/null 2>&1; then
    if systemctl is-enabled --quiet agent-os-dispatcher.timer 2>/dev/null; then
      emit PASS "services" "agent-os-dispatcher.timer enabled"
    else
      emit FAIL "services" "agent-os-dispatcher.timer NOT enabled" \
        "systemctl enable --now agent-os-dispatcher.timer"
    fi
  fi
}

check_services_macos() {
  if [ "$MODE_MINIMAL" = "1" ]; then
    emit SKIP "services" "--minimal: skipping launchd checks"
    return 0
  fi

  # We don't know PROJECT_SLUG (substituted at install). Probe common names.
  local found=0 label
  for label in $(launchctl list 2>/dev/null | awk '/\.(saga-mcp|claude-peers-broker|operator|heartbeat-dispatcher|telegram-mcp)$/ {print $3}'); do
    found=1
    emit PASS "services" "launchd job loaded: $label"
  done
  if [ "$found" = "0" ]; then
    emit SKIP "services" "no AgentOS launchd jobs loaded" \
      "Render & load: see launchd/com.\${PROJECT_SLUG}.*.plist"
  fi
}

check_services() {
  section "Services"
  case "$OS" in
    linux) check_services_linux ;;
    macos) check_services_macos ;;
    *)     emit SKIP "services" "unsupported OS" ;;
  esac
}

###############################################################################
# Section 6 — HTTP health
###############################################################################

check_http_health() {
  section "HTTP health"

  if [ "$MODE_MINIMAL" = "1" ]; then
    emit SKIP "http" "--minimal: skipping HTTP health checks"
    return 0
  fi

  # claude-peers broker (auto-bootstrap on first plugin spawn — may not be up
  # at install time)
  local cp_url="${CLAUDE_PEERS_HEALTH_URL:-http://127.0.0.1:7899/health}"
  if http_ok "$cp_url"; then
    emit PASS "http" "claude-peers broker $cp_url 2xx"
  elif port_listening 7899 2>/dev/null; then
    emit WARN "http" "claude-peers port 7899 listening but $cp_url not 2xx"
  else
    emit WARN "http" "claude-peers broker DOWN ($cp_url)" \
      "Auto-spawns when first plugin session connects — may be normal"
  fi

  # saga-mcp
  local saga_url="${SAGA_MCP_HEALTH_URL:-http://127.0.0.1:3851/health}"
  if http_ok "$saga_url"; then
    emit PASS "http" "saga-mcp $saga_url 2xx"
  elif http_ok "${saga_url%/health}/" 2>/dev/null; then
    emit PASS "http" "saga-mcp responding (no /health, but root 2xx)"
  elif port_listening 3851 2>/dev/null; then
    emit WARN "http" "saga-mcp port 3851 listening but $saga_url not 2xx"
  else
    case "$OS" in
      linux) emit FAIL "http" "saga-mcp DOWN" \
              "systemctl restart agent-os-saga.service && journalctl -u agent-os-saga -n 50" ;;
      *)     emit WARN "http" "saga-mcp DOWN — start saga-mcp launchd job" ;;
    esac
  fi

  # telegram-mcp (optional health endpoint)
  local tg_url="${TELEGRAM_MCP_HEALTH_URL:-}"
  if [ -n "$tg_url" ]; then
    if http_ok "$tg_url"; then
      emit PASS "http" "telegram-mcp $tg_url 2xx"
    else
      emit WARN "http" "telegram-mcp DOWN ($tg_url)"
    fi
  else
    emit SKIP "http" "TELEGRAM_MCP_HEALTH_URL unset (telegram is stdio plugin — usually fine)"
  fi
}

###############################################################################
# Section 7 — Plugins (vendored + cached)
###############################################################################

check_plugins() {
  section "Plugins"

  local p
  # Vendored plugins live in the repo's plugins/ dir
  for p in claude-peers telegram agent-sdk-dev code-review commit-commands security-guidance; do
    local plug_dir="${PROJECT_DIR}/plugins/${p}"
    local plug_json="${plug_dir}/.claude-plugin/plugin.json"
    if [ -f "$plug_json" ]; then
      if valid_json "$plug_json"; then
        emit PASS "plugins" "vendored plugin: $p"
      else
        emit FAIL "plugins" "plugin.json invalid JSON: $plug_json"
      fi
    else
      emit WARN "plugins" "vendored plugin missing: $p" \
        "Expected at $plug_dir"
    fi
  done

  # Marketplace
  local mp="${PROJECT_DIR}/.claude-plugin/marketplace.json"
  if [ -f "$mp" ]; then
    if valid_json "$mp"; then
      local count
      count="$(json_field "$mp" '.plugins | length')"
      emit PASS "plugins" "marketplace.json valid ($count plugins listed)"
    else
      emit FAIL "plugins" "marketplace.json invalid JSON: $mp"
    fi
  else
    emit WARN "plugins" "marketplace.json missing at $mp"
  fi

  # User-level plugin cache (populated by Claude Code on first marketplace add)
  local cache="${HOME}/.claude/plugins/cache"
  if [ -d "$cache" ]; then
    emit PASS "plugins" "plugin cache dir present: ${cache/$HOME/~}"
    if [ -d "${cache}/agentos" ]; then
      emit PASS "plugins" "agentos marketplace cached"
    else
      emit WARN "plugins" "agentos marketplace not cached" \
        "First Claude Code session will populate ${cache}/agentos/"
    fi
  else
    emit WARN "plugins" "plugin cache dir missing: ${cache/$HOME/~}" \
      "Created automatically on first claude invocation"
  fi
}

###############################################################################
# Section 8 — Project hooks
###############################################################################

check_hooks() {
  section "Project hooks"

  local hooks_dir="${PROJECT_DIR}/.claude/hooks"
  if [ ! -d "$hooks_dir" ]; then
    emit FAIL "hooks" ".claude/hooks dir missing in project"
    return 0
  fi

  local h
  for h in _common.sh boot.sh enrich-prompt.sh guard-bash.sh guard-edit.sh \
           log-action.sh log-subagent.sh notify-stop.sh session-end.sh; do
    local f="${hooks_dir}/${h}"
    if [ ! -f "$f" ]; then
      emit FAIL "hooks" "missing hook: $h"
      continue
    fi
    if [ ! -x "$f" ]; then
      if [ "$MODE_FIX" = "1" ]; then
        chmod +x "$f" 2>/dev/null && emit FIX "hooks" "chmod +x $h"
      else
        emit WARN "hooks" "hook not executable: $h" \
          "chmod +x $f (or re-run verify with --fix)"
      fi
    else
      emit PASS "hooks" "$h executable"
    fi
  done

  # Smoke test guard-bash.sh
  local gb="${hooks_dir}/guard-bash.sh"
  if [ -x "$gb" ]; then
    local rc
    set +e
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
      printf '{"tool_input":{"command":"rm -rf /"}}' \
      | "$gb" >/dev/null 2>&1
    rc=$?
    set -e 2>/dev/null || true
    if [ "$rc" = "2" ]; then
      emit PASS "hooks" "guard-bash.sh blocks 'rm -rf /' (exit 2 as expected)"
    else
      emit FAIL "hooks" "guard-bash.sh did NOT block 'rm -rf /' (exit $rc)" \
        "Inspect $gb — security gate is broken"
    fi

    # Smoke test passing input
    set +e
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
      printf '{"tool_input":{"command":"ls -la"}}' \
      | "$gb" >/dev/null 2>&1
    rc=$?
    set -e 2>/dev/null || true
    if [ "$rc" = "0" ]; then
      emit PASS "hooks" "guard-bash.sh allows benign 'ls -la' (exit 0)"
    else
      emit WARN "hooks" "guard-bash.sh exited $rc on benign 'ls -la'"
    fi
  fi

  # Smoke test guard-edit.sh
  local ge="${hooks_dir}/guard-edit.sh"
  if [ -x "$ge" ]; then
    local rc
    set +e
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
      printf '{"tool_input":{"file_path":"/etc/agent-os/agent-os.env"}}' \
      | "$ge" >/dev/null 2>&1
    rc=$?
    set -e 2>/dev/null || true
    if [ "$rc" = "2" ]; then
      emit PASS "hooks" "guard-edit.sh blocks .env edits (exit 2)"
    else
      emit WARN "hooks" "guard-edit.sh did NOT block .env edit (exit $rc) — may be OK if pattern differs"
    fi
  fi
}

###############################################################################
# Section 9 — Env file (Linux only)
###############################################################################

check_env_file() {
  section "Env file"

  if [ "$OS" != "linux" ]; then
    emit SKIP "env" "macOS uses launchd EnvironmentVariables, not /etc/agent-os/agent-os.env"
    return 0
  fi

  local envf="/etc/agent-os/agent-os.env"
  if [ ! -f "$envf" ]; then
    emit WARN "env" "$envf missing — install.sh hasn't run yet?" \
      "Expected for fresh checkouts; required after install"
    return 0
  fi

  if [ -r "$envf" ]; then
    emit PASS "env" "$envf exists and readable"
  else
    emit WARN "env" "$envf exists but unreadable to current user — that's expected (mode 0640, root:agent-os)"
  fi

  # mode check (best effort — only if readable to stat)
  if [ -r "$envf" ]; then
    local mode
    mode="$(stat -c '%a' "$envf" 2>/dev/null || stat -f '%Lp' "$envf" 2>/dev/null)"
    if [ "$mode" = "640" ] || [ "$mode" = "600" ]; then
      emit PASS "env" "mode $mode (correct: 640 root:agent-os, or stricter)"
    else
      emit WARN "env" "mode $mode (expected 640 or 600)" \
        "chmod 640 $envf && chown root:agent-os $envf"
    fi
  fi

  # required keys present
  if [ -r "$envf" ]; then
    local key
    for key in TZ PROJECT_NAME DB_PATH; do
      if grep -qE "^$key=" "$envf"; then
        emit PASS "env" "$key defined in $envf"
      else
        emit WARN "env" "$key missing in $envf" \
          "Re-run install.sh — step 11 (env file) writes these"
      fi
    done
    # at least one auth method
    if grep -qE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=.+' "$envf"; then
      emit PASS "env" "auth token / API key defined"
    else
      emit FAIL "env" "no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY in $envf"
    fi
  fi
}

###############################################################################
# Section 10 — State directories (Linux only)
###############################################################################

check_state_dirs() {
  section "State directories"

  if [ "$OS" != "linux" ]; then
    emit SKIP "state" "Linux-specific paths"
    return 0
  fi

  local d
  for d in /var/lib/agent-os /var/lib/agent-os/claude-config \
           /var/lib/agent-os/claude-config/operator \
           /var/lib/agent-os/claude-config/dispatcher \
           /var/lib/agent-os/claude-config/heartbeat; do
    if [ -d "$d" ]; then
      emit PASS "state" "$d exists"
    else
      if [ "$MODE_FIX" = "1" ]; then
        fix_mkdir_700 "$d"
      else
        emit WARN "state" "$d missing" \
          "Re-run install.sh (step 6) or verify --fix"
      fi
    fi
  done
}

###############################################################################
# Section 11 — Logs
###############################################################################

check_logs() {
  section "Logs"

  local hooks_log="${AGENTOS_HOOKS_LOG_DIR:-/tmp/agentos-hooks}"
  if [ -d "$hooks_log" ]; then
    if [ -w "$hooks_log" ]; then
      emit PASS "logs" "$hooks_log writable"
    else
      emit WARN "logs" "$hooks_log not writable by $(id -un)"
    fi
  else
    if [ "$MODE_FIX" = "1" ]; then
      mkdir -p "$hooks_log" 2>/dev/null && emit FIX "logs" "created $hooks_log"
    else
      emit SKIP "logs" "$hooks_log missing (created on first hook fire)"
    fi
  fi

  if [ "$OS" = "linux" ]; then
    local d
    for d in /var/log/agent-os; do
      if [ -d "$d" ]; then
        emit PASS "logs" "$d exists"
      else
        emit WARN "logs" "$d missing — install.sh creates this in step 6"
      fi
    done
  fi
}

###############################################################################
# Section 12 — claude doctor
###############################################################################

check_doctor() {
  section "claude doctor"

  if ! command -v claude >/dev/null 2>&1; then
    emit SKIP "doctor" "claude not installed"
    return 0
  fi

  # /doctor is interactive in TUI; --help test prefix may not exist. Try
  # --doctor flag if Claude Code supports it; otherwise note we can't run.
  if claude --help 2>&1 | grep -q -- '--doctor\|/doctor'; then
    if claude --doctor >/dev/null 2>&1; then
      emit PASS "doctor" "claude --doctor exited 0"
    else
      emit WARN "doctor" "claude --doctor reported issues — run interactively to inspect"
    fi
  else
    emit SKIP "doctor" "claude --doctor flag not supported on this version"
  fi
}

###############################################################################
# Run + report
###############################################################################

main() {
  if [ "$MODE_QUIET" = "0" ] && [ "$MODE_JSON" = "0" ]; then
    printf '%sAgentOS verify.sh%s — %s%s%s\n' \
      "$C_BOLD" "$C_RESET" "$C_DIM" "v$SCRIPT_VERSION" "$C_RESET"
    printf 'Project dir: %s\n' "$PROJECT_DIR"
    printf 'OS:          %s\n' "$OS"
    if [ "$MODE_MINIMAL" = "1" ]; then
      printf 'Mode:        %s--minimal%s\n' "$C_YELLOW" "$C_RESET"
    fi
    if [ "$MODE_FIX" = "1" ]; then
      printf 'Fix:         %s--fix%s (auto-repair benign issues)\n' "$C_YELLOW" "$C_RESET"
    fi
  fi

  check_binaries
  check_os
  check_settings
  check_auth
  check_services
  check_http_health
  check_plugins
  check_hooks
  check_env_file
  check_state_dirs
  check_logs
  check_doctor

  # Final report
  if [ "$MODE_JSON" = "1" ]; then
    printf '{"version":"%s","os":"%s","passed":%d,"failed":%d,"warned":%d,"skipped":%d,"fixed":%d,"events":[%s]}\n' \
      "$SCRIPT_VERSION" "$OS" \
      "$VERIFY_PASSED" "$VERIFY_FAILED" "$VERIFY_WARNED" "$VERIFY_SKIPPED" "$VERIFY_FIXED" \
      "$JSON_EVENTS"
  elif [ "$MODE_QUIET" = "0" ]; then
    printf '\n%s== Summary ==%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s%d passed%s   %s%d failed%s   %s%d warned%s   %s%d skipped%s' \
      "$C_GREEN" "$VERIFY_PASSED" "$C_RESET" \
      "$C_RED" "$VERIFY_FAILED" "$C_RESET" \
      "$C_YELLOW" "$VERIFY_WARNED" "$C_RESET" \
      "$C_DIM" "$VERIFY_SKIPPED" "$C_RESET"
    if [ "$VERIFY_FIXED" -gt 0 ]; then
      printf '   %s%d fixed%s' "$C_BLUE" "$VERIFY_FIXED" "$C_RESET"
    fi
    printf '\n'
    if [ "$VERIFY_FAILED" -gt 0 ]; then
      printf '\n%sResult: FAIL%s — %d check(s) failed.\n' "$C_RED" "$C_RESET" "$VERIFY_FAILED"
    elif [ "$VERIFY_WARNED" -gt 0 ]; then
      printf '\n%sResult: PASS with warnings%s — review %d warning(s).\n' "$C_YELLOW" "$C_RESET" "$VERIFY_WARNED"
    else
      printf '\n%sResult: PASS%s — all green.\n' "$C_GREEN" "$C_RESET"
    fi
  fi

  if [ "$VERIFY_FAILED" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

main
