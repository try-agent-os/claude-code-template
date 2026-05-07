#!/usr/bin/env bash
# AgentOS one-command installer for Ubuntu 22.04/24.04 + Debian 12+.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/try-agent-os/claude-code-template/main/install.sh | sudo bash
#   # OR
#   git clone https://github.com/try-agent-os/claude-code-template /tmp/agentos-installer
#   sudo /tmp/agentos-installer/install.sh
#
# Flags:
#   --minimal                       Skip operator (saga + dispatcher only).
#                                   Plugins (claude-peers, telegram) still install
#                                   but only spawn when an operator-style session runs.
#   --with=feature-dev,frontend-design  Comma-separated optional plugins to vendor
#   --non-interactive               Read all wizard answers from preset env vars (CI/automation)
#   --bootstrap-personal-repo URL   Replace template remote with user's own GitHub fork
#   --whisper=tiny|base|medium      Whisper model size (default medium, 1.5 GB)
#   --harden                        Apply egress firewall (deny by default, allow only api.anthropic.com,
#                                   GitHub, apt repos). Off by default — heavy.
#   --skip-build                    Skip MCP build steps (assume artefacts exist; for re-runs)
#   --resume                        Re-entry from a half-completed install (idempotent anyway)
#
# Authentication: get a 1-year OAuth token on your local machine with
#   `claude setup-token`
# and either export it as CLAUDE_CODE_OAUTH_TOKEN before running, or paste it
# at the wizard prompt.
#
set -euo pipefail

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

# Anthropic apt repo signing key fingerprint (hard-coded for verification).
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

# Where this script lives — used to find systemd templates etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The script may be run via `curl | bash` (no SCRIPT_DIR templates) — in that
# case we'll clone the template into INSTALL_ROOT first and re-source from there.
TEMPLATE_DIR="${SCRIPT_DIR}"

###############################################################################
# Logging + error trap
###############################################################################
CURRENT_STEP="init"

log()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

on_err() {
  local exit_code=$? line=$1
  printf '\n\033[1;31m[install] FAILED at step "%s" (line %s, exit %s)\033[0m\n' \
    "${CURRENT_STEP}" "${line}" "${exit_code}" >&2
  printf '[install] Re-run the same command — install.sh is idempotent.\n' >&2
  exit "${exit_code}"
}
trap 'on_err $LINENO' ERR

step() { CURRENT_STEP="$1"; log "==> $1"; }

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
# Step 1 — sanity (root, OS, arch)
###############################################################################
step "1/18 sanity checks"

[[ $EUID -eq 0 ]] || fail "Run as root (use sudo)."

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

###############################################################################
# Step 2 — wizard
###############################################################################
step "2/18 wizard"

prompt_var() {
  local var=$1 prompt=$2 default=${3:-} secret=${4:-0}
  # If already exported, keep it.
  if [[ -n "${!var:-}" ]]; then
    log "  using preset \$${var} (length=${#var})"
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" == 1 ]]; then
    if [[ -n "$default" ]]; then
      printf -v "$var" '%s' "$default"
      export "$var"
    else
      fail "--non-interactive but \$${var} is empty and has no default"
    fi
    return 0
  fi
  local val
  if [[ "$secret" == 1 ]]; then
    read -rsp "  ${prompt}: " val
    echo
  elif [[ -n "$default" ]]; then
    read -rp "  ${prompt} [${default}]: " val
    val="${val:-$default}"
  else
    read -rp "  ${prompt}: " val
  fi
  printf -v "$var" '%s' "$val"
  export "$var"
}

# Re-use existing env file if already configured (idempotent)
if [[ -f "$ENV_FILE" ]]; then
  log "  ${ENV_FILE} exists — sourcing existing config (will not re-prompt)"
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

prompt_var PROJECT_NAME      "Project name (slug)" "agentos"
prompt_var TIMEZONE          "Timezone (IANA, e.g. Europe/Lisbon)" "$(timedatectl show -p Timezone --value 2>/dev/null || echo 'UTC')"
prompt_var TG_BOT_TOKEN      "Telegram bot token (from @BotFather, blank to skip telegram)" ""
prompt_var TG_USER_ID        "Your Telegram user ID (from @userinfobot)" ""
prompt_var GIT_REMOTE        "Personal git remote (blank = use template only)" ""

# OAuth detection ladder
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  log "  CLAUDE_CODE_OAUTH_TOKEN already in env — using it"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  log "  ANTHROPIC_API_KEY in env — falling back (Console-billed mode, no Claude.ai subscription)"
else
  cat <<'OAUTH_HELP'

  No CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY found.
  On your LOCAL machine (Mac/Linux with browser), run:
      claude setup-token
  This prints a 1-year sk-ant-oat01-... token. Paste it here.
  (If you only have a Console API key instead, paste that — installer detects which.)

OAUTH_HELP
  prompt_var CLAUDE_CODE_OAUTH_TOKEN "OAuth token (sk-ant-oat01-...) or API key (sk-ant-api03-...)" "" 1
  if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    fail "Authentication required. Re-run after obtaining a token."
  fi
  # Sniff token type — if it starts with sk-ant-api, it's actually an API key
  if [[ "${CLAUDE_CODE_OAUTH_TOKEN}" == sk-ant-api* ]]; then
    ANTHROPIC_API_KEY="${CLAUDE_CODE_OAUTH_TOKEN}"
    unset CLAUDE_CODE_OAUTH_TOKEN
    export ANTHROPIC_API_KEY
    log "  detected API key (not OAuth) — switching var"
  fi
fi

###############################################################################
# Step 3 — APT prereqs (incl. bubblewrap + socat for sandbox)
###############################################################################
step "3/18 apt prereqs"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg git tmux jq sqlite3 \
  build-essential cmake ffmpeg \
  python3 python3-pip \
  ufw \
  bubblewrap socat

# yt-dlp via pip (apt version often lags). Ubuntu 23.04+ requires --break-system-packages.
if ! command -v yt-dlp >/dev/null 2>&1; then
  pip3 install --quiet --break-system-packages -U yt-dlp \
    || apt-get install -y yt-dlp \
    || fail "Could not install yt-dlp via pip or apt."
fi

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

###############################################################################
# Step 5 — Claude Code from signed apt repo (NOT npm, NOT curl install.sh)
###############################################################################
step "5/18 claude-code (signed apt repo)"

KEYRING="/usr/share/keyrings/anthropic.gpg"
SOURCES_LIST="/etc/apt/sources.list.d/claude-code.list"

if [[ ! -f "$KEYRING" ]]; then
  curl -fsSL https://downloads.claude.ai/claude-code/apt/anthropic.asc \
    | gpg --dearmor -o "$KEYRING"

  # Verify fingerprint
  actual_fpr=$(gpg --no-default-keyring --keyring "$KEYRING" --list-keys --with-colons \
    | awk -F: '/^fpr:/ {print $10; exit}')
  if [[ "$actual_fpr" != "$ANTHROPIC_KEY_FPR" ]]; then
    rm -f "$KEYRING"
    fail "Anthropic GPG key fingerprint mismatch: got $actual_fpr, expected $ANTHROPIC_KEY_FPR"
  fi
  log "  GPG key fingerprint verified: $actual_fpr"
fi

if [[ ! -f "$SOURCES_LIST" ]]; then
  echo "deb [signed-by=${KEYRING}] https://downloads.claude.ai/claude-code/apt stable main" \
    > "$SOURCES_LIST"
fi

apt-get update -qq
apt-get install -y claude-code

if ! command -v claude >/dev/null 2>&1; then
  fail "claude-code installed but 'claude' not on PATH — investigate apt postinst."
fi
log "  claude --version: $(claude --version 2>&1 | head -1)"

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

  # telegram plugin (node + whisper.cpp build + model download)
  if [[ -d "${INSTALL_ROOT}/claude/plugins/telegram" ]]; then
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
} > "$ENV_FILE"
chown root:"$AGENT_USER" "$ENV_FILE"
chmod 0640 "$ENV_FILE"
umask 022
log "  wrote ${ENV_FILE}"

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

render_user_claude_json "$CC_DIR_OPERATOR"
render_user_claude_json "$CC_DIR_DISPATCHER"
render_user_claude_json "$CC_DIR_HEARTBEAT"
log "  per-agent ~/.claude.json (saga-mcp SSE only; claude-peers + telegram via plugin discovery) rendered for operator/dispatcher/heartbeat"

###############################################################################
# Step 13 — managed-settings.json (org-wide claude-code policy)
###############################################################################
step "13/18 managed-settings"

MS_TPL="${TEMPLATE_DIR}/managed-settings.template.json"
if [[ -f "$MS_TPL" ]]; then
  install -m 0644 -o root -g root "$MS_TPL" "$CLAUDE_MANAGED_FILE"
  log "  installed ${CLAUDE_MANAGED_FILE}"
else
  warn "  managed-settings.template.json missing in ${TEMPLATE_DIR} — skipping"
fi

###############################################################################
# Step 14 — install + reload systemd
###############################################################################
step "14/18 systemd reload"

systemctl daemon-reload

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
cat <<EOF

========================================================================
  AgentOS installed.
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
  Operator tmux: sudo -u ${AGENT_USER} tmux attach -t operator
  Dispatcher:    journalctl -u agent-os-dispatcher.service -f

  Logs:          tail -f ${LOG_DIR}/{operator,dispatcher,saga-mcp}.log
========================================================================
EOF
