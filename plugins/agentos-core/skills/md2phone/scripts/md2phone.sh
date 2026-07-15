#!/usr/bin/env bash
# md2phone — serve a markdown/HTML file or directory over a cloudflared quick
# tunnel so it can be read on a phone. No Cloudflare account or config needed.
#
#   md2phone.sh <file-or-dir>          start: render .md, serve, open tunnel, print URL
#   md2phone.sh --stop                 stop the running (local) server + tunnel
#   md2phone.sh --stop <slug>          stop a detached host-tmux session md2phone-<slug>
#   md2phone.sh --render <md>          print standalone HTML for a markdown file
#   md2phone.sh --detach <file-or-dir> force the host-tmux detached mode (see below)
#   md2phone.sh --no-detach <f-o-d>    force the in-process (local) mode
#
# Markdown is wrapped into a self-contained HTML page rendered client-side with
# marked + github-markdown-css (from CDN), so no local pandoc/grip is required.
#
# ── Why detached (host-tmux) mode exists ──────────────────────────────────────
# When md2phone is invoked from inside an agent sandbox (operator subagent,
# heartbeat worker — anything with its own private mount namespace), the
# `nohup ... & disown` server + tunnel are still in the sandbox's process tree.
# The moment that sandbox exits (an ephemeral subagent finishing its turn), the
# kernel reaps the whole tree and the tunnel dies — the URL we just sent to the
# phone returns Cloudflare 530/502 seconds later.
#
# Fix: when running inside a sandbox we DETACH — render the page into a path that
# is shared with the host mount namespace, then launch the python server +
# cloudflared inside a *host-namespace* tmux session (the canonical AgentOS
# pattern: `sudo -n nsenter --mount=/proc/1/ns/mnt -- runuser -u "$HOST_USER" --
# env TMUX_TMPDIR=/home/$HOST_USER/.tmux tmux new-session ...`). Those processes
# now live in the host process tree, survive the sandbox, and the session shows up
# in plain `tmux ls`. Each detached run gets its own slug, port and state dir, so
# parallel invocations never collide. Stop one with `--stop <slug>`.
#
# On Mac dev / a plain host shell (no sandbox) nothing changes — the original
# in-process mode is used.
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"

STATE_DIR="${TMPDIR:-/tmp}/md2phone"
PID_FILE="$STATE_DIR/pids"
LOG_FILE="$STATE_DIR/cloudflared.log"
PORT="${MD2PHONE_PORT:-8765}"

# Base for detached-mode per-session state. MUST be a path that is writable from
# the agent sandbox AND visible in the host mount namespace (so the host-tmux
# server can serve the rendered page and the sandbox can read back the URL).
# /var/lib/agent-os qualifies on a standard AgentOS host (shared + writable);
# /home is read-only inside sandboxes and /tmp is private, so neither works.
# Override with MD2PHONE_STATE_DIR.
STATE_BASE="${MD2PHONE_STATE_DIR:-/var/lib/agent-os/md2phone}"

# Canonical host-namespace tmux invocation (see the "Host (PID-1) mount
# namespace" convention + canonical socket TMUX_TMPDIR=/home/$HOST_USER/.tmux).
# Defaults to the invoking (non-root) user; override with MD2PHONE_HOST_USER.
HOST_USER="${MD2PHONE_HOST_USER:-${SUDO_USER:-$(id -un)}}"
HOST_TMUX_TMPDIR="${MD2PHONE_HOST_TMUX_TMPDIR:-/home/${HOST_USER}/.tmux}"
HOST_PREFIX=(sudo -n nsenter --mount=/proc/1/ns/mnt -- runuser -u "$HOST_USER" --
             env "TMUX_TMPDIR=${HOST_TMUX_TMPDIR}")

host_tmux() { "${HOST_PREFIX[@]}" tmux "$@"; }
host_session_exists() { host_tmux has-session -t "$1" 2>/dev/null; }

# True when we are inside an agent sandbox whose process tree would be reaped on
# exit, AND we can reach the host namespace to detach into it. Heuristic:
# CLAUDECODE / AGENTOS_WORKER_MODE marks an agent context; a successful no-prompt
# `nsenter` into PID-1's mount ns proves we both differ from it and may enter it.
in_sandbox() {
  [[ "${MD2PHONE_NO_DETACH:-}" == 1 ]] && return 1
  [[ -n "${CLAUDECODE:-}${AGENTOS_WORKER_MODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]] || return 1
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n nsenter --mount=/proc/1/ns/mnt -- true 2>/dev/null
}

extract_og() {
  # $1 = markdown file -> prints two HTML-escaped lines: TITLE then DESCRIPTION.
  # title  = first markdown heading, else the filename (sans extension);
  # desc   = first real paragraph (skips headings/code-fences/tables/hr/comments),
  #          stripped of markdown markup and clamped to ~200 chars.
  # These feed Open Graph tags so Telegram renders a preview card for the link.
  python3 - "$1" <<'PY'
import sys, re, os, html
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lines = text.splitlines()

title = ''
for ln in lines:
    m = re.match(r'\s*#{1,6}\s+(.*\S)', ln)
    if m:
        title = m.group(1).strip()
        break
if not title:
    title = re.sub(r'\.(md|markdown)$', '', os.path.basename(sys.argv[1]), flags=re.I)

desc, in_fence = '', False
for ln in lines:
    s = ln.strip()
    if s.startswith('```') or s.startswith('~~~'):
        in_fence = not in_fence
        continue
    if in_fence or not s:
        continue
    if s.startswith('#') or s.startswith('<!--') or s.startswith('|'):
        continue
    if re.match(r'^([-*_])\1{2,}$', s):  # horizontal rule
        continue
    desc = s
    break
desc = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', desc)      # images
desc = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', desc)  # links -> text
desc = re.sub(r'^\s*[-*+]\s+', '', desc)              # leading list bullet
desc = re.sub(r'[*_`>~#]', '', desc).strip()          # emphasis/code/quote markers
if len(desc) > 200:
    desc = desc[:197].rstrip() + '...'

print(html.escape(title, quote=True))
print(html.escape(desc, quote=True))
PY
}

render_html() {
  # $1 = markdown file -> standalone HTML on stdout
  local title desc
  { read -r title; read -r desc; } < <(extract_og "$1")
  cat <<'HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
HEAD
  printf '<title>%s</title>\n' "$title"
  # Open Graph + Twitter card so Telegram (and other chats) render a preview
  # card for the tunnel link instead of a bare URL. og:image is optional.
  printf '<meta property="og:title" content="%s">\n' "$title"
  printf '<meta property="og:description" content="%s">\n' "$desc"
  printf '<meta property="og:type" content="article">\n'
  printf '<meta name="twitter:card" content="summary">\n'
  [[ -n "${MD2PHONE_OG_IMAGE:-}" ]] && printf '<meta property="og:image" content="%s">\n' "$MD2PHONE_OG_IMAGE"
  cat <<'MID'
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown.min.css">
<script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>
<style>
  body { margin: 0; background: #fff; }
  @media (prefers-color-scheme: dark) { body { background: #0d1117; } }
  .markdown-body { box-sizing: border-box; max-width: 900px; margin: 0 auto; padding: 32px 24px; }
  @media (max-width: 767px) { .markdown-body { padding: 20px 14px; font-size: 16px; } }
</style>
</head>
<body>
<article class="markdown-body" id="content"></article>
<script id="src" type="text/markdown">
MID
  # neutralise any literal </script> inside the document so it can be embedded
  sed 's#</script#<\\/script#g' "$1"
  cat <<'TAIL'
</script>
<script>
  marked.setOptions({ gfm: true, breaks: false });
  document.getElementById('content').innerHTML =
    marked.parse(document.getElementById('src').textContent);
</script>
</body>
</html>
TAIL
}

materialize_serve() {
  # Render/copy $1 (file or dir) into serve dir $2 so it can be served as static
  # content. Prints the URL path suffix (empty, or "/<filename>" for a verbatim
  # non-html/md file) on stdout. Used by detached mode — the target may live in
  # the sandbox's private /tmp, so we always COPY into the shared serve dir
  # rather than serve the original path in place.
  local target="$1" serve_dir="$2" path_suffix=""
  mkdir -p "$serve_dir"
  if [[ -d "$target" ]]; then
    cp -a "$target/." "$serve_dir/" 2>/dev/null || cp -R "$target/." "$serve_dir/"
  else
    case "$target" in
      *.md|*.markdown) render_html "$target" > "$serve_dir/index.html" ;;
      *.html|*.htm)    cp "$target" "$serve_dir/index.html" ;;
      *)               cp "$target" "$serve_dir/"; path_suffix="/$(basename "$target")" ;;
    esac
  fi
  printf '%s' "$path_suffix"
}

port_in_use() {
  # $1 = port. Checked in whatever namespace the caller runs in (the detached
  # serve loop runs in the host ns, which is what matters for binding).
  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    ss -ltn 2>/dev/null | grep -q ":$1 "
  fi
}

find_free_port() {
  # $1 = starting port; scans upward for the first free one (range +200).
  local p="$1" stop=$(( $1 + 200 ))
  while port_in_use "$p"; do
    p=$((p+1))
    [[ "$p" -gt "$stop" ]] && { echo "md2phone: no free port near $1" >&2; return 1; }
  done
  echo "$p"
}

stop_quiet() {
  [[ -f "$PID_FILE" ]] || return 0
  local p
  for p in $(cat "$PID_FILE"); do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  rm -f "$PID_FILE"
}

free_port() {
  # Kill ANY process listening on $PORT, not just our tracked PIDs. A stale
  # md2phone server (or an orphan from a crashed run) squatting the port makes
  # `python3 -m http.server` silently fail to bind (its stderr goes to /dev/null),
  # so the fresh cloudflared tunnel ends up proxying to the OLD server — the link
  # opens stale content. Freeing the port first is what makes a re-run actually
  # serve the new file. Also reap stray quick-tunnels so they don't accumulate.
  local pids
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
  fi
  # orphaned quick tunnels pointing at our port
  pids="$(pgrep -f "cloudflared tunnel --config /dev/null --url http://localhost:$PORT" 2>/dev/null || true)"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
  # give the kernel a moment to release the socket before we re-bind
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if command -v lsof >/dev/null 2>&1; then
      lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
    else
      ss -ltn 2>/dev/null | grep -q ":$PORT " || break
    fi
    sleep 0.3
  done
}

start() {
  local target="$1"
  command -v cloudflared >/dev/null || { echo "md2phone: cloudflared not found — 'brew install cloudflared'" >&2; exit 1; }
  command -v python3   >/dev/null || { echo "md2phone: python3 not found" >&2; exit 1; }
  [[ -e "$target" ]] || { echo "md2phone: not found — $target" >&2; exit 1; }

  stop_quiet
  free_port
  mkdir -p "$STATE_DIR"

  local serve_dir path_suffix=""
  if [[ -d "$target" ]]; then
    serve_dir="$target"
  else
    serve_dir="$(mktemp -d "$STATE_DIR/serve.XXXXXX")"
    case "$target" in
      *.md|*.markdown) render_html "$target" > "$serve_dir/index.html" ;;
      *.html|*.htm)    cp "$target" "$serve_dir/index.html" ;;
      *)               cp "$target" "$serve_dir/"; path_suffix="/$(basename "$target")" ;;
    esac
  fi

  nohup python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$serve_dir" \
    >/dev/null 2>&1 & disown
  local http_pid=$!

  # Verify OUR python actually owns the port before opening a tunnel to it.
  # If a foreign server still squats $PORT (free_port lost the race, or bind
  # failed for any reason), the tunnel would proxy stale content — so bail out
  # loudly instead of handing back a link to someone else's page.
  local bound="" i listener
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if command -v lsof >/dev/null 2>&1; then
      listener="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    else
      listener="$(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)"
    fi
    if [[ "$listener" == "$http_pid" ]]; then bound=1; break; fi
    kill -0 "$http_pid" 2>/dev/null || break   # our server already died
    sleep 0.3
  done
  if [[ -z "$bound" ]]; then
    echo "md2phone: port $PORT is held by another process (pid ${listener:-?}) — could not serve $target. Run 'md2phone.sh --stop' or free the port and retry." >&2
    stop_quiet
    exit 1
  fi

  : > "$LOG_FILE"
  # --config /dev/null isolates the quick tunnel from any system cloudflared
  # config (e.g. /etc/cloudflared/config.yml on a server already running a
  # named tunnel). Without it cloudflared inherits that file's ingress — often
  # a `http_status:404` catch-all — so the quick tunnel returns 404 for every
  # path even though the local server is healthy. Harmless where no system
  # config exists (Mac dev).
  nohup cloudflared tunnel --config /dev/null --url "http://localhost:$PORT" >"$LOG_FILE" 2>&1 & disown
  local cf_pid=$!

  printf '%s\n%s\n' "$http_pid" "$cf_pid" > "$PID_FILE"

  local url="" i
  for i in $(seq 1 30); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_FILE" | head -1 || true)"
    [[ -n "$url" ]] && break
    sleep 1
  done
  if [[ -z "$url" ]]; then
    echo "md2phone: tunnel did not come up — see $LOG_FILE" >&2
    stop_quiet
    exit 1
  fi
  echo "${url}${path_suffix}"
}

slugify() {
  # filename -> short kebab slug for tmux session / state dir naming
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/\.(md|markdown|html?|txt)$//; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [[ -z "$s" ]] && s="doc"
  printf '%s' "${s:0:24}"
}

serve_detached() {
  # Internal entrypoint — runs INSIDE the host-namespace tmux session. Starts the
  # python server + cloudflared, records the URL into the shared state dir, then
  # blocks (holding the tmux session open) until cloudflared exits or the session
  # is killed. $1 = state dir (shared path), $2 = starting port hint.
  local state_dir="$1" port_hint="${2:-8771}"
  local serve_dir="$state_dir/serve"
  local log="$state_dir/cloudflared.log" pidf="$state_dir/pids" urlf="$state_dir/url"

  command -v cloudflared >/dev/null || { echo "cloudflared not found" > "$urlf"; exit 1; }
  command -v python3   >/dev/null || { echo "python3 not found" > "$urlf"; exit 1; }

  local port
  port="$(find_free_port "$port_hint")" || { echo "FAILED" > "$urlf"; exit 1; }

  nohup python3 -m http.server "$port" --bind 127.0.0.1 --directory "$serve_dir" >/dev/null 2>&1 &
  local http_pid=$!

  # confirm our python actually bound the port
  local bound="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if port_in_use "$port"; then bound=1; break; fi
    kill -0 "$http_pid" 2>/dev/null || break
    sleep 0.3
  done
  [[ -n "$bound" ]] || { echo "FAILED" > "$urlf"; kill "$http_pid" 2>/dev/null || true; exit 1; }

  : > "$log"
  nohup cloudflared tunnel --config /dev/null --url "http://localhost:$port" >"$log" 2>&1 &
  local cf_pid=$!

  printf '%s\n%s\n%s\n' "$http_pid" "$cf_pid" "$port" > "$pidf"

  local url=""
  for i in $(seq 1 30); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" | head -1 || true)"
    [[ -n "$url" ]] && break
    kill -0 "$cf_pid" 2>/dev/null || break
    sleep 1
  done
  if [[ -z "$url" ]]; then
    echo "FAILED" > "$urlf"
    kill "$http_pid" "$cf_pid" 2>/dev/null || true
    exit 1
  fi
  printf '%s' "$url" > "$urlf"

  # Hold the tmux session open. The whole point: these processes now live in the
  # host process tree, so they outlive the sandbox that launched us. Clean up when
  # the session is killed (--stop) or cloudflared dies.
  trap 'kill "$http_pid" "$cf_pid" 2>/dev/null || true; exit 0' TERM INT
  while kill -0 "$cf_pid" 2>/dev/null; do sleep 5; done
  kill "$http_pid" 2>/dev/null || true
}

start_detached() {
  # Sandbox mode — render into a shared state dir, then launch the server+tunnel
  # inside a host-namespace tmux session so they survive this sandbox.
  local target="$1"
  [[ -e "$target" ]] || { echo "md2phone: not found — $target" >&2; exit 1; }
  command -v python3 >/dev/null || { echo "md2phone: python3 not found" >&2; exit 1; }

  local slug session n=1
  slug="$(slugify "$(basename "$target")")"
  session="md2phone-$slug"
  while host_session_exists "$session"; do n=$((n+1)); session="md2phone-$slug-$n"; done
  slug="${session#md2phone-}"

  local state_dir="$STATE_BASE/$slug"
  rm -rf "$state_dir" 2>/dev/null || true
  mkdir -p "$state_dir/serve" || { echo "md2phone: cannot write state dir $state_dir (set MD2PHONE_STATE_DIR to a path shared with the host ns)" >&2; exit 1; }

  local path_suffix
  path_suffix="$(materialize_serve "$target" "$state_dir/serve")"

  # deterministic-but-varied port hint per session so parallel runs start their
  # scan at different ports (the scan itself also guards against collisions)
  local hint
  hint=$(( 8771 + $(cksum <<<"$session" | cut -d' ' -f1) % 100 ))

  : > "$state_dir/url"
  if ! host_tmux new-session -d -s "$session" -c /tmp \
        "exec env TMUX_TMPDIR='${HOST_TMUX_TMPDIR}' bash '$SCRIPT_PATH' --serve '$state_dir' '$hint'"; then
    echo "md2phone: failed to launch host-tmux session (sudo -n nsenter / runuser unavailable?)" >&2
    exit 1
  fi

  local url="" i
  for i in $(seq 1 40); do
    url="$(cat "$state_dir/url" 2>/dev/null || true)"
    [[ "$url" == https://* ]] && break
    if [[ -n "$url" && "$url" != https://* ]]; then
      echo "md2phone: detached tunnel failed ($url) — see $state_dir/cloudflared.log" >&2
      host_tmux kill-session -t "$session" 2>/dev/null || true
      exit 1
    fi
    host_session_exists "$session" || { echo "md2phone: serve session died early — see $state_dir/cloudflared.log" >&2; exit 1; }
    sleep 1
  done
  if [[ "$url" != https://* ]]; then
    echo "md2phone: timed out waiting for tunnel URL — see $state_dir/cloudflared.log" >&2
    exit 1
  fi
  echo "md2phone: detached session '$session' (stop with: md2phone.sh --stop $slug)" >&2
  echo "${url}${path_suffix}"
}

stop_detached() {
  local arg="$1" session slug
  if [[ "$arg" == md2phone-* ]]; then session="$arg"; else session="md2phone-$arg"; fi
  slug="${session#md2phone-}"
  if host_session_exists "$session"; then
    host_tmux kill-session -t "$session" 2>/dev/null || true
    echo "md2phone: stopped $session"
  else
    echo "md2phone: no detached session $session"
  fi
  rm -rf "$STATE_BASE/$slug" 2>/dev/null || true
}

case "${1:-}" in
  --stop)
    if [[ -n "${2:-}" ]]; then stop_detached "$2"; else stop_quiet; free_port; echo "md2phone: stopped"; fi ;;
  --render)
    [[ -n "${2:-}" ]] || { echo "usage: md2phone.sh --render <md>" >&2; exit 1; }
    render_html "$2" ;;
  --serve)
    [[ -n "${2:-}" ]] || { echo "usage: md2phone.sh --serve <state-dir> [port-hint]" >&2; exit 1; }
    serve_detached "$2" "${3:-8771}" ;;
  --detach|--tmux)
    [[ -n "${2:-}" ]] || { echo "usage: md2phone.sh --detach <file-or-dir>" >&2; exit 1; }
    start_detached "$2" ;;
  --no-detach)
    [[ -n "${2:-}" ]] || { echo "usage: md2phone.sh --no-detach <file-or-dir>" >&2; exit 1; }
    start "$2" ;;
  "")
    echo "usage: md2phone.sh <file-or-dir> | --stop [slug] | --render <md> | --detach <file-or-dir>" >&2
    exit 1 ;;
  *)
    if in_sandbox; then start_detached "$1"; else start "$1"; fi ;;
esac
