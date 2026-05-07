#!/usr/bin/env bash
# AgentOS one-command installer.
#
# Two paths, dispatched by detect_mode (Darwin → remote-setup wizard, Linux
# root → local-install of the 18-step canonical host).
#
# Usage on macOS (NO sudo — wizard runs as your user; sudoes only on the
# remote VPS via ssh):
#   curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | bash
#
# Usage on Linux VPS (Ubuntu 22.04/24.04 or Debian 12+, MUST be root):
#   curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | sudo bash
#   # OR
#   git clone https://github.com/try-agent-os/claude-code-template /tmp/agentos-installer
#   sudo /tmp/agentos-installer/install.sh
#
# Flags:
#   --minimal                       Skip operator + telegram entirely.
#                                   Subsets the install: no telegram plugin bun deps,
#                                   no whisper.cpp build, no telegram bot wizard prompts,
#                                   no telegram-coupled lifecycle hooks (notify-stop,
#                                   log-subagent), no operator systemd unit.
#                                   Result: saga-mcp + dispatcher + claude-peers only
#                                   (~14 install steps instead of 18).
#   --with=feature-dev,frontend-design  Comma-separated optional plugins to vendor
#   --non-interactive               Read all wizard answers from preset env vars (CI/automation)
#   --bootstrap-personal-repo URL   Replace template remote with user's own GitHub fork
#   --whisper=tiny|base|medium      Whisper model size (default medium, 1.5 GB)
#   --harden                        Apply egress firewall (deny by default, allow only api.anthropic.com,
#                                   GitHub, apt repos). Off by default — heavy.
#   --skip-build                    Skip MCP build steps (assume artefacts exist; for re-runs)
#   --resume                        Re-entry from a half-completed install (idempotent anyway)
#   --reset                         Clear /etc/agent-os/install.state.json and re-prompt for everything
#   --force-reinstall               Re-run all steps even if marked completed in state file
#
# Authentication: get a 1-year OAuth token on your local machine with
#   `claude setup-token`
# and either export it as CLAUDE_CODE_OAUTH_TOKEN before running, or paste it
# at the wizard prompt.
#
set -euo pipefail

###############################################################################
# Bootstrap — make `curl … | bash` interactive
#
# When piped, stdin is the script body (not the user's terminal), so any
# `read` inside the wizard would read script bytes as answers. Solution:
# detect the pipe, re-download the script to a temp file, and re-exec with
# stdin attached to /dev/tty. After this block we ALWAYS have:
#   - $0 / BASH_SOURCE pointing at a real on-disk file
#   - stdin = controlling terminal (for `read` prompts)
#   - argv preserved (--minimal, --with=…, --reset, etc.)
#
# Skipped when:
#   - already a tty (`-t 0`)              — direct `bash install.sh` invocation
#   - already re-exec'd (env guard)       — second pass after the exec below
#   - no terminal at all (no -t 1, -t 2)  — CI / headless; user must use env vars
#                                            and pass --non-interactive (we then
#                                            keep the original /dev/tty fallback
#                                            at the bottom and let read fail
#                                            loudly if it tries to prompt)
###############################################################################
readonly _BOOTSTRAP_URL="https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh"

if [ "${_AGENTOS_REEXEC:-0}" != "1" ] && [ ! -t 0 ] && { [ -t 1 ] || [ -t 2 ]; }; then
  _bs_tmp=$(mktemp -d -t agentos-installer-XXXXXX 2>/dev/null) || {
    printf '\033[1;33m[install]\033[0m mktemp failed; falling back to /dev/tty redirect.\n' >&2
    _bs_tmp=""
  }
  if [ -n "$_bs_tmp" ]; then
    _bs_saved="$_bs_tmp/install.sh"
    if command -v curl >/dev/null 2>&1 && \
       curl -fsSL --max-time 30 "$_BOOTSTRAP_URL" -o "$_bs_saved" 2>/dev/null && \
       [ -s "$_bs_saved" ]; then
      chmod +x "$_bs_saved"
      printf '\033[1;32m[install]\033[0m Re-execing from %s with stdin attached to terminal…\n' "$_bs_saved" >&2
      # Cleanup tmp on exit of the re-exec'd process
      export _AGENTOS_BOOTSTRAP_TMP="$_bs_tmp"
      _AGENTOS_REEXEC=1 exec bash "$_bs_saved" "$@" </dev/tty
    else
      printf '\033[1;33m[install]\033[0m Re-fetch from %s failed.\n' "$_BOOTSTRAP_URL" >&2
      printf '\033[1;33m[install]\033[0m Falling back to /dev/tty redirect (less robust).\n' >&2
      rm -rf "$_bs_tmp"
    fi
  fi
fi

# Cleanup the bootstrap tmp dir if we re-exec'd from one.
if [ -n "${_AGENTOS_BOOTSTRAP_TMP:-}" ]; then
  trap 'rm -rf "${_AGENTOS_BOOTSTRAP_TMP:-}"' EXIT
fi

###############################################################################
# Constants
###############################################################################
readonly AGENT_USER="agent-os"
readonly AGENT_HOME="/home/${AGENT_USER}"
readonly INSTALL_ROOT="/opt/agent-os"
readonly LOG_DIR="/var/log/agent-os"
readonly STATE_DIR="/var/lib/agent-os"
readonly ETC_DIR="/etc/agent-os"
readonly ENV_FILE="${ETC_DIR}/agent-os.env"
readonly CLAUDE_MANAGED_DIR="/etc/claude-code"
readonly CLAUDE_MANAGED_FILE="${CLAUDE_MANAGED_DIR}/managed-settings.json"
readonly CLAUDE_CONFIG_BASE="${STATE_DIR}/claude-config"

# Per-agent CLAUDE_CONFIG_DIR (each agent gets its own ~/.claude.json + .credentials.json)
readonly CC_DIR_OPERATOR="${CLAUDE_CONFIG_BASE}/operator"
readonly CC_DIR_DISPATCHER="${CLAUDE_CONFIG_BASE}/dispatcher"
readonly CC_DIR_HEARTBEAT="${CLAUDE_CONFIG_BASE}/heartbeat"

# Anthropic apt repo signing key fingerprint (per code.claude.com/docs/en/setup).
# Keep in sync if Anthropic rotates the key — the install will refuse to proceed
# until this matches what `gpg --show-keys` reports for the downloaded asc file.
readonly ANTHROPIC_KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# Repos to clone. Override TEMPLATE_REPO via --bootstrap-personal-repo.
# claude-peers and telegram are now vendored as plugins inside the template
# repo (plugins/claude-peers, plugins/telegram). saga-mcp remains a separate
# clone — it is a long-running broker, not a plugin.
TEMPLATE_REPO="https://github.com/try-agent-os/claude-code-template"
readonly SAGA_MCP_REPO="https://github.com/spranab/saga-mcp"

# Defaults
WHISPER_MODEL="medium"
DISPATCHER_INTERVAL_SEC="2700"   # 45 min
WITH_PLUGINS=""
MINIMAL=0
NON_INTERACTIVE=0
HARDEN=0
SKIP_BUILD=0
BOOTSTRAP_REPO=""
RESET=0
FORCE_REINSTALL=0

# Where this script lives — used to find systemd templates etc.
# When the script is piped via `curl | bash`, BASH_SOURCE[0] is empty and stdin
# is the script. The fallback chain handles all 3 cases (sourced, executed
# directly, curl-piped). With `set -u` the `:-` defaults prevent unbound errors.
_SELF="${BASH_SOURCE[0]:-${0:-/dev/stdin}}"
if [ -f "$_SELF" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
else
  # curl | bash — no on-disk script. Mac branch will git-clone the template.
  SCRIPT_DIR=""
fi
# The script may be run via `curl | bash` (no SCRIPT_DIR templates) — in that
# case we'll clone the template into INSTALL_ROOT first and re-source from there.
TEMPLATE_DIR="${SCRIPT_DIR}"

###############################################################################
# Logging + error trap
###############################################################################
CURRENT_STEP="init"

# Color output
c_green=$'\033[0;32m'
c_yellow=$'\033[1;33m'
c_red=$'\033[0;31m'
c_blue=$'\033[0;34m'
c_bold=$'\033[1m'
c_reset=$'\033[0m'

log()    { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn()   { printf '%s⚠%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
fail()   { printf '%s✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; _try_autoresolve "$*" 1 || true; exit 1; }
info()   { printf '%s%s%s\n' "$c_blue" "$*" "$c_reset"; }
ok()     { printf '%s✓%s %s\n' "$c_green" "$c_reset" "$*"; }
section() { printf '\n%s═══ %s ═══%s\n' "$c_bold" "$*" "$c_reset"; }
header()  { printf '\n%s┌─ %s%s\n' "$c_bold" "$*" "$c_reset"; }

# bash 3.2 (macOS system bash) has no ${var,,} / ${var^^} case-conversion.
# Use these helpers instead.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Save original argv so the autoresolve hook can re-exec the script with the
# same flags after Claude fixes whatever broke.
_ORIGINAL_ARGV=("$@")

# Auto-resolve hook: when a step fails, dispatch Claude (if installed +
# authenticated) to diagnose and fix in-place, then re-exec. Skipped when:
#   - AGENTOS_AUTORESOLVE=0 (user disabled)
#   - claude not yet installed (steps 1–4 on a fresh VPS — autoresolve only
#     becomes active from step 5+ on Linux; on Mac wizard side, claude is
#     usually present and AUTORESOLVE works for any remote-side failure
#     that bubbles up to local fail())
#   - already inside an autoresolve attempt (no recursion)
#   - state file says we already exhausted AGENTOS_AUTORESOLVE_MAX attempts
# Toggle off for CI / debugging via: AGENTOS_AUTORESOLVE=0 install.sh …
_try_autoresolve() {
  local fail_msg="$1" exit_code="${2:-1}"
  [[ "${AGENTOS_AUTORESOLVE:-1}" = "1" ]] || return 1
  [[ "${_AGENTOS_AUTORESOLVING:-0}" = "0" ]] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] || return 1

  local max="${AGENTOS_AUTORESOLVE_MAX:-2}" attempts=0
  if declare -F state_get >/dev/null 2>&1 && [[ -f "${STATE_FILE:-}" ]]; then
    attempts=$(state_get "autoresolve_attempts" "0" 2>/dev/null || echo 0)
  fi
  if [[ "$attempts" -ge "$max" ]]; then
    warn "Auto-resolve exhausted ($attempts/$max attempts already used)."
    return 1
  fi
  if declare -F state_set >/dev/null 2>&1; then
    state_set "autoresolve_attempts" "$((attempts + 1))" 2>/dev/null || true
  fi

  warn "Auto-resolve $((attempts + 1))/$max: dispatching Claude for diagnosis…"

  local ctx; ctx=$(mktemp -t agentos-autoresolve-ctx.XXXXXX)
  {
    printf '## Failed step\n%s\n\n' "${CURRENT_STEP:-unknown}"
    printf '## Failure message\n%s\n\n' "$fail_msg"
    printf '## Exit code\n%s\n\n' "$exit_code"
    printf '## Last 80 lines of dispatcher.log (if any)\n'
    tail -80 /var/log/agent-os/install.log 2>/dev/null || echo "(no log)"
    printf '\n## OS\n'
    [ -r /etc/os-release ] && cat /etc/os-release || echo "(macOS or unknown)"
    printf '\n## Disk\n'
    df -h / 2>/dev/null
    printf '\n## apt sources.list.d\n'
    ls -la /etc/apt/sources.list.d/ 2>/dev/null || echo "(no apt)"
    printf '\n## Install state\n'
    [ -f "${STATE_FILE:-}" ] && jq . "$STATE_FILE" 2>/dev/null || echo "(no state)"
  } > "$ctx"

  local prompt="AgentOS install.sh failed at step '${CURRENT_STEP:-unknown}'.

Diagnose the root cause and apply a targeted fix. Then exit — the installer will re-execute and re-attempt the failed step.

You have root on this Linux VPS. Failure context is at $ctx (read it).

Constraints:
  - DO NOT modify install.sh itself; the script will be re-executed.
  - DO NOT run destructive operations (rm -rf /, mkfs, dropping databases) unless absolutely necessary and you've verified the impact.
  - Stay within the scope of '${CURRENT_STEP:-unknown}'; don't install completely different stacks.
  - When done, write a single line to /tmp/agentos-autoresolve-result with format:
        fixed: <brief description of what you changed>
    OR
        unresolvable: <one-line reason>

Available --add-dir paths: the failure context, /etc/agent-os, /var/log/agent-os, $INSTALL_ROOT/claude (if exists)."

  rm -f /tmp/agentos-autoresolve-result

  local addargs=("--add-dir" "$ctx")
  [ -d /etc/agent-os ]      && addargs+=("--add-dir" /etc/agent-os)
  [ -d /var/log/agent-os ]  && addargs+=("--add-dir" /var/log/agent-os)
  [ -d "${INSTALL_ROOT:-}/claude" ] && addargs+=("--add-dir" "${INSTALL_ROOT}/claude")

  if ! _AGENTOS_AUTORESOLVING=1 claude \
      --dangerously-skip-permissions \
      "${addargs[@]}" \
      -p "$prompt"; then
    warn "Claude session itself errored; abandoning autoresolve."
    rm -f "$ctx"
    return 1
  fi

  rm -f "$ctx"

  if [[ -f /tmp/agentos-autoresolve-result ]]; then
    local result; result=$(head -1 /tmp/agentos-autoresolve-result)
    case "$result" in
      fixed:*)
        ok "Auto-resolve: $result"
        ok "Re-executing install.sh to retry the failed step…"
        # State file preserves completed steps; autoresolve_attempts counter
        # was incremented above so we won't loop forever.
        exec bash "${BASH_SOURCE[0]}" "${_ORIGINAL_ARGV[@]}"
        ;;
      unresolvable:*)
        warn "Auto-resolve gave up: $result"
        ;;
      *)
        warn "Auto-resolve produced unexpected result: $result"
        ;;
    esac
  else
    warn "Auto-resolve session ended without writing /tmp/agentos-autoresolve-result"
  fi
  return 1
}

on_err() {
  local exit_code=$? line=$1
  printf '\n\033[1;31m[install] FAILED at step "%s" (line %s, exit %s)\033[0m\n' \
    "${CURRENT_STEP}" "${line}" "${exit_code}" >&2
  _try_autoresolve "ERR trap at line $line" "$exit_code" || true
  printf '[install] Re-run the same command — install.sh is idempotent.\n' >&2
  exit "${exit_code}"
}
trap 'on_err $LINENO' ERR

step() { CURRENT_STEP="$1"; log "==> $1"; }

###############################################################################
# State file — non-secret answers persisted between runs
###############################################################################
# On macOS we run as the user (no sudo), so /etc/agent-os/ is unwritable; persist
# under the user's home next to DEPLOY_STATE. On Linux the canonical install runs
# as root, so /etc/agent-os/install.state.json stays the system-wide source of truth.
if [[ "${OSTYPE:-}" == darwin* ]]; then
  STATE_FILE="$HOME/.agent-os-deploy/install.state.json"
else
  STATE_FILE="/etc/agent-os/install.state.json"
fi

# Read a value from state file (returns "" if absent)
state_get() {
  local key="$1"; local default="${2:-}"
  if [ -f "$STATE_FILE" ]; then
    jq -r --arg k "$key" --arg d "$default" '(.[$k] // $d) | tostring' "$STATE_FILE" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

# Write a value to state file. type: string|number|bool
state_set() {
  local key="$1"; local value="$2"; local type="${3:-string}"
  mkdir -p "$(dirname "$STATE_FILE")"
  if [ ! -f "$STATE_FILE" ]; then
    echo '{"version": 1, "first_run_at": "'"$(date -Iseconds)"'", "completed_steps": []}' > "$STATE_FILE"
  fi
  local now
  now="$(date -Iseconds)"
  if [ "$type" = "number" ] || [ "$type" = "bool" ]; then
    jq --arg k "$key" --argjson v "$value" --arg now "$now" \
      '.[$k] = $v | .last_run_at = $now' "$STATE_FILE" > "$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    jq --arg k "$key" --arg v "$value" --arg now "$now" \
      '.[$k] = $v | .last_run_at = $now' "$STATE_FILE" > "$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
  chmod 0640 "$STATE_FILE" 2>/dev/null || true
  chown root:agent-os "$STATE_FILE" 2>/dev/null || true
}

# Prompt with default loaded from state file
ask() {
  local prompt="$1"; local key="$2"; local default="${3:-}"
  local prev answer
  prev=$(state_get "$key" "$default")
  if [ -n "$prev" ] && [ "$prev" != "null" ]; then
    printf "  %s [%s%s%s]: " "$prompt" "$c_blue" "$prev" "$c_reset" >&2
    read -r answer
    answer="${answer:-$prev}"
  else
    printf "  %s: " "$prompt" >&2
    read -r answer
  fi
  state_set "$key" "$answer"
  printf '%s' "$answer"
}

# Silent prompt for secrets — NEVER persisted to state.json
ask_secret() {
  local prompt="$1"; local var_in_env="$2"
  local current_val="" answer
  if [ -f /etc/agent-os/agent-os.env ]; then
    current_val=$(grep "^${var_in_env}=" /etc/agent-os/agent-os.env 2>/dev/null | cut -d= -f2- || true)
  fi
  if [ -n "$current_val" ]; then
    printf "  %s [%skept from previous%s, type 'reset' to re-enter]: " "$prompt" "$c_blue" "$c_reset" >&2
    read -rs answer; echo >&2
    if [ "$answer" = "reset" ]; then
      printf "  %s: " "$prompt" >&2
      read -rs answer; echo >&2
    elif [ -z "$answer" ]; then
      answer="$current_val"
    fi
  else
    printf "  %s: " "$prompt" >&2
    read -rs answer; echo >&2
  fi
  printf '%s' "$answer"
}

# Resume prompt at start of wizard
prompt_resume() {
  if [ -f "$STATE_FILE" ]; then
    local first count
    first=$(state_get "first_run_at")
    count=$(jq -r '.completed_steps | length' "$STATE_FILE" 2>/dev/null || echo 0)
    section "AgentOS Install Wizard"
    info "Found existing install state from: $first"
    info "Steps completed: $count"
    if [ "${RESET:-0}" = "1" ]; then
      warn "Reset mode — clearing state."
      rm -f "$STATE_FILE"
      return
    fi
    if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
      ok "Non-interactive — resuming."
      return
    fi
    printf "Resume from previous state? [%sY%s/n]: " "$c_green" "$c_reset"
    read -r choice
    if [ "$(lower "$choice")" = "n" ] || [ "$(lower "$choice")" = "no" ]; then
      warn "Starting fresh."
      mv "$STATE_FILE" "$STATE_FILE.bak.$(date +%s)"
    else
      ok "Resuming."
    fi
  else
    section "AgentOS Install Wizard"
    info "First run — let's configure your AgentOS instance."
  fi
}

# Mark step completed
mark_step_completed() {
  local s="$1"
  if [ -f "$STATE_FILE" ]; then
    jq --argjson s "$s" '.completed_steps |= (. + [$s] | unique)' "$STATE_FILE" > "$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
}

# Check whether step is already done
step_done() {
  local s="$1"
  [ -f "$STATE_FILE" ] || return 1
  jq -e --argjson s "$s" '.completed_steps | index($s)' "$STATE_FILE" >/dev/null 2>&1
}

###############################################################################
# Arg parsing
###############################################################################
for arg in "$@"; do
  case "$arg" in
    --minimal) MINIMAL=1 ;;
    --with=*) WITH_PLUGINS="${arg#--with=}" ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --bootstrap-personal-repo=*|--bootstrap-personal-repo)
      if [[ "$arg" == --bootstrap-personal-repo ]]; then
        fail "--bootstrap-personal-repo requires =URL form"
      fi
      BOOTSTRAP_REPO="${arg#--bootstrap-personal-repo=}"
      TEMPLATE_REPO="$BOOTSTRAP_REPO"
      ;;
    --whisper=*) WHISPER_MODEL="${arg#--whisper=}" ;;
    --harden) HARDEN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --resume) ;; # no-op; whole script is idempotent
    --reset) RESET=1 ;;
    --force-reinstall) FORCE_REINSTALL=1 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;$d'
      exit 0 ;;
    *) fail "Unknown flag: $arg" ;;
  esac
done

case "$WHISPER_MODEL" in
  tiny|base|medium) ;;
  *) fail "--whisper must be one of: tiny | base | medium" ;;
esac

###############################################################################
# Smart entrypoint: macOS → remote-setup wizard, Linux/root → local install
#
# The same install.sh works two ways:
#   • Run on a Mac → orchestrates a remote VPS install (provisions or attaches
#     to an existing SSH alias, rsyncs the repo, runs install.sh remotely with
#     --non-interactive).
#   • Run on Linux as root → installs AgentOS locally (existing flow below).
#
# This dispatch happens AFTER arg parsing so wizard answers can come from env
# (PROJECT_NAME, TG_BOT_TOKEN, etc.) and known flags are already consumed.
###############################################################################
detect_mode() {
  if [ "$(uname)" = "Darwin" ]; then
    echo "remote-setup"
  elif [ "$(uname)" = "Linux" ] && [ -d /etc/systemd/system ]; then
    if [ "$(id -u)" -ne 0 ]; then
      printf "%s✗%s install.sh on Linux must run as root. Re-run with: sudo bash install.sh\n" "$c_red" "$c_reset" >&2
      exit 1
    fi
    echo "local-install"
  else
    printf "%s✗%s Unsupported environment. install.sh runs on macOS (provisions remote VPS) or Ubuntu/Debian root (local install).\n" "$c_red" "$c_reset" >&2
    exit 1
  fi
}

###############################################################################
# Mac branch — remote-setup wizard
###############################################################################
DEPLOY_STATE_DIR="$HOME/.agent-os-deploy"
DEPLOY_STATE="${DEPLOY_STATE_DIR}/state.json"

deploy_state_init() {
  mkdir -p "$DEPLOY_STATE_DIR"
  if [ ! -f "$DEPLOY_STATE" ]; then
    echo '{"version":1,"hosts":{}}' > "$DEPLOY_STATE"
  fi
}

deploy_state_save_host() {
  # args: alias ip provider region size
  local alias="$1" ip="$2" provider="$3" region="$4" size="$5"
  local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg a "$alias" --arg ip "$ip" --arg p "$provider" --arg r "$region" --arg s "$size" --arg now "$now" \
    '.hosts[$a] = {ip:$ip, provider:$p, region:$r, size:$s, created_at:$now}' \
    "$DEPLOY_STATE" > "$DEPLOY_STATE.tmp" && mv "$DEPLOY_STATE.tmp" "$DEPLOY_STATE"
}

deploy_state_known_aliases() {
  jq -r '.hosts | keys[]' "$DEPLOY_STATE" 2>/dev/null || true
}

# Check that a CLI is installed; if not, suggest brew install and bail.
require_cli() {
  local cli="$1" pkg="$2"
  if ! command -v "$cli" >/dev/null 2>&1; then
    fail "$cli not found. Install with: brew install $pkg"
  fi
}

# Append (idempotent) an SSH alias to ~/.ssh/config.
# On reprovision: if Host alias exists with a different HostName, strip the
# stale block and append a fresh one (also clears stale known_hosts entries).
ssh_config_add_alias() {
  local alias="$1" ip="$2" user="${3:-root}" identity="${4:-$HOME/.ssh/id_ed25519}"
  local cfg="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh"
  touch "$cfg"
  chmod 600 "$cfg"
  if grep -qE "^Host[[:space:]]+${alias}\$" "$cfg" 2>/dev/null; then
    local existing_ip
    existing_ip=$(awk -v a="$alias" '
      $1=="Host" && $2==a { in_block=1; next }
      $1=="Host" { in_block=0 }
      in_block && tolower($1)=="hostname" { print $2; exit }
    ' "$cfg")
    if [ "$existing_ip" = "$ip" ]; then
      info "  ~/.ssh/config Host '$alias' HostName matches ($ip), leaving as is."
      return
    fi
    info "  ~/.ssh/config Host '$alias' HostName ${existing_ip:-<unset>} → $ip — updating."
    awk -v a="$alias" '
      $1=="Host" && $2==a { skip=1; next }
      $1=="Host" { skip=0 }
      !skip { print }
    ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg" && chmod 600 "$cfg"
    ssh-keygen -R "$alias" >/dev/null 2>&1 || true
    if [ -n "$existing_ip" ]; then
      ssh-keygen -R "$existing_ip" >/dev/null 2>&1 || true
    fi
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  fi
  cat >> "$cfg" <<EOF

Host ${alias}
  HostName ${ip}
  User ${user}
  IdentityFile ${identity}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  ok "  added ~/.ssh/config Host '$alias' → $ip (IdentityFile ${identity})"
}

# Detect user's primary local SSH private key. Tries common paths in order.
# Returns absolute path. If none found, generates ed25519 (with prompt).
# Sets globals: $SSH_PRIVATE_KEY, $SSH_PUBLIC_KEY, $SSH_KEY_FINGERPRINT
detect_or_generate_ssh_key() {
  # Skip detection if already set in this session
  if [ -n "${SSH_PRIVATE_KEY:-}" ] && [ -f "$SSH_PRIVATE_KEY" ]; then
    return 0
  fi
  local candidates=(
    "$HOME/.ssh/id_ed25519"
    "$HOME/.ssh/id_rsa"
    "$HOME/.ssh/id_ecdsa"
    "$HOME/.ssh/id_dsa"
  )
  local k
  for k in "${candidates[@]}"; do
    if [ -f "$k" ] && [ -f "$k.pub" ]; then
      SSH_PRIVATE_KEY="$k"
      SSH_PUBLIC_KEY="$k.pub"
      SSH_KEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_PUBLIC_KEY" 2>/dev/null | awk '{print $2}')
      ok "Using SSH key: $SSH_PRIVATE_KEY ($SSH_KEY_FINGERPRINT)"
      return 0
    fi
  done

  # No key found — offer to generate
  warn "No SSH key found in ~/.ssh/ (checked id_ed25519, id_rsa, id_ecdsa, id_dsa)"
  printf "  Generate ed25519 key now? [%sY%s/n]: " "$c_green" "$c_reset"
  local gen
  read -r gen
  if [ "$(lower "$gen")" = "n" ]; then
    fail "No SSH key — cannot continue. Generate one with: ssh-keygen -t ed25519"
  fi
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "agentos-deploy"
  SSH_PRIVATE_KEY="$HOME/.ssh/id_ed25519"
  SSH_PUBLIC_KEY="$HOME/.ssh/id_ed25519.pub"
  SSH_KEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_PUBLIC_KEY" 2>/dev/null | awk '{print $2}')
  ok "Generated $SSH_PRIVATE_KEY"
}

# Wait for SSH to become reachable AND authenticate on a freshly-provisioned host.
# Bounded loop: max_attempts × 2s. Tests real auth (BatchMode), not just port.
wait_until_ssh_ready() {
  local alias="$1"
  local max_attempts="${2:-60}"  # 60 × 2s = 2 min
  local i
  printf "  Waiting for sshd on %s" "$alias"
  for i in $(seq 1 "$max_attempts"); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$alias" true 2>/dev/null; then
      printf "\n"
      ok "SSH auth OK after ${i} × 2s"
      return 0
    fi
    sleep 2
    printf "."
  done
  printf "\n"
  fail "  SSH to $alias failed after $((max_attempts * 2))s.

  Most likely cause: SSH key mismatch.

  Check:
    • cat ~/.ssh/config | grep -A 5 'Host $alias' — what IdentityFile is configured
    • ls ~/.ssh/id_* — what private keys exist on this Mac
    • doctl compute ssh-key list — what keys are registered with DigitalOcean (or hcloud / linode-cli)

  If the wizard registered the wrong key with the provider, fix:
    1. Add this Mac's key to the provider:
       doctl compute ssh-key import agentos-deploy --public-key-file ${SSH_PUBLIC_KEY:-~/.ssh/id_ed25519.pub}
    2. Delete the stuck droplet:
       doctl compute droplet delete $alias --force
    3. Re-run: bash install.sh   (resumes from state.json)
  "
}

prompt_existing_alias() {
  header "Pick existing SSH alias"
  local known_hosts
  known_hosts=$(awk '/^[Hh]ost[[:space:]]+[^*]+$/ {print $2}' "$HOME/.ssh/config" 2>/dev/null || true)
  if [ -n "$known_hosts" ]; then
    info "  Hosts in ~/.ssh/config:"
    echo "$known_hosts" | sed 's/^/    - /'
  else
    warn "  No Host entries found in ~/.ssh/config."
  fi
  printf "  Alias to use: "
  read -r SSH_ALIAS
  if [ -z "${SSH_ALIAS:-}" ]; then
    fail "No alias provided."
  fi
  # Verify the alias resolves; do NOT touch ~/.ssh/config (user's existing entry stays as-is).
  if ! ssh -G "$SSH_ALIAS" >/dev/null 2>&1; then
    fail "ssh -G '$SSH_ALIAS' failed — alias not configured. Add to ~/.ssh/config or pick another."
  fi
  ok "  Using existing alias '$SSH_ALIAS' (~/.ssh/config left untouched)"
}

ensure_brew_cli() {
  # args: cli_name brew_pkg human_label
  local cli="$1" pkg="$2" label="${3:-$1}"
  if command -v "$cli" >/dev/null 2>&1; then
    return 0
  fi
  warn "$label not installed."
  if command -v brew >/dev/null 2>&1; then
    printf "  Install via brew? [%sY%s/n]: " "$c_green" "$c_reset"
    local b
    read -r b
    if [ "$(lower "$b")" != "n" ]; then
      brew install "$pkg" || fail "brew install $pkg failed"
      return 0
    else
      info "Install manually: brew install $pkg"
      return 1
    fi
  else
    info "Install Homebrew first: https://brew.sh — then 'brew install $pkg'"
    return 1
  fi
}

provision_do_droplet() {
  header "Provision DigitalOcean droplet"
  ensure_brew_cli doctl doctl "doctl" || return 1
  if ! doctl auth list 2>/dev/null | grep -q .; then
    info "Authenticate doctl: doctl auth init"
    info "Get token: https://cloud.digitalocean.com/account/api/tokens"
    printf "  Press ENTER after running 'doctl auth init': "
    read -r _
  fi
  ok "doctl ready"

  # Pick or upload SSH key
  detect_or_generate_ssh_key  # sets SSH_PRIVATE_KEY / SSH_PUBLIC_KEY / SSH_KEY_FINGERPRINT

  # Find or upload local pubkey on DO (match by fingerprint)
  local do_key_id
  do_key_id=$(doctl compute ssh-key list --format ID,FingerprintSHA256 --no-header 2>/dev/null \
    | awk -v fp="$SSH_KEY_FINGERPRINT" '$2==fp {print $1; exit}')

  if [ -z "$do_key_id" ]; then
    info "  Local key fingerprint $SSH_KEY_FINGERPRINT not found on DO. Uploading..."
    do_key_id=$(doctl compute ssh-key import "agentos-$(hostname -s)" \
      --public-key-file "$SSH_PUBLIC_KEY" --format ID --no-header 2>/dev/null || true)
    if [ -z "$do_key_id" ]; then
      fail "Failed to import SSH key to DO. Try manually: doctl compute ssh-key import agentos-$(hostname -s) --public-key-file $SSH_PUBLIC_KEY"
    fi
    ok "  Uploaded as DO key id $do_key_id"
  else
    ok "  Local key already registered on DO (id $do_key_id)"
  fi

  local region size name ip
  printf "  Droplet name [%sclaude%s]: " "$c_blue" "$c_reset"; read -r name; name="${name:-claude}"
  printf "  Region [%sfra1%s]: " "$c_blue" "$c_reset"; read -r region; region="${region:-fra1}"
  printf "  Size [%ss-4vcpu-8gb%s] (~\$48/mo): " "$c_blue" "$c_reset"; read -r size; size="${size:-s-4vcpu-8gb}"

  info "  Creating droplet '$name' in $region ($size)…"
  ip=$(doctl compute droplet create "$name" \
        --image ubuntu-24-04-x64 \
        --size "$size" \
        --region "$region" \
        --ssh-keys "$do_key_id" \
        --wait \
        --format PublicIPv4 --no-header)
  if [ -z "$ip" ]; then
    fail "doctl did not return a public IP."
  fi
  ok "  droplet up: $ip"
  SSH_ALIAS="$name"
  ssh_config_add_alias "$SSH_ALIAS" "$ip" "root" "$SSH_PRIVATE_KEY"
  wait_until_ssh_ready "$SSH_ALIAS"
  deploy_state_save_host "$SSH_ALIAS" "$ip" "digitalocean" "$region" "$size"
}

provision_hetzner() {
  header "Provision Hetzner Cloud server"
  ensure_brew_cli hcloud hcloud "hcloud" || return 1
  if ! hcloud context list 2>/dev/null | grep -q .; then
    info "Create a Hetzner API token: https://console.hetzner.cloud → Project → Security → API Tokens"
    info "Then run: hcloud context create agentos"
    printf "  Press ENTER after creating context: "
    read -r _
  fi
  ok "hcloud ready"

  # Pick or upload SSH key
  detect_or_generate_ssh_key

  # Find or upload local pubkey on Hetzner (match by fingerprint)
  local ssh_key_name
  ssh_key_name=$(hcloud ssh-key list -o json 2>/dev/null \
    | jq -r --arg fp "$SSH_KEY_FINGERPRINT" '.[] | select(.fingerprint==($fp | sub("^SHA256:"; ""))) | .name' \
    | head -1 || true)

  if [ -z "$ssh_key_name" ]; then
    ssh_key_name="agentos-$(hostname -s)"
    info "  Local key fingerprint $SSH_KEY_FINGERPRINT not found on Hetzner. Uploading as '$ssh_key_name'..."
    hcloud ssh-key create --name "$ssh_key_name" --public-key-from-file "$SSH_PUBLIC_KEY" >/dev/null 2>&1 \
      || fail "Failed to upload SSH key to Hetzner. Try manually: hcloud ssh-key create --name $ssh_key_name --public-key-from-file $SSH_PUBLIC_KEY"
    ok "  Uploaded as '$ssh_key_name'"
  else
    ok "  Local key already registered on Hetzner (name '$ssh_key_name')"
  fi

  local region size name ip
  printf "  Server name [%sclaude%s]: " "$c_blue" "$c_reset"; read -r name; name="${name:-claude}"
  printf "  Location [%sfsn1%s]: " "$c_blue" "$c_reset"; read -r region; region="${region:-fsn1}"
  printf "  Type [%scax21%s] (~€7/mo, ARM): " "$c_blue" "$c_reset"; read -r size; size="${size:-cax21}"

  info "  Creating server '$name' in $region ($size)…"
  local out
  out=$(hcloud server create \
          --name "$name" \
          --image ubuntu-24.04 \
          --type "$size" \
          --location "$region" \
          --ssh-key "$ssh_key_name" \
          -o json)
  ip=$(echo "$out" | jq -r '.server.public_net.ipv4.ip')
  if [ -z "$ip" ] || [ "$ip" = "null" ]; then
    fail "hcloud did not return a public IP. Raw: $out"
  fi
  ok "  server up: $ip"
  SSH_ALIAS="$name"
  ssh_config_add_alias "$SSH_ALIAS" "$ip" "root" "$SSH_PRIVATE_KEY"
  wait_until_ssh_ready "$SSH_ALIAS"
  deploy_state_save_host "$SSH_ALIAS" "$ip" "hetzner" "$region" "$size"
}

provision_linode() {
  header "Provision Linode"
  ensure_brew_cli linode-cli linode-cli "linode-cli" || return 1
  if ! linode-cli account view >/dev/null 2>&1; then
    info "Configure linode-cli: linode-cli configure"
    info "Get token: https://cloud.linode.com/profile/tokens"
    printf "  Press ENTER after running 'linode-cli configure': "
    read -r _
  fi
  ok "linode-cli ready"

  # Pick or generate SSH key
  detect_or_generate_ssh_key

  local region size name pubkey ip
  printf "  Linode label [%sclaude%s]: " "$c_blue" "$c_reset"; read -r name; name="${name:-claude}"
  printf "  Region [%seu-central%s]: " "$c_blue" "$c_reset"; read -r region; region="${region:-eu-central}"
  printf "  Type [%sg6-standard-2%s] (~\$24/mo): " "$c_blue" "$c_reset"; read -r size; size="${size:-g6-standard-2}"

  pubkey=$(cat "$SSH_PUBLIC_KEY")
  info "  Creating Linode '$name' in $region ($size) with key $SSH_PUBLIC_KEY…"
  ip=$(linode-cli linodes create \
        --label "$name" \
        --image linode/ubuntu24.04 \
        --type "$size" \
        --region "$region" \
        --authorized_keys "$pubkey" \
        --json | jq -r '.[0].ipv4[0]')
  if [ -z "$ip" ] || [ "$ip" = "null" ]; then
    fail "linode-cli did not return a public IP."
  fi
  ok "  Linode up: $ip"
  SSH_ALIAS="$name"
  ssh_config_add_alias "$SSH_ALIAS" "$ip" "root" "$SSH_PRIVATE_KEY"
  wait_until_ssh_ready "$SSH_ALIAS"
  deploy_state_save_host "$SSH_ALIAS" "$ip" "linode" "$region" "$size"
}

exec_remote_setup_wizard() {
  # Sanity: jq is required for state file
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq not found on this Mac. Install with: brew install jq"
  fi
  deploy_state_init

  # Per-deploy log file
  mkdir -p "$DEPLOY_STATE_DIR"
  local DEPLOY_LOG="$DEPLOY_STATE_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"

  ###########################################################################
  # Cost transparency screen
  ###########################################################################
  section "AgentOS Remote Setup"
  info "Will provision a Linux VPS and install AgentOS template on it."
  info ""
  info "Cost overview:"
  info "  • VPS (recurring):       \$5–\$48/month (depending on provider + size)"
  info "    DigitalOcean s-4vcpu-8gb: \$48/mo (recommended)"
  info "    Hetzner CAX21:           ~\$8/mo (good budget option)"
  info "    Linode g6-standard-2:    \$24/mo"
  info "  • Telegram:              free"
  info "  • Claude Code:           free CLI; runtime requires Anthropic subscription/API"
  info "  • Whisper transcription: free (local, ~1.5 GB disk)"
  info ""
  printf "  Continue? [%sY%s/n]: " "$c_green" "$c_reset"
  local cont
  read -r cont
  [ "$(lower "$cont")" != "n" ] || exit 0

  ###########################################################################
  # Pre-flight checks
  ###########################################################################
  header "Pre-flight checks"

  # Mac dependencies
  local missing=()
  for cmd in ssh rsync git curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing on this Mac: ${missing[*]} — install with: brew install ${missing[*]}"
  fi
  ok "ssh / rsync / git / curl / jq present"

  # Internet — HEAD-only check (avoids -f failing on 401 from authenticated endpoints).
  if ! curl -sI --max-time 5 https://api.anthropic.com/ -o /dev/null 2>&1; then
    warn "Cannot reach api.anthropic.com — Claude Code won't auth on remote either."
  else
    ok "Internet connectivity"
  fi

  # claude CLI on Mac (needed for setup-token)
  if ! command -v claude &>/dev/null; then
    warn "Claude Code CLI not found on this Mac. You'll need it for 'claude setup-token'."
    info "Install: curl -fsSL https://claude.ai/install.sh | bash"
    printf "  Continue anyway? [y/%sN%s]: " "$c_yellow" "$c_reset"
    local ok_choice
    read -r ok_choice
    [ "$(lower "$ok_choice")" = "y" ] || exit 1
  else
    ok "Claude Code: $(claude --version 2>&1 | head -1)"
  fi

  # ~/.ssh/config writable
  if [[ ! -d ~/.ssh ]]; then
    log "Creating ~/.ssh directory..."
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
  fi
  touch ~/.ssh/config 2>/dev/null || { fail "Cannot write to ~/.ssh/config"; }
  chmod 600 ~/.ssh/config
  ok "~/.ssh/config writable"

  # SSH key — auto-detect (id_ed25519, id_rsa, id_ecdsa, id_dsa) or offer to generate.
  # Sets globals SSH_PRIVATE_KEY / SSH_PUBLIC_KEY / SSH_KEY_FINGERPRINT for use by provision_*.
  detect_or_generate_ssh_key

  # Show previous hosts (resume hint)
  local prev_aliases
  prev_aliases=$(deploy_state_known_aliases)
  if [ -n "$prev_aliases" ]; then
    info "Previously known hosts (from $DEPLOY_STATE):"
    echo "$prev_aliases" | sed 's/^/  - /'
  fi

  ###########################################################################
  # Step 1 — Target host
  ###########################################################################
  header "Step 1 of 6: Target host"
  echo "  1) Use existing SSH alias from ~/.ssh/config"
  echo "  2) Provision new DigitalOcean droplet (doctl)"
  echo "  3) Provision new Hetzner Cloud server (hcloud)"
  echo "  4) Provision new Linode (linode-cli)"
  printf "Choose [%sdefault: 1%s]: " "$c_blue" "$c_reset"
  local choice
  read -r choice
  choice="${choice:-1}"

  case "$choice" in
    1) prompt_existing_alias ;;
    2) provision_do_droplet ;;
    3) provision_hetzner ;;
    4) provision_linode ;;
    *) fail "Invalid choice" ;;
  esac

  if [ -z "${SSH_ALIAS:-}" ]; then
    fail "SSH_ALIAS not set after host selection."
  fi

  ###########################################################################
  # Step 2 — SSH connectivity
  ###########################################################################
  header "Step 2 of 6: SSH connectivity to '$SSH_ALIAS'"
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_ALIAS" true 2>/dev/null; then
    fail "SSH to $SSH_ALIAS failed. Check ~/.ssh/config and key access."
  fi
  ok "SSH to $SSH_ALIAS works."

  ###########################################################################
  # Step 3 — Configuration
  ###########################################################################
  header "Step 3 of 6: Configuration"
  PROJECT_NAME=$(ask "Project slug" "project_name" "myagentos")
  GIT_REMOTE=$(ask "Git remote (optional, blank to skip)" "git_remote" "")
  TIMEZONE=$(ask "Timezone (IANA)" "timezone" "Europe/Lisbon")
  WHISPER_MODEL=$(ask "Whisper model (tiny|base|medium)" "whisper_model" "medium")

  ###########################################################################
  # Step 4 — Telegram bot setup (BotFather hand-holding)
  ###########################################################################
  header "Step 4 of 6: Telegram bot setup"
  cat <<'EOF'
  ┌─────────────────────────────────────────────┐
  │ Create your Telegram bot via @BotFather:    │
  │                                              │
  │ 1. Open Telegram → search @BotFather        │
  │ 2. Send /newbot                             │
  │ 3. Pick a display name (e.g., "Vasily AI")  │
  │ 4. Pick a username — must end in _bot       │
  │ 5. Copy the API token (format: 123:ABC...)  │
  │ 6. Paste below                              │
  └─────────────────────────────────────────────┘
EOF

  while true; do
    TG_BOT_TOKEN=$(ask_secret "Bot token" "TG_BOT_TOKEN")
    if [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
      ok "Token format valid"
      break
    fi
    warn "Invalid format. Expected: 123456789:ABC...DEF (try again or Ctrl+C to abort)"
  done

  ###########################################################################
  # Step 4b — Multi-admin via /start polling
  ###########################################################################
  header "Step 4b: Bot admins (via /start)"
  info "Now have your admins send /start to your bot. We'll auto-detect their user IDs."
  info ""
  info "  • On Telegram, find your bot (the username you picked)"
  info "  • Send /start (or any message)"
  info "  • Add other admins now too — they should also send /start"
  info ""

  local TG_API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
  local TG_ADMIN_USER_IDS="" TG_ADMIN_USERNAMES="" admins=""

  while true; do
    printf "  Press ENTER when all admins have sent /start: "
    read -r _

    local raw
    raw=$(curl -fsS --max-time 10 "${TG_API}/getUpdates" 2>/dev/null || echo '{"result":[]}')
    admins=$(echo "$raw" | jq -r '.result[]?.message | select(.text=="/start") | "\(.from.id):\(.from.username // .from.first_name)"' 2>/dev/null | sort -u)

    if [[ -z "$admins" ]]; then
      warn "No /start messages found. Did you send to the right bot?"
      info "Bot token starts: ${TG_BOT_TOKEN:0:10}..."
      printf "  Retry / skip / abort? [%sR%s/s/a]: " "$c_green" "$c_reset"
      local choice2
      read -r choice2
      case "$(lower "$choice2")" in
        s) TG_ADMIN_USER_IDS=""; TG_ADMIN_USERNAMES=""; break ;;
        a) exit 0 ;;
        *) continue ;;
      esac
    else
      ok "Found admins:"
      echo "$admins" | while IFS=: read -r id user; do
        printf "    %s✓%s @%s (id %s)\n" "$c_green" "$c_reset" "$user" "$id"
      done
      TG_ADMIN_USER_IDS=$(echo "$admins" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
      TG_ADMIN_USERNAMES=$(echo "$admins" | cut -d: -f2 | tr '\n' ',' | sed 's/,$//')
      printf "  Save these as bot admins? [%sY%s/n]: " "$c_green" "$c_reset"
      local ok_choice
      read -r ok_choice
      [ "$(lower "$ok_choice")" != "n" ] || exit 0
      break
    fi
  done

  # legacy TG_USER_ID = first admin (for backward compat with hooks/.env writes)
  TG_USER_ID="${TG_ADMIN_USER_IDS%%,*}"
  state_set "tg_admin_user_ids" "$TG_ADMIN_USER_IDS"
  state_set "tg_admin_usernames" "$TG_ADMIN_USERNAMES"
  state_set "tg_user_id" "$TG_USER_ID"

  ###########################################################################
  # Step 4c — Claude Code OAuth (auto-launch setup-token)
  ###########################################################################
  header "Step 4c: Claude Code OAuth"

  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    ok "OAuth token from env (length ${#CLAUDE_CODE_OAUTH_TOKEN})"
  elif command -v claude &>/dev/null; then
    info "Need a 1-year OAuth token. We'll run 'claude setup-token' for you."
    info "(Browser will open. Paste resulting token below.)"
    printf "  Press ENTER to launch claude setup-token: "
    read -r _

    # Open in new Terminal window so user sees the URL even if main shell is busy
    if command -v osascript &>/dev/null; then
      osascript -e 'tell application "Terminal" to do script "claude setup-token"' 2>/dev/null \
        || claude setup-token
    else
      claude setup-token
    fi

    echo
    CLAUDE_CODE_OAUTH_TOKEN=$(ask_secret "Paste OAuth token (sk-ant-oat01-...)" "CLAUDE_CODE_OAUTH_TOKEN")
  else
    info "Get token: on a Mac with Claude Code installed, run 'claude setup-token'"
    CLAUDE_CODE_OAUTH_TOKEN=$(ask_secret "Paste OAuth token (sk-ant-oat01-...)" "CLAUDE_CODE_OAUTH_TOKEN")
  fi

  # Validate format
  if ! [[ "$CLAUDE_CODE_OAUTH_TOKEN" =~ ^sk-ant-oat[0-9]+-[A-Za-z0-9_-]+$ ]]; then
    warn "Token format unexpected (expected sk-ant-oat01-...). Continuing anyway."
  fi

  ###########################################################################
  # Step 5 — Remote install (git clone, not rsync)
  ###########################################################################
  header "Step 5 of 6: Remote install"
  info "Cloning template on $SSH_ALIAS..."

  ssh "$SSH_ALIAS" "rm -rf /tmp/agentos && git clone --depth 1 https://github.com/try-agent-os/claude-code-template /tmp/agentos" 2>&1 | tee -a "$DEPLOY_LOG"
  ok "Repo cloned remotely"

  info "Running install.sh non-interactively (this will take 5-15 min)..."
  info "Live output below — also tee'd to $DEPLOY_STATE_DIR/$SSH_ALIAS.log"

  # Pass all wizard answers as env vars; install.sh resumes from state.json on remote
  ssh "$SSH_ALIAS" "cd /tmp/agentos && \
      PROJECT_NAME='$PROJECT_NAME' \
      GIT_REMOTE='$GIT_REMOTE' \
      TIMEZONE='$TIMEZONE' \
      WHISPER_MODEL='$WHISPER_MODEL' \
      TELEGRAM_BOT_TOKEN='$TG_BOT_TOKEN' \
      TG_USER_ID='$TG_USER_ID' \
      TG_ADMIN_USER_IDS='$TG_ADMIN_USER_IDS' \
      TG_ADMIN_USERNAMES='$TG_ADMIN_USERNAMES' \
      CLAUDE_CODE_OAUTH_TOKEN='$CLAUDE_CODE_OAUTH_TOKEN' \
      sudo -E bash install.sh --non-interactive" 2>&1 | tee "$DEPLOY_STATE_DIR/$SSH_ALIAS.log"
  local install_exit=${PIPESTATUS[0]}

  if [[ $install_exit -ne 0 ]]; then
    fail "Remote install exited $install_exit — check log: $DEPLOY_STATE_DIR/$SSH_ALIAS.log (resume: bash install.sh)"
  fi
  ok "Remote install completed"

  ###########################################################################
  # Step 6 — Self-test via Telegram + operator peer registration
  ###########################################################################
  header "Step 6 of 6: Self-test"
  info "Sending test message to your bot..."

  local first_admin="${TG_ADMIN_USER_IDS%%,*}"
  if [[ -n "$first_admin" ]]; then
    if curl -fsS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=$first_admin" \
        -d "text=AgentOS deployed to $SSH_ALIAS ($(date +%H:%M)). If you see this, the bot works." \
        >/dev/null 2>&1; then
      ok "Test message sent — check your Telegram"
    else
      warn "Test message failed (operator may still come up)"
    fi
  fi

  # Wait up to 60s for operator to register as peer
  info "Waiting up to 60s for operator to register..."
  local i
  for i in $(seq 1 30); do
    if ssh "$SSH_ALIAS" "curl -sf http://127.0.0.1:7899/list-peers -H 'Content-Type: application/json' -d '{\"scope\":\"machine\",\"cwd\":\"/\",\"git_root\":null}' 2>/dev/null | jq -e '.[] | select(.cwd | contains(\"operator\"))' >/dev/null" 2>/dev/null; then
      ok "Operator registered as peer (took ${i}s × 2)"
      break
    fi
    sleep 2
    printf "."
  done
  echo

  # Optional verify.sh probe (existed in old wizard — keep for parity)
  if ssh "$SSH_ALIAS" "test -x /opt/agent-os/claude/scripts/verify.sh" 2>/dev/null; then
    info "Running verify.sh on remote..."
    ssh "$SSH_ALIAS" "sudo bash /opt/agent-os/claude/scripts/verify.sh" 2>&1 | tail -20 \
      || warn "verify.sh reported issues — full output: ssh $SSH_ALIAS 'sudo bash /opt/agent-os/claude/scripts/verify.sh'"
  fi

  ###########################################################################
  # Final summary
  ###########################################################################
  section "✓ AgentOS deployed"
  printf "  Server:     %s%s%s\n" "$c_green" "$SSH_ALIAS" "$c_reset"
  printf "  Operator:   listening on Telegram\n"
  printf "  Admins:     %s\n" "${TG_ADMIN_USERNAMES:-<none>}"
  printf "\n"
  printf "  Try it:\n"
  printf "    1. Send any message to your bot on Telegram\n"
  printf "    2. Or attach: %sssh %s -t 'sudo -u agent-os tmux attach -t operator'%s\n" "$c_bold" "$SSH_ALIAS" "$c_reset"
  printf "    3. Check status: %sssh %s 'sudo bash /opt/agent-os/claude/scripts/verify.sh'%s\n" "$c_bold" "$SSH_ALIAS" "$c_reset"
  printf "\n"
  printf "  Re-run anytime: %sbash install.sh%s (resumes from state)\n" "$c_bold" "$c_reset"
  printf "  State: %s\n" "$DEPLOY_STATE"
  printf "  Deploy log: %s\n" "$DEPLOY_LOG"
}

# detect_mode dispatches BEFORE any Linux-specific check (os-release, apt, etc.).
# On macOS this calls exec_remote_setup_wizard and exits; the local-install
# logic below is unreachable on Mac. Keep this dispatch the FIRST thing after
# arg parsing — any Linux-only code added above will break the Mac branch.

# Guard: on macOS the wizard runs as the user (touches ~/.ssh/config, runs
# `claude setup-token` in the user's browser session, sudoes only on the
# remote VPS via ssh). Running with sudo would resolve `~/.ssh/config` to
# `/root/.ssh/config` and break the auth flow. Bail out with a clear hint.
if [ "$(uname)" = "Darwin" ] && [ "$(id -u)" -eq 0 ]; then
  printf '%s✗%s Do not run install.sh with sudo on macOS.\n' "$c_red" "$c_reset" >&2
  printf '\n' >&2
  printf '  The Mac wizard runs as your user — it manages ~/.ssh/config,\n' >&2
  printf '  drives `claude setup-token` in your browser, and sudoes only on\n' >&2
  printf '  the remote Linux VPS over ssh.\n' >&2
  printf '\n' >&2
  printf '  Re-run without sudo:\n' >&2
  printf '    %scurl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | bash%s\n' "$c_bold" "$c_reset" >&2
  printf '\n' >&2
  printf '  (sudo is only used when running install.sh on the Linux VPS itself.)\n' >&2
  exit 1
fi

# Fallback /dev/tty redirect — only reached if the bootstrap re-exec at the
# top of the script could not run (curl missing, network down, mktemp failed,
# or no terminal at all). If we're piped AND have a terminal, redirect.
# If we're piped AND have NO terminal, fail loudly rather than silently
# consuming script bytes as user input — unless --non-interactive was set.
if [ ! -t 0 ]; then
  if [ -t 1 ] || [ -t 2 ]; then
    if ! exec </dev/tty 2>/dev/null; then
      warn "Could not open /dev/tty for interactive prompts."
      [[ "${NON_INTERACTIVE:-0}" == "1" ]] || \
        fail "stdin is a pipe and /dev/tty is unavailable. Either use --non-interactive with all wizard env vars preset, or run the installer from a real terminal."
    fi
  elif [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
    fail "Non-interactive environment detected (no terminal on stdin/stdout/stderr). Re-run with --non-interactive and preset all wizard env vars (PROJECT_NAME, PROJECT_SLUG, TG_BOT_TOKEN, TG_USER_ID, TIMEZONE, CLAUDE_CODE_OAUTH_TOKEN)."
  fi
fi

MODE=$(detect_mode)
if [ "$MODE" = "remote-setup" ]; then
  exec_remote_setup_wizard "$@"
  exit 0
fi
if [ "$MODE" != "local-install" ]; then
  fail "Unknown mode '$MODE' from detect_mode (expected: remote-setup or local-install)."
fi
# Below this line: Linux-only territory. Mac never reaches it.

###############################################################################
# Step 1 — sanity (root, OS, arch) — Linux-only branch
###############################################################################
step "1/18 sanity checks"

[[ $EUID -eq 0 ]] || fail "Run as root (use sudo)."

# /etc/os-release is Linux-specific; this check is gated by MODE=local-install
# above so it never executes on macOS.
if [[ ! -r /etc/os-release ]]; then
  fail "/etc/os-release missing — cannot detect OS."
fi
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) fail "Unsupported OS: ${ID:-unknown}. Need Ubuntu 22.04+ or Debian 12+." ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) log "OS=${ID} ${VERSION_ID:-?}, arch=${ARCH}" ;;
  *) fail "Unsupported arch: ${ARCH}. AgentOS supports amd64 and arm64." ;;
esac
mark_step_completed 1

###############################################################################
# Step 2 — wizard (state-file-backed, resumable)
###############################################################################
step "2/18 wizard"

# Ensure state dir exists for state file (root:agent-os comes later, but root for now)
mkdir -p "$ETC_DIR"

# Re-use existing env file if already configured (sources secrets back into env).
# CRITICAL: dot-source would override env vars passed via SSH/cmdline (e.g. the
# Mac wizard re-running with NEW tokens). Save originals first, source the
# file, then restore originals — file values only fill in MISSING vars.
if [[ -f "$ENV_FILE" ]]; then
  log "  ${ENV_FILE} exists — sourcing existing secrets (incoming env vars take precedence)"
  __ORIG_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  __ORIG_TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
  __ORIG_CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  __ORIG_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
  __ORIG_OPENAI_API_KEY="${OPENAI_API_KEY:-}"
  __ORIG_TG_USER_ID="${TG_USER_ID:-}"
  __ORIG_TG_ADMIN_USER_IDS="${TG_ADMIN_USER_IDS:-}"
  __ORIG_TG_ADMIN_USERNAMES="${TG_ADMIN_USERNAMES:-}"
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
  # Restore non-empty originals (incoming wins; if not provided, file value stands)
  TELEGRAM_BOT_TOKEN="${__ORIG_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
  TG_BOT_TOKEN="${__ORIG_TG_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
  CLAUDE_CODE_OAUTH_TOKEN="${__ORIG_CLAUDE_CODE_OAUTH_TOKEN:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"
  ANTHROPIC_API_KEY="${__ORIG_ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY:-}}"
  OPENAI_API_KEY="${__ORIG_OPENAI_API_KEY:-${OPENAI_API_KEY:-}}"
  TG_USER_ID="${__ORIG_TG_USER_ID:-${TG_USER_ID:-}}"
  TG_ADMIN_USER_IDS="${__ORIG_TG_ADMIN_USER_IDS:-${TG_ADMIN_USER_IDS:-}}"
  TG_ADMIN_USERNAMES="${__ORIG_TG_ADMIN_USERNAMES:-${TG_ADMIN_USERNAMES:-}}"
  unset __ORIG_TELEGRAM_BOT_TOKEN __ORIG_TG_BOT_TOKEN __ORIG_CLAUDE_CODE_OAUTH_TOKEN \
        __ORIG_ANTHROPIC_API_KEY __ORIG_OPENAI_API_KEY __ORIG_TG_USER_ID \
        __ORIG_TG_ADMIN_USER_IDS __ORIG_TG_ADMIN_USERNAMES
fi

if step_done 2 && [[ "$FORCE_REINSTALL" != 1 ]] && [[ "$RESET" != 1 ]]; then
  log "  step 2 already completed — loading from state, skipping prompts"
  PROJECT_NAME=$(state_get "project_name" "agentos")
  TIMEZONE=$(state_get "timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || echo 'UTC')")
  TG_USER_ID=$(state_get "tg_user_id" "")
  TG_ADMIN_USER_IDS=$(state_get "tg_admin_user_ids" "")
  TG_ADMIN_USERNAMES=$(state_get "tg_admin_usernames" "")
  GIT_REMOTE=$(state_get "git_remote" "")
  WHISPER_MODEL=$(state_get "whisper_model" "$WHISPER_MODEL")
  # Secrets stay in env (already sourced from $ENV_FILE above)
  TG_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
else
  prompt_resume

  if [[ "$NON_INTERACTIVE" == 1 ]]; then
    # Non-interactive: read from env vars or state, no prompts
    PROJECT_NAME="${PROJECT_NAME:-$(state_get project_name agentos)}"
    TIMEZONE="${TIMEZONE:-$(state_get timezone "$(timedatectl show -p Timezone --value 2>/dev/null || echo 'UTC')")}"
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
    # Multi-admin: prefer env vars from Mac wrapper (Step 4b), fall back to single TG_USER_ID for legacy
    TG_ADMIN_USER_IDS="${TG_ADMIN_USER_IDS:-$(state_get tg_admin_user_ids "")}"
    TG_ADMIN_USERNAMES="${TG_ADMIN_USERNAMES:-$(state_get tg_admin_usernames "")}"
    TG_USER_ID="${TG_USER_ID:-$(state_get tg_user_id "")}"
    if [[ -z "$TG_USER_ID" && -n "$TG_ADMIN_USER_IDS" ]]; then
      TG_USER_ID="${TG_ADMIN_USER_IDS%%,*}"  # legacy single-admin = first admin
    fi
    if [[ -z "$TG_ADMIN_USER_IDS" && -n "$TG_USER_ID" ]]; then
      TG_ADMIN_USER_IDS="$TG_USER_ID"  # legacy single-admin → seed allowlist
    fi
    GIT_REMOTE="${GIT_REMOTE:-$(state_get git_remote "")}"
    WHISPER_MODEL="${WHISPER_MODEL:-$(state_get whisper_model medium)}"
    # Persist non-secret answers to state
    state_set project_name "$PROJECT_NAME"
    state_set timezone "$TIMEZONE"
    state_set tg_user_id "$TG_USER_ID"
    state_set tg_admin_user_ids "$TG_ADMIN_USER_IDS"
    state_set tg_admin_usernames "$TG_ADMIN_USERNAMES"
    state_set git_remote "$GIT_REMOTE"
    state_set whisper_model "$WHISPER_MODEL"
  else
    header "Project identity"
    PROJECT_NAME=$(ask "Project slug (alphanumeric+dash)" "project_name" "agentos")

    if [[ "${MINIMAL}" == 1 ]]; then
      log "  --minimal: skipping Telegram bot wizard prompts"
      TG_BOT_TOKEN=""
      TG_USER_ID=""
      TG_ADMIN_USER_IDS=""
      TG_ADMIN_USERNAMES=""
    else
      header "Telegram bot"
      info "Open @BotFather, /newbot, paste token below."
      TG_BOT_TOKEN=$(ask_secret "Bot token" "TELEGRAM_BOT_TOKEN")

      # Multi-admin: prefer env vars from Mac wrapper (Step 4b), else single prompt
      if [[ -n "${TG_ADMIN_USER_IDS:-}" ]]; then
        TG_USER_ID="${TG_ADMIN_USER_IDS%%,*}"  # legacy single-admin = first admin
        info "  Admins from Mac wrapper: ${TG_ADMIN_USERNAMES:-<no usernames>} (${TG_ADMIN_USER_IDS})"
        state_set "tg_admin_user_ids" "$TG_ADMIN_USER_IDS"
        state_set "tg_admin_usernames" "${TG_ADMIN_USERNAMES:-}"
      else
        TG_USER_ID=$(ask "Your Telegram user ID (numeric, get from @userinfobot)" "tg_user_id" "")
        TG_ADMIN_USER_IDS="$TG_USER_ID"
        TG_ADMIN_USERNAMES=""
        state_set "tg_admin_user_ids" "$TG_ADMIN_USER_IDS"
        state_set "tg_admin_usernames" ""
      fi
    fi

    header "Git remote (optional)"
    info "Skip with empty value if you'll set up later."
    GIT_REMOTE=$(ask "git@github.com:user/repo.git" "git_remote" "")

    header "Timezone"
    TIMEZONE=$(ask "Timezone (IANA, e.g. Europe/Lisbon)" "timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || echo 'Europe/Lisbon')")
    if ! timedatectl list-timezones 2>/dev/null | grep -qF "$TIMEZONE"; then
      warn "Timezone '$TIMEZONE' not in system list. Continuing anyway."
    fi

    if [[ "${MINIMAL}" == 1 ]]; then
      log "  --minimal: skipping Whisper model prompt (no telegram = no voice transcription)"
    else
      header "Whisper model"
      info "tiny=75MB (fast, low quality), base=150MB (balanced), medium=1.5GB (default, full quality)"
      WHISPER_MODEL=$(ask "Whisper model size" "whisper_model" "medium")
    fi

    header "Claude Code OAuth"
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
      info "CLAUDE_CODE_OAUTH_TOKEN already in env — using it."
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
      info "ANTHROPIC_API_KEY in env — falling back (Console-billed mode)."
    else
      info "On your local Mac, run: claude setup-token"
      info "Paste the resulting 1-year token (sk-ant-oat01-...) below."
      CLAUDE_CODE_OAUTH_TOKEN=$(ask_secret "OAuth token" "CLAUDE_CODE_OAUTH_TOKEN")
      if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        fail "Authentication required. Re-run after obtaining a token."
      fi
      # Sniff token type — if it starts with sk-ant-api, it's actually an API key
      if [[ "${CLAUDE_CODE_OAUTH_TOKEN}" == sk-ant-api* ]]; then
        ANTHROPIC_API_KEY="${CLAUDE_CODE_OAUTH_TOKEN}"
        unset CLAUDE_CODE_OAUTH_TOKEN
        export ANTHROPIC_API_KEY
        info "Detected API key (not OAuth) — switching var."
      fi
    fi
  fi

  # Persist state flags too
  state_set harden "${HARDEN}" number
  state_set minimal "${MINIMAL}" number

  # Confirmation summary
  section "Summary"
  printf "  Project:     %s\n" "$PROJECT_NAME"
  if [[ -n "${TG_BOT_TOKEN:-}" ]]; then
    printf "  Telegram:    user %s, bot token %s...%s\n" "$TG_USER_ID" "${TG_BOT_TOKEN:0:6}" "${TG_BOT_TOKEN: -4}"
    if [[ -n "${TG_ADMIN_USER_IDS:-}" && "${TG_ADMIN_USER_IDS}" != "${TG_USER_ID}" ]]; then
      printf "  Admins:      %s (%s)\n" "${TG_ADMIN_USERNAMES:-<no names>}" "${TG_ADMIN_USER_IDS}"
    fi
  else
    printf "  Telegram:    %s\n" "<skip>"
  fi
  printf "  Git remote:  %s\n" "${GIT_REMOTE:-<skip>}"
  printf "  Timezone:    %s\n" "$TIMEZONE"
  printf "  Whisper:     %s\n" "$WHISPER_MODEL"
  printf "  Harden mode: %s\n" "$([ "${HARDEN:-0}" = "1" ] && echo "yes" || echo "no")"
  printf "  Minimal:     %s\n" "$([ "${MINIMAL:-0}" = "1" ] && echo "yes (no telegram/operator)" || echo "no")"

  if [ -t 0 ] && [[ "$NON_INTERACTIVE" != 1 ]]; then
    printf "\nProceed with install? [%sY%s/n]: " "$c_green" "$c_reset"
    read -r ok_choice
    if [ "$(lower "$ok_choice")" = "n" ] || [ "$(lower "$ok_choice")" = "no" ]; then
      warn "Aborted by user."
      exit 0
    fi
  fi
fi

# Export wizard outputs for downstream steps
export PROJECT_NAME TIMEZONE TG_BOT_TOKEN TG_USER_ID TG_ADMIN_USER_IDS TG_ADMIN_USERNAMES GIT_REMOTE WHISPER_MODEL
mark_step_completed 2

###############################################################################
# Step 3 — APT prereqs (incl. bubblewrap + socat for sandbox)
###############################################################################
step "3/18 apt prereqs"

export DEBIAN_FRONTEND=noninteractive

# Self-heal: prior install runs (or partial provisions) may have left broken
# apt sources behind — most commonly the legacy Anthropic apt repo at
# downloads.claude.ai/claude-code/apt that is now decommissioned (we now
# install Claude Code via the bootstrap script in Step 5, see commit history).
# Step 5 removes those artifacts itself, but Step 3 runs first, so a re-run
# on a half-installed VPS would die here on `apt-get update` before reaching
# the cleanup. Detect and self-heal: try update, parse failures, disable
# the offending source files, retry once.
_apt_log=$(mktemp)
apt-get update -o Acquire::Retries=2 >"$_apt_log" 2>&1 || true
if grep -qE 'does not have a Release file|Failed to fetch|Could not resolve' "$_apt_log"; then
  warn "Detected broken apt source(s); attempting self-heal."
  _broken_urls=$(grep -oE 'https?://[^[:space:]]+' "$_apt_log" | sort -u)
  for _url in $_broken_urls; do
    _base=${_url%/dists/*}
    _base=${_base%/}
    _matches=$(grep -lr -F "$_base" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
    for _f in $_matches; do
      mv "$_f" "${_f}.disabled-$(date +%s)" 2>/dev/null && \
        ok "Disabled broken apt source: $_f (was pointing at $_base)"
    done
  done
  apt-get update -qq || fail "apt-get update still failing after disabling broken sources. See $_apt_log for full output."
fi
rm -f "$_apt_log"

apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg git tmux jq sqlite3 \
  build-essential cmake ffmpeg \
  python3 python3-pip \
  ufw \
  bubblewrap socat \
  unzip

# yt-dlp via pip (apt version often lags). Ubuntu 23.04+ requires --break-system-packages.
if ! command -v yt-dlp >/dev/null 2>&1; then
  pip3 install --quiet --break-system-packages -U yt-dlp \
    || apt-get install -y yt-dlp \
    || fail "Could not install yt-dlp via pip or apt."
fi
mark_step_completed 3

###############################################################################
# Step 4 — Node 20 LTS via NodeSource
###############################################################################
step "4/18 node 20 lts"

need_node=1
if command -v node >/dev/null 2>&1; then
  current=$(node -v 2>/dev/null || echo v0)
  if [[ "$current" == v20.* ]]; then
    log "  node $current already present"
    need_node=0
  fi
fi
if [[ "$need_node" == 1 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh
  bash /tmp/nodesource_setup.sh
  apt-get install -y nodejs
  rm -f /tmp/nodesource_setup.sh
fi
mark_step_completed 4

###############################################################################
# Step 5 — Claude Code from signed apt repo (canonical, per code.claude.com/docs)
#
# History note: an earlier URL (downloads.claude.ai/claude-code/apt without the
# `/stable` channel suffix) was 404. The correct, currently-published path is
# `…/apt/stable stable main` with the GPG key under `/keys/claude-code.asc`.
# Bootstrap installer (https://claude.ai/install.sh) was tried as a workaround
# but it lands the binary in /root/.local/bin which is unreadable to the
# agent-os system user (mode 0700 on /root). apt installs to /usr/bin/claude,
# system-wide readable, plus gives proper `apt-get upgrade claude-code`.
###############################################################################
step "5/18 claude-code (signed apt repo)"

KEYRING="/etc/apt/keyrings/claude-code.asc"
SOURCES_LIST="/etc/apt/sources.list.d/claude-code.list"

install -d -m 0755 /etc/apt/keyrings

if [[ ! -f "$KEYRING" ]]; then
  curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$KEYRING"
  # Verify fingerprint against the value pinned at code.claude.com/docs/en/setup
  actual_fpr=$(gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
  if [[ "$actual_fpr" != "$ANTHROPIC_KEY_FPR" ]]; then
    rm -f "$KEYRING"
    fail "Anthropic GPG key fingerprint mismatch: got $actual_fpr, expected $ANTHROPIC_KEY_FPR"
  fi
  log "  GPG key fingerprint verified: $actual_fpr"
fi

if [[ ! -f "$SOURCES_LIST" ]]; then
  echo "deb [signed-by=${KEYRING}] https://downloads.claude.ai/claude-code/apt/stable stable main" \
    > "$SOURCES_LIST"
fi

# Clean up any orphaned bootstrap install from a prior install.sh run on this host
if [[ -L /usr/local/bin/claude ]] && [[ "$(readlink /usr/local/bin/claude)" == /root/.local/bin/claude ]]; then
  rm -f /usr/local/bin/claude
fi
rm -rf /root/.local/share/claude /root/.local/bin/claude 2>/dev/null || true

apt-get update -qq
apt-get install -y claude-code

if ! command -v claude >/dev/null 2>&1; then
  fail "claude-code installed but 'claude' not on PATH — investigate apt postinst."
fi
log "  claude --version: $(claude --version 2>&1 | head -1)"
mark_step_completed 5

###############################################################################
# Step 6 — user + dirs
###############################################################################
step "6/18 user + dirs"

if ! id "$AGENT_USER" >/dev/null 2>&1; then
  # System user, no login password, /bin/bash so `sudo -u agent-os tmux attach` works
  useradd --system --create-home --home-dir "$AGENT_HOME" --shell /bin/bash "$AGENT_USER"
  log "  created user ${AGENT_USER}"
else
  log "  user ${AGENT_USER} exists"
fi

# Standard dirs
# NOTE: telegram-mcp's messages.db used to live in a dedicated cwd dir
# (${STATE_DIR}/telegram-mcp). With the plugin model Claude Code spawns the
# subprocess with cwd = plugin dir, so the DB ends up alongside plugin code.
# Open question (flagged in commit message): should we patch the vendored
# telegram-mcp source to honour ${CLAUDE_PLUGIN_DATA} for its DB path so the
# DB lives under STATE_DIR? For now we let the plugin write into its own
# install dir and rely on systemd ReadWritePaths to allow it.
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$INSTALL_ROOT" "$LOG_DIR" "$STATE_DIR"
install -d -o root         -g "$AGENT_USER" -m 0750 "$ETC_DIR" "$CLAUDE_MANAGED_DIR"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$CLAUDE_CONFIG_BASE"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$CC_DIR_OPERATOR" "$CC_DIR_DISPATCHER" "$CC_DIR_HEARTBEAT"

# ${AGENT_HOME}/.config must exist before operator.service starts: the unit
# lists it in ReadWritePaths and systemd's mount namespacing fails with
# 226/NAMESPACE if the path is missing. Claude Code also writes here when
# CLAUDE_CONFIG_DIR isn't honoured by every codepath (bun cache, etc.).
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "${AGENT_HOME}/.config"

# Now that ETC_DIR is owned root:agent-os, fix state file ownership if it pre-existed
if [ -f "$STATE_FILE" ]; then
  chown root:"$AGENT_USER" "$STATE_FILE" 2>/dev/null || true
  chmod 0640 "$STATE_FILE" 2>/dev/null || true
fi
mark_step_completed 6

###############################################################################
# Step 7 — bun (as agent-os user)
###############################################################################
step "7/18 bun"

if [[ ! -x "${AGENT_HOME}/.bun/bin/bun" ]]; then
  sudo -u "$AGENT_USER" bash -c 'curl -fsSL https://bun.sh/install | bash'
else
  log "  bun already installed at ${AGENT_HOME}/.bun/bin/bun"
fi
BUN_PATH="${AGENT_HOME}/.bun/bin/bun"
mark_step_completed 7

###############################################################################
# Step 8 — clone repos
###############################################################################
step "8/18 clone repos"

clone_or_pull() {
  local url=$1 dest=$2
  if [[ -d "${dest}/.git" ]]; then
    sudo -u "$AGENT_USER" git -C "$dest" fetch --depth 1 origin
    sudo -u "$AGENT_USER" git -C "$dest" reset --hard origin/HEAD
    log "  pulled ${dest}"
  else
    sudo -u "$AGENT_USER" git clone --depth 1 "$url" "$dest"
    log "  cloned ${url} -> ${dest}"
  fi
}

clone_or_pull "$TEMPLATE_REPO" "${INSTALL_ROOT}/claude"
clone_or_pull "$SAGA_MCP_REPO" "${INSTALL_ROOT}/saga-mcp"

# claude-peers and telegram are vendored as plugins inside the template repo
# (plugins/claude-peers, plugins/telegram). No separate clone needed — they
# come along with TEMPLATE_REPO.

# After cloning the template into INSTALL_ROOT, prefer those template files over
# whatever directory the script was invoked from (handles curl|bash case).
if [[ -d "${INSTALL_ROOT}/claude/systemd" ]]; then
  TEMPLATE_DIR="${INSTALL_ROOT}/claude"
  log "  template dir resolved to ${TEMPLATE_DIR}"
fi
mark_step_completed 8

###############################################################################
# Step 9 — build vendored plugin MCP runtimes + saga-mcp
###############################################################################
step "9/18 build plugin MCPs + saga-mcp"

if [[ "$SKIP_BUILD" == 1 ]]; then
  log "  --skip-build: assuming dist/ artefacts already present"
else
  # claude-peers plugin (bun, no build step — server.ts auto-bootstraps broker)
  if [[ -d "${INSTALL_ROOT}/claude/plugins/claude-peers" ]]; then
    log "Installing claude-peers plugin Bun deps..."
    sudo -u "$AGENT_USER" bash -c "cd ${INSTALL_ROOT}/claude/plugins/claude-peers && ${BUN_PATH} install"
  fi

  # telegram plugin (node + whisper.cpp build + model download).
  # --minimal skips telegram entirely (no operator → no Telegram interface).
  if [[ "${MINIMAL}" == 1 ]]; then
    log "  --minimal: skipping telegram plugin install + whisper.cpp build"
  elif [[ -d "${INSTALL_ROOT}/claude/plugins/telegram" ]]; then
    log "Installing telegram plugin npm deps + building whisper..."
    sudo -u "$AGENT_USER" bash -c "cd ${INSTALL_ROOT}/claude/plugins/telegram && /usr/bin/npm ci && /usr/bin/npm run build"

    sudo -u "$AGENT_USER" bash <<EOF
set -euo pipefail
cd "${INSTALL_ROOT}/claude/plugins/telegram"
WMODELS=node_modules/nodejs-whisper/cpp/whisper.cpp/models
WBUILD=node_modules/nodejs-whisper/cpp/whisper.cpp/build
if [[ -d \$WMODELS ]]; then
  if [[ ! -f "\$WMODELS/ggml-${WHISPER_MODEL}.bin" ]]; then
    ( cd "\$WMODELS" && bash download-ggml-model.sh "${WHISPER_MODEL}" )
  fi
  if [[ ! -x "\$WBUILD/bin/whisper-cli" ]]; then
    ( cd node_modules/nodejs-whisper/cpp/whisper.cpp \
        && cmake -B build && cmake --build build -j --config Release )
  fi
fi
EOF
  fi

  # saga-mcp (node + tsc) — separate broker, not a plugin
  sudo -u "$AGENT_USER" bash <<EOF
set -euo pipefail
cd "${INSTALL_ROOT}/saga-mcp"
if [[ ! -d node_modules ]] || [[ package.json -nt node_modules/.package-lock.json ]]; then
  npm ci --no-audit --no-fund
fi
[[ -f dist/index.js ]] || npm run build
EOF
fi
mark_step_completed 9

###############################################################################
# Step 10 — render systemd unit templates
###############################################################################
step "10/18 render systemd units"

if [[ ! -d "${TEMPLATE_DIR}/systemd" ]]; then
  fail "systemd templates not found in ${TEMPLATE_DIR}/systemd"
fi

render_unit() {
  local src=$1 dest=$2
  sed \
    -e "s|{INSTALL_ROOT}|${INSTALL_ROOT}|g" \
    -e "s|{STATE_DIR}|${STATE_DIR}|g" \
    -e "s|{LOG_DIR}|${LOG_DIR}|g" \
    -e "s|{AGENT_USER}|${AGENT_USER}|g" \
    -e "s|{AGENT_HOME}|${AGENT_HOME}|g" \
    -e "s|{ENV_FILE}|${ENV_FILE}|g" \
    -e "s|{BUN_PATH}|${BUN_PATH}|g" \
    -e "s|{DISPATCHER_INTERVAL_SEC}|${DISPATCHER_INTERVAL_SEC}|g" \
    -e "s|{CLAUDE_CONFIG_DIR_OPERATOR}|${CC_DIR_OPERATOR}|g" \
    -e "s|{CLAUDE_CONFIG_DIR_DISPATCHER}|${CC_DIR_DISPATCHER}|g" \
    -e "s|{CLAUDE_CONFIG_DIR_HEARTBEAT}|${CC_DIR_HEARTBEAT}|g" \
    "$src" > "$dest"
  chmod 0644 "$dest"
}

for unit in agent-os-saga.service \
            agent-os-dispatcher.service \
            agent-os-dispatcher.timer \
            agent-os-operator.service ; do
  src="${TEMPLATE_DIR}/systemd/${unit}"
  if [[ ! -f "$src" ]]; then
    warn "  template missing: $src — skipping"
    continue
  fi
  if [[ "${MINIMAL}" == 1 ]] && [[ "$unit" == "agent-os-operator.service" ]]; then
    log "  --minimal: skipping $unit"
    continue
  fi
  render_unit "$src" "/etc/systemd/system/${unit}"
  log "  rendered ${unit}"
done
mark_step_completed 10

###############################################################################
# Step 11 — write /etc/agent-os/agent-os.env
###############################################################################
step "11/18 env file"

# Preserve existing values when re-running
mkdir -p "$ETC_DIR"
umask 077
{
  echo "# AgentOS environment — managed by install.sh"
  echo "# Mode 0640, owner root:agent-os. Do not commit."
  echo
  echo "# --- Authentication (ONE of: OAUTH_TOKEN or ANTHROPIC_API_KEY) ---"
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}"
  fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
  fi
  echo
  echo "# --- Telegram ---"
  echo "TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN:-}"
  # Multi-admin allowlist — comma-separated user IDs (auto-detected via /start polling
  # in the Mac wizard, Step 4b). The telegram plugin seeds these as 'allowed' in its
  # SQLite users table on startup. TELEGRAM_USER_ID is kept for legacy compat (= first ID).
  echo "TELEGRAM_ADMIN_USER_IDS=${TG_ADMIN_USER_IDS:-}"
  echo "TELEGRAM_ADMIN_USERNAMES=${TG_ADMIN_USERNAMES:-}"
  echo "TELEGRAM_USER_ID=${TG_USER_ID:-}"
  echo
  echo "# --- AgentOS state paths ---"
  echo "DB_PATH=${STATE_DIR}/saga.db"
  echo "CLAUDE_PEERS_DB=${STATE_DIR}/claude-peers.db"
  # NOTE: telegram plugin's messages.db lives inside the plugin install dir
  # (resolved by Claude Code via plugin discovery). No env path needed.
  echo
  echo "# --- Optional ---"
  echo "OPENAI_API_KEY=${OPENAI_API_KEY:-}"
  echo "TZ=${TIMEZONE}"
  echo "PROJECT_NAME=${PROJECT_NAME}"
  echo
  echo "# --- Behaviour ---"
  echo "DISABLE_AUTOUPDATER=1"
  echo "MCP_CONNECTION_NONBLOCKING=true"
  echo
  echo "# --- T11 lifecycle hooks (.claude/hooks/*) ---"
  echo "# OPERATOR_PEER_ID is empty by default — set it after the operator boots"
  echo "# and registers itself with claude-peers (see /var/log/agent-os/operator.log)."
  echo "OPERATOR_PEER_ID=${OPERATOR_PEER_ID:-}"
  echo "CLAUDE_PEERS_API_URL=http://127.0.0.1:7899/send-message"
  echo "CLAUDE_PEERS_HEALTH_URL=http://127.0.0.1:7899/health"
  echo "SAGA_MCP_HEALTH_URL=http://localhost:3851/health"
  echo "AGENTOS_HOOKS_LOG_DIR=/tmp/agentos-hooks"
  echo "AGENTOS_AUDIT_LOG=${INSTALL_ROOT}/claude/.claude/audit.log"
} > "$ENV_FILE"
chown root:"$AGENT_USER" "$ENV_FILE"
chmod 0640 "$ENV_FILE"
umask 022
log "  wrote ${ENV_FILE}"
mark_step_completed 11

###############################################################################
# Step 12 — render per-agent .claude.json
###############################################################################
step "12/18 per-agent claude config"

CLAUDE_CFG_TPL="${TEMPLATE_DIR}/.claude-config.template.json"

if [[ ! -f "$CLAUDE_CFG_TPL" ]]; then
  fail ".claude-config.template.json not found in ${TEMPLATE_DIR}"
fi

render_user_claude_json() {
  local dest=$1
  local target="${dest}/.claude.json"
  sed \
    -e "s|\${INSTALL_ROOT}|${INSTALL_ROOT}|g" \
    -e "s|\${STATE_DIR}|${STATE_DIR}|g" \
    -e "s|\${BUN_PATH}|${BUN_PATH}|g" \
    "$CLAUDE_CFG_TPL" > "$target"
  chown "$AGENT_USER:$AGENT_USER" "$target"
  chmod 0640 "$target"
}

# Per-agent settings.json (channelsEnabled, allowedChannelPlugins, enabledPlugins,
# extraKnownMarketplaces, permissions). Different from .claude.json — settings.json
# holds policy/feature toggles claude reads at startup; .claude.json holds user
# state (theme, hasCompletedOnboarding, projects, oauthAccount cache, ...).
SETTINGS_TPL="${TEMPLATE_DIR}/.claude-settings.template.json"
render_user_settings_json() {
  local dest=$1
  local target="${dest}/settings.json"
  if [[ -f "$SETTINGS_TPL" ]]; then
    sed \
      -e "s|\${INSTALL_ROOT}|${INSTALL_ROOT}|g" \
      -e "s|\${STATE_DIR}|${STATE_DIR}|g" \
      "$SETTINGS_TPL" > "$target"
    chown "$AGENT_USER:$AGENT_USER" "$target"
    chmod 0640 "$target"
  fi
}

render_user_claude_json "$CC_DIR_OPERATOR"
render_user_claude_json "$CC_DIR_DISPATCHER"
render_user_claude_json "$CC_DIR_HEARTBEAT"
render_user_settings_json "$CC_DIR_OPERATOR"
render_user_settings_json "$CC_DIR_DISPATCHER"
render_user_settings_json "$CC_DIR_HEARTBEAT"
log "  per-agent ~/.claude.json + settings.json rendered for operator/dispatcher/heartbeat"
mark_step_completed 12

###############################################################################
# Step 13 — managed-settings.json (org-wide claude-code policy)
###############################################################################
step "13/18 managed-settings"

MS_TPL="${TEMPLATE_DIR}/managed-settings.template.json"
if [[ -f "$MS_TPL" ]]; then
  if [[ "${MINIMAL}" == 1 ]]; then
    # Strip telegram@agentos from enabledPlugins + allowedChannelPlugins,
    # and drop mcp__telegram__* permission. Result is a saga + claude-peers
    # only managed-settings.json — no telegram references at all.
    # NOTE: enabledPlugins / allowedChannelPlugins are OBJECTS (records)
    # in claude-code 2.1.119+ schema, not arrays — use `del(.[name])`.
    jq '
      .enabledPlugins         |= del(.["telegram@agentos"])
      | .allowedChannelPlugins  |= del(.["telegram@agentos"])
      | .permissions.allow      |= map(select(. != "mcp__telegram__*"))
    ' "$MS_TPL" > "$CLAUDE_MANAGED_FILE"
    chown root:root "$CLAUDE_MANAGED_FILE"
    chmod 0644 "$CLAUDE_MANAGED_FILE"
    log "  installed ${CLAUDE_MANAGED_FILE} (--minimal: telegram@agentos stripped)"
  else
    install -m 0644 -o root -g root "$MS_TPL" "$CLAUDE_MANAGED_FILE"
    log "  installed ${CLAUDE_MANAGED_FILE}"
  fi
else
  warn "  managed-settings.template.json missing in ${TEMPLATE_DIR} — skipping"
fi
mark_step_completed 13

###############################################################################
# Step 14 — install + reload systemd
###############################################################################
step "14/18 systemd reload"

systemctl daemon-reload
mark_step_completed 14

###############################################################################
# Step 14b (minimal-only) — strip telegram/operator-coupled lifecycle hooks
###############################################################################
# notify-stop.sh and log-subagent.sh both push to operator-via-telegram, so
# they're useless without the operator. log-action.sh runs formatters which
# are also a heavier dependency footprint. For minimal: keep only the core
# guard + boot + enrich + session-end set.
if [[ "${MINIMAL}" == 1 ]]; then
  step "14b/18 minimal — strip telegram/operator-coupled hooks"
  CLAUDE_REPO_DIR="${INSTALL_ROOT}/claude"
  HOOKS_TO_REMOVE=(notify-stop.sh log-subagent.sh log-action.sh)
  for h in "${HOOKS_TO_REMOVE[@]}"; do
    if [[ -f "${CLAUDE_REPO_DIR}/.claude/hooks/${h}" ]]; then
      rm -f "${CLAUDE_REPO_DIR}/.claude/hooks/${h}"
      log "  removed .claude/hooks/${h}"
    fi
  done
  # Strip the matching entries from settings.json so Claude Code doesn't try
  # to invoke missing scripts. Use jq to drop Stop, SubagentStop, PostToolUse
  # entries (the only events that referenced removed hooks).
  SETTINGS="${CLAUDE_REPO_DIR}/.claude/settings.json"
  if [[ -f "$SETTINGS" ]]; then
    jq 'del(.hooks.Stop) | del(.hooks.SubagentStop) | del(.hooks.PostToolUse)' \
      "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    chown "$AGENT_USER:$AGENT_USER" "$SETTINGS"
    log "  stripped Stop / SubagentStop / PostToolUse hook entries from .claude/settings.json"
  fi
fi

###############################################################################
# Step 15 — initialize saga DB (first-boot)
###############################################################################
step "15/18 saga db init"

INIT_SCRIPT="${INSTALL_ROOT}/claude/scripts/init-epics.sh"
if [[ -x "$INIT_SCRIPT" ]]; then
  if [[ ! -f "${STATE_DIR}/saga.db" ]]; then
    sudo -u "$AGENT_USER" \
      env DB_PATH="${STATE_DIR}/saga.db" "$INIT_SCRIPT" || \
      warn "  init-epics.sh exited non-zero — saga will create DB on first request"
  else
    log "  saga.db already exists"
  fi
else
  log "  init-epics.sh not found — saga-mcp will auto-create DB on first connect"
fi
mark_step_completed 15

###############################################################################
# Step 16 — optional plugins
###############################################################################
step "16/18 optional plugins"

if [[ -n "${WITH_PLUGINS}" ]]; then
  PLUGINS_DIR="${INSTALL_ROOT}/claude/plugins"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$PLUGINS_DIR"
  IFS=',' read -ra _PLUGINS <<<"${WITH_PLUGINS}"
  for plugin in "${_PLUGINS[@]}"; do
    src="${INSTALL_ROOT}/claude/plugins.optional/${plugin}"
    dest="${PLUGINS_DIR}/${plugin}"
    if [[ -d "$src" && ! -d "$dest" ]]; then
      cp -r "$src" "$dest"
      chown -R "$AGENT_USER:$AGENT_USER" "$dest"
      log "  vendored plugin: ${plugin}"
    elif [[ -d "$dest" ]]; then
      log "  plugin already present: ${plugin}"
    else
      warn "  plugin not found in plugins.optional: ${plugin}"
    fi
  done
else
  log "  no --with= plugins requested"
fi
mark_step_completed 16

###############################################################################
# Step 17 — enable + start
###############################################################################
step "17/18 enable + start units"

# NOTE: claude-peers + telegram no longer have dedicated systemd units —
# they are stdio MCP plugins, spawned by Claude Code itself per session.
# claude-peers' broker daemon is auto-bootstrapped from server.ts on first
# spawn (see plugins/claude-peers/server.ts).
UNITS=(agent-os-saga.service agent-os-dispatcher.timer)
if [[ "${MINIMAL}" == 0 ]]; then
  UNITS+=(agent-os-operator.service)
fi

systemctl enable --now "${UNITS[@]}"
mark_step_completed 17

###############################################################################
# Step 18 — wait + verify
###############################################################################
step "18/18 verify"

sleep 6

verify_unit() {
  local unit=$1
  if systemctl is-active --quiet "$unit"; then
    log "  [OK] $unit active"
  else
    warn "  [WARN] $unit not active — check 'journalctl -u $unit -n 50'"
  fi
}

for u in "${UNITS[@]}"; do verify_unit "$u"; done

# saga-mcp HTTP probe (claude-peers broker comes up only when the first plugin
# session spawns — no probe at install time)
if curl -fsS --max-time 3 http://127.0.0.1:3851/health >/dev/null 2>&1 \
  || curl -fsS --max-time 3 http://127.0.0.1:3851/ >/dev/null 2>&1; then
  log "  [OK] saga-mcp responding on :3851"
else
  warn "  [WARN] saga-mcp not responding — check journalctl -u agent-os-saga"
fi
mark_step_completed 18

###############################################################################
# Optional: --harden firewall
###############################################################################
if [[ "$HARDEN" == 1 ]]; then
  step "extra: --harden egress firewall"
  ufw --force reset >/dev/null
  ufw default deny outgoing
  ufw default deny incoming
  ufw allow ssh
  # Allow DNS
  ufw allow out 53/udp
  ufw allow out 53/tcp
  # Allow apt repos + Anthropic + GitHub (resolved at firewall time)
  for host in api.anthropic.com downloads.claude.ai github.com api.github.com codeload.github.com objects.githubusercontent.com archive.ubuntu.com security.ubuntu.com deb.debian.org security.debian.org deb.nodesource.com bun.sh registry.npmjs.org ; do
    if getent hosts "$host" >/dev/null; then
      for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
        ufw allow out to "$ip" proto tcp port 443
      done
    fi
  done
  ufw --force enable
  log "  ufw enabled, default deny egress, allow-list applied"
fi

###############################################################################
# Final summary
###############################################################################
if [[ "${MINIMAL}" == 1 ]]; then
  MODE_LABEL="AgentOS installed (minimal — saga + dispatcher + claude-peers, no operator/telegram)."
  OPERATOR_LINE="  (no operator in --minimal mode — re-run install.sh without --minimal to add it)"
  LOGS_LINE="  Logs:          tail -f ${LOG_DIR}/{dispatcher,saga-mcp}.log"
else
  MODE_LABEL="AgentOS installed."
  OPERATOR_LINE="  Operator tmux: sudo -u ${AGENT_USER} tmux attach -t operator"
  LOGS_LINE="  Logs:          tail -f ${LOG_DIR}/{operator,dispatcher,saga-mcp}.log"
fi

cat <<EOF

========================================================================
  ${MODE_LABEL}
========================================================================
  Repo:          ${INSTALL_ROOT}/claude
  State:         ${STATE_DIR}
  Logs:          ${LOG_DIR}
  Env file:      ${ENV_FILE}  (mode 0640, root:${AGENT_USER})
  Managed:      ${CLAUDE_MANAGED_FILE}

  Per-agent CLAUDE_CONFIG_DIR:
    operator   -> ${CC_DIR_OPERATOR}
    dispatcher -> ${CC_DIR_DISPATCHER}
    heartbeat  -> ${CC_DIR_HEARTBEAT}

  Verify:        sudo systemctl status 'agent-os-*'
${OPERATOR_LINE}
  Dispatcher:    journalctl -u agent-os-dispatcher.service -f

${LOGS_LINE}
========================================================================
EOF
