#!/bin/bash
# worker-supervisor.sh — ONE consolidated tick that supervises every worker.
#
# Replaces three previously-overlapping watchers:
#   worker-timeout-janitor.sh   (*/1)  — wall-clock cap + state-aware flip
#   worker-progress-watchdog.sh (*/2)  — startup-dialog Enter + pane-stall kill
#   worker-collector-tick.sh    (*/5)  — orphan sweep (in_progress + no tmux)
# and folds in the per-spawn worker-startup-dialog-guard.sh (same regex+Enter).
#
# crash-detector.sh (if present) stays SEPARATE — it is a cross-attempt circuit
# breaker over historical memory/worker-errors/*.log (different job, cadence */15).
#
# WHY consolidate: the three watchers split kill-authority three ways (janitor
# by age, watchdog by stall, collector by reset) and janitor(*/1)+watchdog(*/2)
# could both hit the same session in the same minute; only janitor was
# idempotent. Here there is ONE kill-authority and ONE idempotency guard.
#
# ── Part A: per live `worker-*` tmux session, in strict priority order ────────
#   1. terminal-status no-op  — ClickUp already in_review/done/… → worker
#                               finished; just release the slot, never re-flip.
#   2. dialog Enter           — pane shows a blocking startup dialog → send
#                               Enter (default = Continue), alert once.
#   3. wall-cap state-flip    — age >= per-worker cap → classify last comments
#                               (done→in_review / awaiting→on_hold /
#                               1st→todo requeue / 2nd→blocked) → kill.
#   4. pane-stall escalate    — pane hash unchanged > STALL_MIN → strike1 Enter,
#                               strike2 kill-for-respawn (unless ClickUp
#                               in_progress → alert-only, long real work).
# Each phase ends the session's turn (one action per session per tick) → no
# double-kill, no two authorities racing on one session.
#
# ── Part B: orphan sweep (ClickUp in_progress whose slug has NO live session) ─
#   2-strike damper + stale-heartbeat (600s) → reset to todo so launch re-picks.
#   "claude booted?" is read from the logs/workers/<slug>/session-launched
#   marker (written by spawn-worker.sh right after `tmux new-session`), NOT from
#   the retired startup-dialog-guard.log.
#
# Cadence: every minute via routines/worker-supervisor.yaml (tightest of the
# three it replaces, preserving dialog/wall-cap responsiveness).
#
# Tunables (env): SUPERVISOR_SESSION_FILTER, WORKER_TIMEOUT_MIN,
#   SUPERVISOR_STALL_MIN, SUPERVISOR_STALL_SEC, SUPERVISOR_MIN_AGE_SEC,
#   SUPERVISOR_DIALOG_GRACE_SEC, SUPERVISOR_STALE_HEARTBEAT_SEC,
#   SUPERVISOR_NOTIFY_CMD, SUPERVISOR_STATE_DIR, SUPERVISOR_SKIP_ORPHAN.

set -uo pipefail

export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"

# Repo root — resolve from this script's location unless REPO_ROOT overrides it.
REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CAP_MIN="${WORKER_TIMEOUT_MIN:-45}"
SESSION_FILTER="${SUPERVISOR_SESSION_FILTER:-^worker-}"
STALL_MIN="${SUPERVISOR_STALL_MIN:-5}"
STALL_SEC="${SUPERVISOR_STALL_SEC:-$(( STALL_MIN * 60 ))}"
MIN_AGE_SEC="${SUPERVISOR_MIN_AGE_SEC:-180}"
DIALOG_GRACE_SEC="${SUPERVISOR_DIALOG_GRACE_SEC:-45}"
STALE_HEARTBEAT_SEC="${SUPERVISOR_STALE_HEARTBEAT_SEC:-600}"
# Optional operator-notification hook — not shipped by the template; calls are
# existence-guarded below so its absence is a safe no-op.
NOTIFY_CMD="${SUPERVISOR_NOTIFY_CMD:-${REPO}/scripts/notify-operator.sh}"
STATE_DIR="${SUPERVISOR_STATE_DIR:-${REPO}/memory/health/worker-supervisor}"
CLICKUP="${REPO}/scripts/clickup/clickup.sh"

NOW=$(date +%s)
ACTIVITY_LOG="${REPO}/memory/worker-activity/$(date +%Y-%m).log"
LOG_DIR="/var/log/agent-os"
LOG_FILE="$LOG_DIR/worker-supervisor.log"

mkdir -p "$STATE_DIR" "$(dirname "$ACTIVITY_LOG")" "$LOG_DIR" 2>/dev/null || true

# Known startup blockers (case-insensitive). Superset of the retired
# worker-startup-dialog-guard.sh regex — all need a single Enter to clear.
DIALOG_RE='Settings Warning|Found invalid settings|invalid settings|Loading development channels|I am using this for local development|Enter to confirm|press enter to continue|❯ 1\.|1\. Continue|1\. Yes|Do you want to proceed|Choose the text style|Select (login|theme)|Dark mode.*Light mode'

# ── ClickUp token (once) ─────────────────────────────────────────────────────
ENV_FILE="${AGENT_OS_ENV_FILE:-/etc/agent-os/agent-os.env}"
if [[ -z "${CLICKUP_API_TOKEN:-}${CLICKUP_PERSONAL_TOKEN:-}" && -r "$ENV_FILE" ]]; then
  set +u; source "$ENV_FILE" 2>/dev/null || true; set -u
fi
TOKEN="${CLICKUP_API_TOKEN:-${CLICKUP_PERSONAL_TOKEN:-}}"
# ClickUp team/space scoping for the orphan sweep — from env, no baked-in ids.
TEAM_ID="${CLICKUP_TEAM_ID:-}"
SPACE_ID="${CLICKUP_SPACE_ID:-}"

log()      { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
activity() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$ACTIVITY_LOG" 2>/dev/null || true; }

# op_notify <notify-cmd args...> — run the operator hook only if it exists.
op_notify() {
  [ -x "$NOTIFY_CMD" ] && "$NOTIFY_CMD" "$@" 2>/dev/null || true
}

alert() {
  local sev="$1"; shift
  op_notify --source worker-supervisor --severity "$sev" --msg "$*"
  log "ALERT[$sev] $*"
}

# fetch_status <task_id> → lowercased ClickUp status, spaces→underscores ("").
fetch_status() {
  local task_id="$1"
  [[ -z "$TOKEN" || -z "$task_id" ]] && { echo ""; return; }
  curl -sSf -H "Authorization: ${TOKEN}" \
    "https://api.clickup.com/api/v2/task/${task_id}" 2>/dev/null \
    | python3 -c "
import json,sys
try: print(str(json.load(sys.stdin).get('status',{}).get('status','')).strip().lower().replace(' ','_'))
except Exception: print('')
" 2>/dev/null || echo ""
}

# fetch_comments_text <task_id> → JSON array of comment texts (oldest-first).
fetch_comments_text() {
  local task_id="$1"
  [[ -z "$TOKEN" || -z "$task_id" ]] && { echo "[]"; return; }
  curl -sSf -H "Authorization: ${TOKEN}" \
    "https://api.clickup.com/api/v2/task/${task_id}/comment" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    cs=sorted(json.load(sys.stdin).get('comments',[]),key=lambda c:int(c.get('date','0')))
    print(json.dumps([c.get('comment_text','') for c in cs]))
except Exception: print('[]')
" 2>/dev/null || echo "[]"
}

# comments_have_done <comments_json> → "1" if one of the last 4 comments carries
# the worker's own `outcome: done` marker, else "0". A finished worker always
# posts that line before /done, so it is the ground truth for "the work is
# over" even when the task status was never flipped.
comments_have_done() {
  python3 -c "
import json,sys
texts=json.loads(sys.argv[1]); recent=texts[-4:] if len(texts)>=4 else texts
for t in recent:
    if 'outcome: done' in t or 'outcome:done' in t: print('1'); sys.exit(0)
print('0')" "$1" 2>/dev/null || echo "0"
}

# comments_have_awaiting <comments_json> → "yes" if one of the last 3 comments
# carries an awaiting-the-owner marker (the worker did its part and parked the
# task on a human decision), else "no".
comments_have_awaiting() {
  python3 -c "
import json,sys
texts=json.loads(sys.argv[1]); recent=texts[-3:] if len(texts)>=3 else texts
for t in recent:
    for m in ['⏳ **Awaiting','Awaiting decision','Awaiting owner','⏳ Awaiting']:
        if m in t: print('yes'); sys.exit(0)
print('no')" "$1" 2>/dev/null || echo "no"
}

# ── Part A — supervise live worker sessions ──────────────────────────────────
SESSIONS=$(tmux ls 2>/dev/null | cut -d: -f1 | grep -E "$SESSION_FILTER" || true)

if [ -n "$SESSIONS" ]; then
while IFS= read -r sess; do
  [ -z "$sess" ] && continue

  created=$(tmux display-message -p -t "$sess" '#{session_created}' 2>/dev/null || echo 0)
  [ "$created" = "0" ] && continue
  age_sec=$(( NOW - created ))
  age_min=$(( age_sec / 60 ))

  slug="${sess#worker-}"
  worker_dir="${REPO}/logs/workers/${slug}"
  clickup_task_id=$(cat "${worker_dir}/clickup-task-id" 2>/dev/null || echo "")

  # ── Phase 1: terminal-status no-op (idempotency guard) ─────────────────────
  # The worker may have already finished (/done set in_review) just before this
  # tick — its self-kill races us. Never re-flip a terminal/review status; just
  # release the slot. Re-running must be a no-op on these statuses.
  if [ -n "$clickup_task_id" ]; then
    st=$(fetch_status "$clickup_task_id")
    case "$st" in
      in_review|done|complete|completed|closed|approved|cancelled|canceled)
        activity "supervisor: $sess ClickUp '${st}' terminal — worker finished, releasing slot (no flip)"
        tmux kill-session -t "$sess" 2>/dev/null || true
        rm -f "$STATE_DIR/${sess}.state" 2>/dev/null || true
        continue
        ;;
    esac
  fi

  # ── Phase 1b: singleton (DAG-launched) completion no-op ────────────────────
  # A DAG-launched singleton (e.g. a strategist) carries a sentinel
  # clickup-task-id (literal "strategist", or empty) — fetch_status 404s → '',
  # so Phase 1 above can't see its completion. It then sits idle at a finished
  # prompt with a static pane and Phase 4 fires a false "stalled → KILL for
  # respawn" alert (nothing respawns it; the DAG already ran). Detect completion
  # the way the singleton actually records it: last-run.md `status: done`
  # written AFTER this session started (mtime >= session_created is the
  # freshness guard — a stale prior-day last-run.md must NOT kill a fresh run).
  # Real workers always have a numeric ClickUp id, so they skip this.
  if [ -z "$clickup_task_id" ] || [ "$clickup_task_id" = "strategist" ]; then
    lastrun="${worker_dir}/last-run.md"
    if [ -f "$lastrun" ]; then
      lr_mtime=$(stat -c %Y "$lastrun" 2>/dev/null || echo 0)
      if [ "$lr_mtime" -ge "$created" ] && grep -qE '^status:[[:space:]]*done' "$lastrun" 2>/dev/null; then
        activity "supervisor: $sess last-run.md status:done (fresh) — singleton finished, releasing slot (no flip, no alert)"
        tmux kill-session -t "$sess" 2>/dev/null || true
        rm -f "$STATE_DIR/${sess}.state" 2>/dev/null || true
        continue
      fi
    fi
  fi

  # Capture visible pane; hash the tail (last 25 lines) to detect a repaint.
  pane=$(tmux capture-pane -p -t "$sess" 2>/dev/null || true)
  tail=$(printf '%s' "$pane" | tail -n 25)
  hash=$(printf '%s' "$tail" | sha256sum 2>/dev/null | awk '{print $1}')

  prev_hash=""; hash_since="$NOW"; strikes=0; stall_alerted=0; dialog_alerted=0; inprogress_alerted=0
  statefile="$STATE_DIR/${sess}.state"
  if [ -f "$statefile" ]; then . "$statefile" 2>/dev/null || true; fi
  write_state() {
    {
      echo "prev_hash='${hash}'"
      echo "hash_since='${hash_since}'"
      echo "strikes='${strikes}'"
      echo "stall_alerted='${stall_alerted}'"
      echo "dialog_alerted='${dialog_alerted}'"
      echo "inprogress_alerted='${inprogress_alerted}'"
    } > "$statefile" 2>/dev/null || true
  }

  # ── Phase 2: startup-dialog detector (folds in startup-dialog-guard) ───────
  if [ "$age_sec" -ge "$DIALOG_GRACE_SEC" ] && printf '%s' "$tail" | grep -qiE "$DIALOG_RE"; then
    tmux send-keys -t "$sess" Enter 2>/dev/null || true
    if [ "${dialog_alerted:-0}" != "1" ]; then
      alert warn "worker ${slug} was stuck on a startup dialog — auto-Enter (Continue)"
      activity "supervisor: $sess startup-dialog → auto-Enter"
      dialog_alerted=1
    fi
    hash_since="$NOW"; strikes=0; stall_alerted=0; inprogress_alerted=0   # recovering — reset stall
    write_state
    continue
  fi
  dialog_alerted=0

  # ── Phase 3: wall-cap state-flip (single kill-authority for the cap) ───────
  cap_min="$CAP_MIN"
  per_cap=$(cat "${worker_dir}/timeout-min" 2>/dev/null || echo "")
  if [[ "$per_cap" =~ ^[0-9]+$ ]] && [ "$per_cap" -gt 0 ]; then cap_min="$per_cap"; fi

  if [ "$age_min" -ge "$cap_min" ]; then
    activity "supervisor: timing out $sess (age=${age_min}min cap=${cap_min}min clickup=${clickup_task_id:-?})"
    if [ -n "$clickup_task_id" ]; then
      comments_json=$(fetch_comments_text "$clickup_task_id")
      has_awaiting=$(comments_have_awaiting "$comments_json")
      has_done=$(comments_have_done "$comments_json")

      if [ "$has_done" -gt 0 ]; then
        activity "supervisor: $clickup_task_id has outcome:done — setting in_review"
        "$CLICKUP" comment --task "$clickup_task_id" --text "⏱ Janitor timeout (${age_min}min): worker session killed. Last comment shows outcome:done — setting in_review for the owner." 2>/dev/null || true
        "$CLICKUP" update --task "$clickup_task_id" --status in_review 2>/dev/null || true
        op_notify --source worker-supervisor --severity info --msg "worker ${slug} timeout (${age_min}min) — ClickUp ${clickup_task_id} had outcome:done → in_review"
      elif [ "$has_awaiting" = "yes" ]; then
        activity "supervisor: $clickup_task_id awaiting marker — setting on_hold"
        "$CLICKUP" comment --task "$clickup_task_id" --text "⏱ Janitor timeout (${age_min}min): worker session killed. Task had awaiting-owner marker — setting on_hold (not blocked). The owner's decision pending." 2>/dev/null || true
        "$CLICKUP" update --task "$clickup_task_id" --status on_hold 2>/dev/null || true
        op_notify --source worker-supervisor --severity info --msg "worker ${slug} timeout (${age_min}min) — ClickUp ${clickup_task_id} was awaiting owner → on_hold"
      else
        prior_timeouts=$(python3 -c "
import json,sys
texts=json.loads(sys.argv[1])
print(sum(1 for t in texts if 'Janitor timeout' in t and ('requeued' in t or 'blocked' in t or 'Timeout 1/2' in t or 'Timeout 2/2' in t)))" "$comments_json" 2>/dev/null || echo "0")
        if [ "$prior_timeouts" -lt 1 ]; then
          activity "supervisor: $clickup_task_id first timeout → requeued as todo"
          "$CLICKUP" comment --task "$clickup_task_id" --text "⏱ Janitor timeout (${age_min}min): Timeout 1/2, requeued. Worker exceeded the ${cap_min}-minute cap without finishing. Setting status back to todo for re-pick. If this timeout repeats, next time will be blocked." 2>/dev/null || true
          "$CLICKUP" update --task "$clickup_task_id" --status todo 2>/dev/null || true
          op_notify --source worker-supervisor --severity warn --msg "worker ${slug} timeout 1/2 (${age_min}min) — ClickUp ${clickup_task_id} → todo (requeued, next timeout → blocked)"
        else
          activity "supervisor: $clickup_task_id prior_timeouts=${prior_timeouts} → blocked"
          "$CLICKUP" comment --task "$clickup_task_id" --text "⏱ Janitor timeout (${age_min}min): Timeout 2/2, blocked. Worker timed out again after requeue. Needs manual investigation before re-queue: set status back to \`todo\` after fixing the root cause." 2>/dev/null || true
          "$CLICKUP" update --task "$clickup_task_id" --status blocked 2>/dev/null || true
          op_notify --source worker-supervisor --severity warn --msg "worker ${slug} timeout 2/2 (${age_min}min) — ClickUp ${clickup_task_id} → blocked (repeated timeout)"
        fi
      fi
    fi
    tmux kill-session -t "$sess" 2>/dev/null || true
    rm -f "$statefile" 2>/dev/null || true
    continue
  fi

  # ── Phase 4: pane-stall escalate ───────────────────────────────────────────
  if [ "$hash" = "$prev_hash" ]; then
    unchanged=$(( NOW - hash_since ))
    if [ "$unchanged" -ge "$STALL_SEC" ] && [ "$age_sec" -ge "$MIN_AGE_SEC" ]; then
      # ── Phase 4a: DAG-launched singleton guard ─────────────────────────────
      # A singleton (sentinel clickup-task-id "strategist" / empty) runs ONE
      # long QUIET model analysis turn by design → a static pane is expected,
      # NOT a hang. Phase 1b only releases AFTER last-run.md status:done is
      # written; on a longer run the quiet turn can outlast the 5-min stall
      # window before done is written, so a naive strike2 would KILL a
      # legitimately-working singleton. The "respawn" is fictional (nobody
      # respawns a DAG-launched singleton — it starts from cron), and the
      # strike1 auto-Enter injects a stray keystroke mid-analysis. So for
      # singletons: never Enter, never kill on pane-stall — the wall-cap
      # (Phase 3, timeout-min) is the sole kill-authority for a genuine hang.
      if [ -z "$clickup_task_id" ] || [ "$clickup_task_id" = "strategist" ]; then
        if [ "${stall_alerted:-0}" != "1" ]; then
          alert info "singleton ${slug} quiet >${STALL_MIN}min — long model turn, leaving it (wall-cap = kill-authority)"
          activity "supervisor: $sess singleton stall (${unchanged}s) → watch-only (no Enter, no kill; wall-cap handles real hang)"
          stall_alerted=1
        fi
        write_state
        continue
      fi
      strikes=$(( strikes + 1 ))
      if [ "$strikes" -le 1 ]; then
        tmux send-keys -t "$sess" Enter 2>/dev/null || true
        if [ "${stall_alerted:-0}" != "1" ]; then
          alert warn "worker ${slug}: zero progress >${STALL_MIN}min — auto-Enter, watching"
          activity "supervisor: $sess stall (${unchanged}s) → strike1 auto-Enter"
          stall_alerted=1
        fi
      else
        status=$(fetch_status "$clickup_task_id")
        if [ "$status" = "in_progress" ]; then
          # Static pane + in_progress past the stall window is more often a GHOST
          # than a hang: a worker that finished its work (and committed) but whose
          # /done never flipped the status. The old branch alerted "check manually"
          # on EVERY tick forever for that case. So first try to RESOLVE it from
          # the worker's own comments — outcome:done → in_review, awaiting-marker →
          # on_hold — and release the session either way (spawn-worker's orphan GC
          # reaps the worktree on its next tick). Only a genuine unknown falls
          # through, and that alerts ONCE (guard) then stays watch-only: the
          # wall-cap (Phase 3) remains the sole kill-authority, which is what
          # protects a legitimately long quiet model turn.
          comments_json=$(fetch_comments_text "$clickup_task_id")
          gh_done=$(comments_have_done "$comments_json")
          gh_awaiting=$(comments_have_awaiting "$comments_json")
          if [ "${gh_done:-0}" = "1" ]; then
            activity "supervisor: $sess static+in_progress but outcome:done in comments → in_review + kill (ghost cleanup)"
            "$CLICKUP" comment --task "$clickup_task_id" --text "🧹 Supervisor: pane static >${STALL_MIN}min, task still in_progress, but the last comment shows outcome:done — the worker finished and /done never flipped the status. Setting in_review and releasing the session (worktree GC'd on the next spawn tick)." 2>/dev/null || true
            "$CLICKUP" update --task "$clickup_task_id" --status in_review 2>/dev/null || true
            alert info "worker ${slug} finished (outcome:done) but was stuck in_progress — auto-flipped to in_review, slot released"
            tmux kill-session -t "$sess" 2>/dev/null || true
            rm -f "$statefile" 2>/dev/null || true
            continue
          elif [ "$gh_awaiting" = "yes" ]; then
            activity "supervisor: $sess static+in_progress but awaiting marker → on_hold + kill"
            "$CLICKUP" comment --task "$clickup_task_id" --text "🧹 Supervisor: pane static >${STALL_MIN}min, task in_progress, awaiting-owner marker in the comments — setting on_hold and releasing the session." 2>/dev/null || true
            "$CLICKUP" update --task "$clickup_task_id" --status on_hold 2>/dev/null || true
            alert info "worker ${slug} is awaiting the owner but was stuck in_progress — auto-flipped to on_hold, slot released"
            tmux kill-session -t "$sess" 2>/dev/null || true
            rm -f "$statefile" 2>/dev/null || true
            continue
          fi
          if [ "${inprogress_alerted:-0}" != "1" ]; then
            alert warn "worker ${slug} quiet >${STALL_MIN}min, task=in_progress, no outcome:done — watching (wall-cap kills a real hang)"
            activity "supervisor: $sess stall but ClickUp in_progress, no outcome → alert-once + watch-only (wall-cap = kill-authority)"
            inprogress_alerted=1
          fi
          strikes=1   # stay in watch mode, don't re-escalate every tick
        else
          alert error "worker ${slug} stalled >${STALL_MIN}min (ClickUp='${status:-?}') — killed for respawn"
          activity "supervisor: $sess stall (${unchanged}s, ClickUp='${status:-?}') → KILL for respawn"
          tmux kill-session -t "$sess" 2>/dev/null || true
          rm -f "$statefile" 2>/dev/null || true
          continue
        fi
      fi
    fi
    write_state   # keep original hash_since (do NOT reset to NOW)
  else
    hash_since="$NOW"; strikes=0; stall_alerted=0; inprogress_alerted=0
    write_state
    log "ok: $sess healthy (pane changed, age=$(( age_sec / 60 ))min)"
  fi
done <<< "$SESSIONS"
fi

# ── Part B — orphan sweep (in_progress + no live session) ─────────────────────
if [ "${SUPERVISOR_SKIP_ORPHAN:-0}" != "1" ]; then
ERRORS_DIR="${REPO}/memory/worker-errors"
mkdir -p "$ERRORS_DIR" 2>/dev/null || true
python3 - "$ERRORS_DIR" "$REPO" "$STALE_HEARTBEAT_SEC" "$TOKEN" "$TEAM_ID" "$SPACE_ID" <<'PYEOF'
import datetime, json, pathlib, re, subprocess, sys, time, urllib.request

ERRORS_DIR, REPO, STALE, TOKEN, TEAM_ID, SPACE_ID = sys.argv[1:7]
STALE = int(STALE)

# slugify — prefer the repo helper if present, else a safe built-in fallback so
# the sweep still works when scripts/lib/slugify.py is not shipped.
sys.path.insert(0, f"{REPO}/scripts/lib")
try:
    from slugify import slugify   # single source of truth when available
except Exception:
    def slugify(s):
        s = (s or "").strip().lower()
        s = re.sub(r"[^a-z0-9]+", "-", s)
        return s.strip("-")

LOG = f"{ERRORS_DIR}/{datetime.datetime.now().strftime('%Y-%m')}.log"

if not TOKEN or not TEAM_ID or not SPACE_ID:
    print("[worker-supervisor] missing ClickUp token/team/space — skipping orphan sweep", file=sys.stderr)
    sys.exit(0)

# Active tmux worker sessions
try:
    sessions = subprocess.check_output(["tmux", "ls"], text=True, stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    sessions = ""
active_slugs = {ln.split(":", 1)[0][len("worker-"):] for ln in sessions.splitlines() if ln.startswith("worker-")}

# ClickUp tasks currently in_progress — ALL pages, not just page=0 (a silent
# cap is silent data-loss): previously orphan zombies beyond the first hundred
# in_progress tasks were invisible to the sweep forever, without a single log line.
rows, page, capped = [], 0, False
while True:
    url = f"https://api.clickup.com/api/v2/team/{TEAM_ID}/task?space_ids[]={SPACE_ID}&statuses[]=in_progress&include_closed=false&page={page}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": TOKEN}), timeout=15) as resp:
            batch = json.loads(resp.read()).get("tasks", [])
    except Exception as e:
        print(f"[worker-supervisor] ClickUp API error: {e} — sweep skipped", file=sys.stderr)
        sys.exit(0)
    rows += batch
    if len(batch) < 100:
        break
    page += 1
    if page >= 20:
        capped = True
        print(f"[worker-supervisor] capped: pagination stopped at 20 pages, "
              f"{len(rows)} tasks fetched, remainder DROPPED — orphan sweep INCOMPLETE", file=sys.stderr)
        break

ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
now = time.time()

for r in rows:
    slug = slugify(r["name"])
    worker_dir = pathlib.Path(REPO) / "logs" / "workers" / slug
    strike = worker_dir / "orphan-strike"

    if slug in active_slugs:
        strike.unlink(missing_ok=True)
        continue

    heartbeat = worker_dir / "heartbeat"
    if heartbeat.is_file() and (now - heartbeat.stat().st_mtime) < STALE:
        # Heartbeat fresh — session likely alive (namespace divergence). Clear strike.
        strike.unlink(missing_ok=True)
        continue

    # No live session and heartbeat stale. 2-strike damper: reset only after the
    # absence is confirmed two consecutive ticks.
    task_id = r["id"]
    if not strike.exists():
        worker_dir.mkdir(parents=True, exist_ok=True)
        strike.touch()
        print(f"[worker-supervisor] orphan-strike 1/2 for {slug} (clickup#{task_id})", file=sys.stderr)
        continue

    strike.unlink(missing_ok=True)

    # Classify the failure while the worker dir still reflects THIS attempt.
    # "claude booted?" signal comes from the session-launched marker that
    # spawn-worker.sh writes right after `tmux new-session`
    # (present ⇒ got past pre-flight, tmux session created;
    # absent ⇒ spawn-time failure: settings pre-flight exit, tmux failure, etc.).
    if (worker_dir / "session-launched").is_file():
        cause = "died mid-run (booted, session lost)"
    else:
        cause = "spawn-failed: claude never booted (no session-launched marker)"

    _data = json.dumps({"status": "todo"}).encode()
    _req = urllib.request.Request(
        f"https://api.clickup.com/api/v2/task/{task_id}",
        data=_data, headers={"Authorization": TOKEN, "Content-Type": "application/json"}, method="PUT")
    put_ok = False
    try:
        urllib.request.urlopen(_req, timeout=10); put_ok = True
    except Exception as e:
        print(f"[worker-supervisor] reset failed for {task_id}: {e}", file=sys.stderr)

    with open(LOG, "a") as f:
        if put_ok:
            # Format MUST match what crash-detector.sh parses ("crashed" + clickup#<id>).
            f.write(f"{ts} | {slug} | crashed: orphan reset (clickup#{task_id}, no tmux, heartbeat stale) | {cause}\n")
        else:
            f.write(f"{ts} | {slug} | reset-failed: PUT error, task still in_progress (clickup#{task_id}) | {cause}\n")

# A capped (incomplete) sweep MUST be visible from the outside: exit 3 → scheduler goes red.
sys.exit(3 if capped else 0)
PYEOF
ORPHAN_RC=$?
fi

exit "${ORPHAN_RC:-0}"
