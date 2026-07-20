#!/usr/bin/env bash
# clickup.sh — thin wrapper over the ClickUp REST API v2.
#
# Direct official REST (curl + jq), dependency-light. Used by the interactive
# worker layer (the /done and /blocked slash commands and the worker prompt call
# `comment` and `update`) and by the operator (`create`, `get-list`, `dashboard`).
#
# Auth: personal token in the `Authorization: <token>` header (NO "Bearer " prefix).
#   Read from env CLICKUP_API_TOKEN, else CLICKUP_PERSONAL_TOKEN.
#   If both are empty, source the env file (AGENT_OS_ENV_FILE, default
#   /etc/agent-os/agent-os.env) and check again.
#
# Team / Space ids (needed only by `dashboard`) are read from env
#   CLICKUP_TEAM_ID / CLICKUP_SPACE_ID. Nothing is hardcoded. List ids are always
#   passed explicitly via `--list <id>`.
#
# Subcommands:
#   create     --list <id> --name "..." [--desc "..."] [--status todo] [--priority 2]
#                  [--assignees <id>,...] [--tags a,b] [--parent <task_id>]
#                  (--parent makes the new task a SUBTASK of <task_id>)
#   get-list   --list <id> [--status todo,in_progress,blocked]
#   dashboard  [--statuses todo,in_progress,blocked]   (team+space filtered)
#   update     --task <id> [--status ...] [--name ...] [--desc ...] [--priority ...]
#   get        --task <id> [--team <id>]              (--team => resolve custom id, e.g. DEV-123)
#   set-field  --task <id> --field <field_id> --value <v>    (custom field; dropdown value = option UUID)
#   del-field  --task <id> --field <field_id>                (clear a custom field value)
#   comment    --task <id> --text "..." [--markdown] [--notify]
#   comments   --task <id> [--json]                   (whole thread, ascending date;
#                  --json => raw objects with id/resolved/assignee/user)
#   reply-comment --comment <comment_id> --text "..." [--markdown] [--notify]
#                  (reply IN a comment thread — POST /comment/{id}/reply)
#   comment-replies --comment <comment_id>            (replies of a comment, ascending date)
#
# NB: to resolve a custom id (e.g. DEV-123) `get` takes --team; for writes use the
#     real .id from the get response (write subcommands do not resolve custom ids).
#
# NB(markdown): --desc on create/update writes ClickUp's `markdown_content` field
#     (renders **bold**/###/`code`/lists in the UI), NOT plain `description`
#     (which would show raw markdown literally). Comments render markdown only with
#     the --markdown flag (converted to a Quill block array via lib/md2quill.py).
#     Always write descriptions/comments through this wrapper, not raw curl with
#     {description:...}, or markdown will come back raw.
#
# Dependencies: curl, jq, python3 (only for --markdown comments).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Backend-agnostic delivery gate (see scripts/lib/delivery-guard.sh). Sourced, not
# reimplemented — the same function backs every task-queue adapter.
# shellcheck source=../lib/delivery-guard.sh
if [ -r "${SCRIPT_DIR}/../lib/delivery-guard.sh" ]; then
  . "${SCRIPT_DIR}/../lib/delivery-guard.sh"
else
  delivery_guard_check() { :; }   # lib missing → never block the CLI outright
fi

# --- Constants --------------------------------------------------------------
readonly API_BASE="https://api.clickup.com/api/v2"
readonly DEFAULT_STATUSES="todo,in_progress,blocked"
readonly ENV_FILE="${AGENT_OS_ENV_FILE:-/etc/agent-os/agent-os.env}"

# Team / Space ids come from the environment only (no hardcoded ids).
TEAM_ID="${CLICKUP_TEAM_ID:-}"
SPACE_ID="${CLICKUP_SPACE_ID:-}"

# --- Token ------------------------------------------------------------------
# Resolved once in main() into the global TOKEN. `exit 1` here fires in the main
# shell (not a subshell command-substitution), so the script really aborts with a
# clear error BEFORE any HTTP request rather than proceeding with an empty token.
TOKEN=""
resolve_token() {
  local tok="${CLICKUP_API_TOKEN:-${CLICKUP_PERSONAL_TOKEN:-}}"
  if [[ -z "$tok" && -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set +u
    source "$ENV_FILE" 2>/dev/null || true
    set -u
    tok="${CLICKUP_API_TOKEN:-${CLICKUP_PERSONAL_TOKEN:-}}"
    # Env ids may also live in the env file — pick them up if still unset.
    [[ -z "$TEAM_ID"  ]] && TEAM_ID="${CLICKUP_TEAM_ID:-}"
    [[ -z "$SPACE_ID" ]] && SPACE_ID="${CLICKUP_SPACE_ID:-}"
  fi
  if [[ -z "$tok" ]]; then
    echo "ERROR: ClickUp token not found. Set CLICKUP_API_TOKEN (or CLICKUP_PERSONAL_TOKEN)" >&2
    echo "       in the environment or in ${ENV_FILE}." >&2
    exit 1
  fi
  TOKEN="$tok"
}

# --- HTTP helper ------------------------------------------------------------
# req METHOD PATH [JSON_BODY]
# Prints the response body to stdout. On http-code !=2xx: body to stderr + exit 1.
# Always logs the http-code to stderr (so callers see diagnostics).
req() {
  local method="$1" path="$2" body="${3:-}"
  local url tmp http
  url="${API_BASE}${path}"
  tmp="$(mktemp)"
  # Clean up tmp AND disarm the trap on return. Without `set -T` (functrace) a
  # RETURN trap is shell-scoped, so it would otherwise re-fire on every later
  # function return; `trap - RETURN` inside the handler disarms it after req exits.
  # ${tmp:-} keeps it safe under `set -u` even if it somehow fires out of scope.
  trap 'rm -f "${tmp:-}"; trap - RETURN' RETURN

  local -a curl_args=(
    -sS -X "$method" "$url"
    -H "Authorization: ${TOKEN}"
    -H "Content-Type: application/json"
    -w '%{http_code}' -o "$tmp"
  )
  [[ -n "$body" ]] && curl_args+=(-d "$body")

  http="$(curl "${curl_args[@]}")" || {
    echo "ERROR: curl failed (network) for ${method} ${path}" >&2
    cat "$tmp" >&2 2>/dev/null || true
    return 1
  }

  echo "HTTP ${http} ${method} ${path}" >&2
  if [[ "$http" != 2* ]]; then
    echo "ERROR: ClickUp API returned ${http} on ${method} ${path}" >&2
    cat "$tmp" >&2
    echo >&2
    return 1
  fi
  cat "$tmp"
}

# --- Utilities --------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

# csv2json_strarr "a,b,c" -> ["a","b","c"]  (strings)
csv2json_strarr() {
  local csv="${1:-}"
  [[ -z "$csv" ]] && { echo "[]"; return; }
  jq -cn --arg s "$csv" '$s | split(",") | map(select(length>0) | gsub("^\\s+|\\s+$";""))'
}
# csv2json_intarr "1,2" -> [1,2]
csv2json_intarr() {
  local csv="${1:-}"
  [[ -z "$csv" ]] && { echo "[]"; return; }
  jq -cn --arg s "$csv" '$s | split(",") | map(select(length>0) | tonumber)'
}
# statuses csv -> query string &statuses[]=x&statuses[]=y
statuses_qs() {
  local csv="${1:-}" out="" s
  [[ -z "$csv" ]] && return
  IFS=',' read -ra arr <<< "$csv"
  for s in "${arr[@]}"; do
    s="$(echo "$s" | tr -d ' ')"
    [[ -z "$s" ]] && continue
    out+="&statuses%5B%5D=$(jq -rn --arg v "$s" '$v|@uri')"
  done
  printf '%s' "$out"
}

# --- Subcommands ------------------------------------------------------------
cmd_create() {
  # --tags accepts BOTH repeated flags (`--tags a --tags b`) AND CSV in a single
  # flag (`--tags a,b`), and a mix — all occurrences accumulate.
  local list="" name="" desc="" status="todo" priority="" assignees="" parent=""
  local tags=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list) list="$2"; shift 2;;
      --name) name="$2"; shift 2;;
      --desc) desc="$2"; shift 2;;
      --status) status="$2"; shift 2;;
      --priority) priority="$2"; shift 2;;
      --assignees) assignees="$2"; shift 2;;
      --tags)
        if [[ -z "$tags" ]]; then tags="$2"; else tags="${tags},$2"; fi
        shift 2;;
      --parent) parent="$2"; shift 2;;
      *) die "create: unknown flag $1";;
    esac
  done
  [[ -z "$list" ]] && die "create: need --list <id>"
  [[ -z "$name" ]] && die "create: need --name \"...\""

  local assignees_json tags_json
  assignees_json="$(csv2json_intarr "$assignees")"
  tags_json="$(csv2json_strarr "$tags")"

  # NB: description goes into ClickUp's `markdown_content` field (NOT plain
  # `description`). Only `markdown_content` renders **bold**/###/`code`/lists in
  # the ClickUp UI — `description` shows the raw markdown literally. It round-trips
  # via markdown_description on read (include_markdown_description=true) and
  # degrades to plain text fine.
  # --parent <task_id> makes the new task a SUBTASK of <task_id>; it goes verbatim
  # into the create body.
  local body
  body="$(jq -cn \
    --arg name "$name" \
    --arg desc "$desc" \
    --arg status "$status" \
    --argjson assignees "$assignees_json" \
    --argjson tags "$tags_json" \
    --arg priority "$priority" \
    --arg parent "$parent" \
    '{name:$name, status:$status}
     + (if $desc  != "" then {markdown_content:$desc} else {} end)
     + (if ($assignees|length)>0 then {assignees:$assignees} else {} end)
     + (if ($tags|length)>0 then {tags:$tags} else {} end)
     + (if $priority != "" then {priority:($priority|tonumber)} else {} end)
     + (if $parent != "" then {parent:$parent} else {} end)')"

  local resp
  resp="$(req POST "/list/${list}/task" "$body")"
  local task_id
  task_id="$(echo "$resp" | jq -r '.id')"

  # Safety-net: verify which tags actually attached and re-attach the missing ones
  # via POST /task/{id}/tag/{name}. The POST body with `tags:[...]` usually works,
  # but historically it was flaky — this is a belt. Extra call ~50ms per tag,
  # idempotent. If a post-create call fails we warn on stderr but do not fail the
  # whole command (the task already exists).
  if [[ "$tags" != "" && -n "$task_id" && "$task_id" != "null" ]]; then
    local attached_tags
    attached_tags="$(echo "$resp" | jq -r '[.tags[]?.name] | join(",")')"
    local want_tag
    IFS=',' read -ra _want <<< "$tags"
    for want_tag in "${_want[@]}"; do
      want_tag="$(echo "$want_tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$want_tag" ]] && continue
      if [[ ",${attached_tags}," != *",${want_tag},"* ]]; then
        # POST /task/{id}/tag/{name} creates the tag in the Space if missing and
        # attaches it to the task. URL-encode the tag name (for tags with `:` etc).
        local tag_enc
        tag_enc="$(jq -rn --arg v "$want_tag" '$v|@uri')"
        if req POST "/task/${task_id}/tag/${tag_enc}" >/dev/null 2>/tmp/clickup-tag-attach.err; then
          echo "TAG-ATTACHED ${task_id} +${want_tag}" >&2
        else
          echo "WARN: could not attach tag ${want_tag} to ${task_id}" >&2
          cat /tmp/clickup-tag-attach.err >&2 2>/dev/null || true
        fi
      fi
    done
  fi

  echo "$resp" | jq -r '"CREATED " + .id + " | " + (.status.status // "?") + " | " + .name + "\nURL: " + .url'
}

cmd_get_list() {
  local list="" status=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list) list="$2"; shift 2;;
      --status) status="$2"; shift 2;;
      *) die "get-list: unknown flag $1";;
    esac
  done
  [[ -z "$list" ]] && die "get-list: need --list <id>"

  local qs resp
  qs="$(statuses_qs "$status")"
  resp="$(req GET "/list/${list}/task?archived=false${qs}")"
  echo "$resp" | jq -r '.tasks[] | .id + " | " + (.status.status // "?") + " | " + .name'
}

cmd_dashboard() {
  local statuses="$DEFAULT_STATUSES"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --statuses) statuses="$2"; shift 2;;
      *) die "dashboard: unknown flag $1";;
    esac
  done
  [[ -z "$TEAM_ID" ]] && die "dashboard: CLICKUP_TEAM_ID is not set (export it or add it to ${ENV_FILE})"
  local qs space_qs resp
  qs="$(statuses_qs "$statuses")"
  # Space filter is optional — only added when CLICKUP_SPACE_ID is set.
  space_qs=""
  [[ -n "$SPACE_ID" ]] && space_qs="&space_ids%5B%5D=${SPACE_ID}"
  resp="$(req GET "/team/${TEAM_ID}/task?include_closed=false&page=0${space_qs}${qs}")"
  echo "$resp" | jq -r '.tasks[] | .id + " | " + (.status.status // "?") + " | " + (.list.name // "?") + " | " + .name'
}

cmd_update() {
  local task="" status="" name="" desc="" priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2;;
      --status) status="$2"; shift 2;;
      --name) name="$2"; shift 2;;
      --desc) desc="$2"; shift 2;;
      --priority) priority="$2"; shift 2;;
      *) die "update: unknown flag $1";;
    esac
  done
  [[ -z "$task" ]] && die "update: need --task <id>"

  # --desc updates ClickUp's `markdown_content` (renders in UI), not plain
  # `description` (which would show raw markdown). See cmd_create note.
  local body
  body="$(jq -cn \
    --arg status "$status" \
    --arg name "$name" \
    --arg desc "$desc" \
    --arg priority "$priority" \
    '{}
     + (if $status   != "" then {status:$status} else {} end)
     + (if $name     != "" then {name:$name} else {} end)
     + (if $desc     != "" then {markdown_content:$desc} else {} end)
     + (if $priority != "" then {priority:($priority|tonumber)} else {} end)')"
  [[ "$body" == "{}" ]] && die "update: nothing to update (pass at least one of --status/--name/--desc/--priority)"

  local resp
  resp="$(req PUT "/task/${task}" "$body")"
  echo "$resp" | jq -r '"UPDATED " + .id + " | " + (.status.status // "?") + " | " + .name'
}

cmd_get() {
  local task="" team=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2;;
      --team) team="$2"; shift 2;;
      *) die "get: unknown flag $1";;
    esac
  done
  [[ -z "$task" ]] && die "get: need --task <id>"
  local qs=""
  [[ -n "$team" ]] && qs="?custom_task_ids=true&team_id=${team}"
  req GET "/task/${task}${qs}" | jq .
}

cmd_set_field() {
  local task="" field="" value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)  task="$2";  shift 2;;
      --field) field="$2"; shift 2;;
      --value) value="$2"; shift 2;;
      *) die "set-field: unknown flag $1";;
    esac
  done
  [[ -z "$task"  ]] && die "set-field: need --task <id>"
  [[ -z "$field" ]] && die "set-field: need --field <field_id>"
  [[ -z "$value" ]] && die "set-field: need --value <v>"
  local body
  body="$(jq -cn --arg v "$value" '{value:$v}')"
  req POST "/task/${task}/field/${field}" "$body" >/dev/null
  echo "FIELD-SET ${task} ${field} = ${value}"
}

cmd_del_field() {
  local task="" field=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)  task="$2";  shift 2;;
      --field) field="$2"; shift 2;;
      *) die "del-field: unknown flag $1";;
    esac
  done
  [[ -z "$task"  ]] && die "del-field: need --task <id>"
  [[ -z "$field" ]] && die "del-field: need --field <field_id>"
  req DELETE "/task/${task}/field/${field}" >/dev/null
  echo "FIELD-CLEARED ${task} ${field}"
}

cmd_comment() {
  # `comment_text` alone leaves **markdown** literal in ClickUp clients. With
  # --markdown we convert the text through lib/md2quill.py and send a Quill-style
  # `comment` array — that DOES render bold/italic/code/lists/links in the UI.
  local task="" text="" notify="false" markdown="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)     task="$2"; shift 2;;
      --text)     text="$2"; shift 2;;
      --notify)   notify="true"; shift;;
      --markdown) markdown="true"; shift;;
      *) die "comment: unknown flag $1";;
    esac
  done
  [[ -z "$task" ]] && die "comment: need --task <id>"
  [[ -z "$text" ]] && die "comment: need --text \"...\""
  # Delivery gate: a worker whose commits never reached origin/main must not be able
  # to publish `outcome: done`. The logic is backend-agnostic (scripts/lib/delivery-guard.sh)
  # and is enforced here too, because /done posts through this CLI directly.
  delivery_guard_check "$text" || die "comment: refused by the delivery guard (see above)"
  local body
  if [[ "$markdown" == "true" ]]; then
    local quill
    quill="$(printf '%s' "$text" | python3 "${SCRIPT_DIR}/lib/md2quill.py")"
    # The Quill `comment` array is the canonical content; ClickUp derives the
    # displayed text from it. Sending the raw markdown ALSO in `comment_text`
    # makes ClickUp store BOTH and return them concatenated on read (doubled
    # body). Send comment_text empty.
    body="$(jq -cn --argjson c "$quill" --argjson n "$notify" '{comment_text:"", comment:$c, notify_all:$n}')"
  else
    body="$(jq -cn --arg t "$text" --argjson n "$notify" '{comment_text:$t, notify_all:$n}')"
  fi
  req POST "/task/${task}/comment" "$body" >/dev/null
  echo "COMMENTED ${task}"
}

cmd_comments() {
  local task="" json="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2;;
      --json) json="true"; shift;;
      *) die "comments: unknown flag $1";;
    esac
  done
  [[ -z "$task" ]] && die "comments: need --task <id>"
  if [[ "$json" == "true" ]]; then
    # Raw objects ascending by date with the fields useful for filtering:
    # id (for reply), resolved (true|false|null), assignee.id/username,
    # user.id/username, reply_count, date, comment_text. resolved=null = a plain
    # unassigned comment.
    req GET "/task/${task}/comment" \
      | jq -c '.comments | sort_by(.date|tonumber) | .[] |
          {id, resolved, assignee_id:(.assignee.id // null),
           assignee:(.assignee.username // null),
           user_id:(.user.id // null), user:(.user.username // null),
           reply_count, date, comment_text}'
  else
    req GET "/task/${task}/comment" \
      | jq -r '.comments | reverse | .[] | "[\(.date)] \(.user.username): \(.comment_text)"'
  fi
}

cmd_reply_comment() {
  # Reply IN an existing comment thread (POST /comment/{comment_id}/reply). Without
  # --markdown sends plain comment_text; with --markdown sends a Quill array via
  # md2quill.py (renders bold/italic/code/lists/links), like `comment`.
  local comment="" text="" notify="false" markdown="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --comment)  comment="$2"; shift 2;;
      --text)     text="$2"; shift 2;;
      --notify)   notify="true"; shift;;
      --markdown) markdown="true"; shift;;
      *) die "reply-comment: unknown flag $1";;
    esac
  done
  [[ -z "$comment" ]] && die "reply-comment: need --comment <comment_id>"
  [[ -z "$text" ]] && die "reply-comment: need --text \"...\""
  local body
  if [[ "$markdown" == "true" ]]; then
    local quill
    quill="$(printf '%s' "$text" | python3 "${SCRIPT_DIR}/lib/md2quill.py")"
    # Quill `comment` array is canonical; sending raw markdown in `comment_text`
    # too makes ClickUp return the body doubled on read (see cmd_comment note).
    body="$(jq -cn --argjson c "$quill" --argjson n "$notify" '{comment_text:"", comment:$c, notify_all:$n}')"
  else
    body="$(jq -cn --arg t "$text" --argjson n "$notify" '{comment_text:$t, notify_all:$n}')"
  fi
  req POST "/comment/${comment}/reply" "$body" >/dev/null
  echo "REPLIED ${comment}"
}

cmd_comment_replies() {
  local comment=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --comment) comment="$2"; shift 2;;
      *) die "comment-replies: unknown flag $1";;
    esac
  done
  [[ -z "$comment" ]] && die "comment-replies: need --comment <comment_id>"
  req GET "/comment/${comment}/reply" \
    | jq -r '.comments | sort_by(.date|tonumber) | .[] | "[\(.date)] \(.user.username): \(.comment_text)"'
}

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  [[ $# -eq 0 ]] && { usage; exit 1; }
  local sub="$1"; shift || true
  # help does not require a token
  case "$sub" in -h|--help|help) usage; exit 0;; esac
  resolve_token
  case "$sub" in
    create)    cmd_create "$@";;
    get-list)  cmd_get_list "$@";;
    dashboard) cmd_dashboard "$@";;
    update)    cmd_update "$@";;
    get)       cmd_get "$@";;
    set-field) cmd_set_field "$@";;
    del-field) cmd_del_field "$@";;
    comment)        cmd_comment "$@";;
    comments)       cmd_comments "$@";;
    reply-comment)  cmd_reply_comment "$@";;
    comment-replies) cmd_comment_replies "$@";;
    -h|--help|help) usage;;
    *) die "unknown subcommand '$sub' (create|get-list|dashboard|update|get|set-field|del-field|comment|comments|reply-comment|comment-replies)";;
  esac
}

main "$@"
