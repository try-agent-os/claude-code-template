#!/bin/bash
# worker-launcher-tick.sh — Dagu DAG entry: pick the next todo task and launch a worker.
#
# Token-free launcher (pure bash + Python, no LLM). Replaces the old LLM
# dispatcher that decided-and-launched stream workers each cycle. Reads todo
# tasks from the task backend (ClickUp, the reference backend), applies the slot
# rules, fills the worker prompt template, and spawns ONE interactive worker via
# scripts/spawn-worker.sh, then marks the task in_progress.
#
# Task backend config (env, typically from the AgentOS env file):
#   CLICKUP_PERSONAL_TOKEN   — ClickUp API v2 token (required)
#   CLICKUP_TEAM_ID          — ClickUp team/workspace id (required)
#   CLICKUP_SPACE_ID         — space to scope the task query to (optional)
#
# Algorithm:
#   0. worker-preflight.sh gate (settings valid / tmux reachable / optional dep hook)
#   1. tmux worker cap (token economy)
#   2. GET todo tasks → keep only tasks tagged `auto-worker` (the safety valve:
#      judgment/personal tasks without the tag are never auto-grabbed).
#      "Scheduled:"-prefixed system tasks bypass the tag check.
#   3. Pick the most urgent pickable task (lowest ClickUp priority id)
#   4. Compute slug + model, fill worker-prompt-template.md
#   5. exec scripts/spawn-worker.sh
#   6. Mark the task in_progress (only if the launch succeeded)
#   7. Notify the operator iff this was a user task (not "Scheduled:")

set -uo pipefail

export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LAUNCHER="$REPO/scripts/spawn-worker.sh"
TEMPLATE="$REPO/agents/heartbeat/worker-prompt-template.md"
NOTIFY="$REPO/scripts/notify-operator.sh"
ENV_FILE="${AGENT_OS_ENV_FILE:-/etc/agent-os/agent-os.env}"
WORKER_CAP="${WORKER_CAP:-10}"

# 0) Global preflight gate. Any failure → skip this tick (exit 0 for Dagu).
if [ -x "$REPO/scripts/worker-preflight.sh" ]; then
  if ! bash "$REPO/scripts/worker-preflight.sh"; then
    exit 0
  fi
fi

# 1) Worker cap
active=$(tmux ls 2>/dev/null | grep -c '^worker-' || true)
if [ "${active:-0}" -ge "$WORKER_CAP" ]; then
  exit 0
fi

# 2-7) Pick + launch (Python for JSON + template substitution)
python3 - "$LAUNCHER" "$TEMPLATE" "$NOTIFY" "$REPO" "$ENV_FILE" <<'PYEOF'
import json, os, pathlib, re, subprocess, sys, tempfile, urllib.request
from datetime import datetime, timedelta, timezone

LAUNCHER, TEMPLATE, NOTIFY, REPO, ENV_FILE = sys.argv[1:6]

# Drain safety-gate. Enforcement is tag-based and lives in exactly one place so
# that task generators and this launcher can never disagree about what a human
# still has to look at. See scripts/lib/needs_human.py.
sys.path.insert(0, os.path.join(REPO, "scripts", "lib"))
from needs_human import is_manual_gated

# --- Task backend config (env, with env-file fallback) ---
def _from_env_file(key):
    try:
        with open(ENV_FILE) as f:
            for line in f:
                if line.startswith(key + "="):
                    return line.strip().split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return None

TOKEN = os.environ.get("CLICKUP_PERSONAL_TOKEN") or _from_env_file("CLICKUP_PERSONAL_TOKEN")
TEAM_ID = os.environ.get("CLICKUP_TEAM_ID") or _from_env_file("CLICKUP_TEAM_ID")
SPACE_ID = os.environ.get("CLICKUP_SPACE_ID") or _from_env_file("CLICKUP_SPACE_ID")

if not TOKEN or not TEAM_ID:
    print("[worker-launcher] CLICKUP_PERSONAL_TOKEN / CLICKUP_TEAM_ID not set — nothing to pick", file=sys.stderr)
    sys.exit(0)

# Fetch todo tasks. include_subtasks=true so nested urgent/high subtasks are
# pickable (otherwise the Team API returns only top-level tasks and the queue
# looks empty when all eligible work is nested).
url = (f"https://api.clickup.com/api/v2/team/{TEAM_ID}/task?"
       f"statuses[]=todo&include_closed=false&include_subtasks=true&page=0")
if SPACE_ID:
    url += f"&space_ids[]={SPACE_ID}"
req = urllib.request.Request(url, headers={"Authorization": TOKEN})
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        todo = json.loads(resp.read()).get("tasks", [])
except Exception as e:
    print(f"[worker-launcher] task backend API error: {e}", file=sys.stderr)
    sys.exit(0)

if not todo:
    sys.exit(0)

def pickable(t: dict) -> bool:
    name = t.get("name", "")
    raw_tags = t.get("tags", [])
    tag_names = {(tag["name"] if isinstance(tag, dict) else tag) for tag in raw_tags}
    # HUMAN GATE: `needs-human` (or `manual-only`) opts a task back OUT, even
    # when it carries `auto-worker`. Generators stamp the tag on tasks a person
    # must see first; removing the tag after review releases the task.
    # Checked FIRST, before every other branch, so that it holds for `Scheduled:`
    # tasks too — a gate with an exception is not a gate, and the exception would
    # be silent.
    if is_manual_gated(name, tag_names):
        return False
    # START-DATE GATE: a task with a future start_date is deferred — skipped
    # until that wall-clock moment, then drained normally. Lets a task self-
    # activate at a set time without a one-shot cron. start_date is epoch-ms
    # (string) or null/absent; malformed → ignore the gate.
    sd = t.get("start_date")
    if sd:
        try:
            if int(sd) > int(datetime.now(timezone.utc).timestamp() * 1000):
                return False
        except (TypeError, ValueError):
            pass
    # Scheduled cron-tasks — system-internal, keep priority-only gate.
    prio = t.get("priority")
    prio_id = prio.get("id") if prio else None
    if name.startswith("Scheduled:"):
        return prio_id in ("1", "2", "3")
    # User tasks — require the `auto-worker` opt-in tag. ALL priorities drain
    # (urgency is ordering, not a gate); the tag is the safety valve so
    # judgment/personal tasks are never auto-grabbed.
    return "auto-worker" in tag_names

def _prio_rank(t: dict) -> int:
    prio = t.get("priority")
    pid = prio.get("id") if prio else None
    try:
        return int(pid)
    except (TypeError, ValueError):
        return 99

# Pick the most urgent pickable task (min priority id; stable tie-break keeps
# queue order — p3 eligible only once p1/p2 are drained).
_pickables = [t for t in todo if pickable(t)]
candidate = min(_pickables, key=_prio_rank) if _pickables else None
if candidate is None:
    sys.exit(0)

# slugify — single source of truth (scripts/lib/slugify.py). scripts/lib is
# already on sys.path from the drain-gate import above.
from slugify import slugify

title = candidate["name"]
backend_task_id = candidate["id"]
slug = slugify(title)

# Tmux idempotency
if subprocess.run(["tmux", "has-session", "-t", f"worker-{slug}"],
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
    sys.exit(0)

description = candidate.get("description") or ""
hay = f"{title}\n{description}".lower()

# Per-task cwd routing. A task may carry a line "Working dir (cwd): <abs path>"
# so the launcher starts the worker inside the right folder (project-scoped
# slash commands + CLAUDE.md only load from the launch cwd). Falls back to the
# main repo when absent or invalid.
worker_cwd = None
m_cwd = re.search(r"Working dir\s*\(cwd\):\s*(\S+)", description)
if m_cwd:
    cand_dir = m_cwd.group(1).strip().rstrip("`'\"")
    if os.path.isdir(cand_dir):
        worker_cwd = cand_dir
    else:
        print(f"[worker-launcher] task {backend_task_id} cwd '{cand_dir}' not a dir — using main repo", file=sys.stderr)

# Model: default from env (DEFAULT_MODEL); tasks with "sonnet" in title/desc
# force the cheaper Sonnet model — those are the fast scheduled checks.
default_model = os.environ.get("DEFAULT_MODEL", "claude-sonnet-4-6")
heavy_model = os.environ.get("WORKER_MODEL_HEAVY", default_model)
model = "claude-sonnet-4-6" if "sonnet" in hay else heavy_model

# --- Desc contract: description = Context ¶¶ Scope ¶¶ Criteria ---
# A "Criteria:" / "Acceptance Criteria:" header line starts the criteria block,
# which runs to the end of desc or the next section header. Directive lines
# (Timeout:, Working dir (cwd):) never belong to criteria.
CRIT_HEAD = re.compile(
    r"^\s*(?:#{1,6}\s*)?(?:Criteria|Acceptance Criteria)\s*:\s*(.*)$", re.IGNORECASE)
NEXT_HEAD = re.compile(
    r"^\s*(?:#{1,6}\s+\S|(?:Context|Scope|Timeout)\s*:|Working dir\s*\()", re.IGNORECASE)

def split_desc(desc: str):
    lines = desc.splitlines()
    for i, line in enumerate(lines):
        m = CRIT_HEAD.match(line)
        if not m:
            continue
        block = [m.group(1)] if m.group(1).strip() else []
        j = i + 1
        while j < len(lines) and not NEXT_HEAD.match(lines[j]):
            block.append(lines[j]); j += 1
        rest = "\n".join(lines[:i] + lines[j:])
        return "\n".join(block).strip(), rest.strip()
    return "", desc.strip()

criteria_desc, desc_rest = split_desc(description)

raw_tags = candidate.get("tags", [])
tags = [t["name"] if isinstance(t, dict) else t for t in raw_tags]

# confirm gate: task requires explicit operator approval before running.
if "confirm" in tags:
    msg = (f"[confirm-gate] {backend_task_id} — needs approval before running: {title}\n"
           f"Reply 'start {backend_task_id}' to launch, or 'skip {backend_task_id}' to defer.")
    if os.access(NOTIFY, os.X_OK):
        subprocess.run([NOTIFY, "--source", "worker-launcher", "--severity", "warn", "--msg", msg], check=False)
    _req = urllib.request.Request(
        f"https://api.clickup.com/api/v2/task/{backend_task_id}",
        data=json.dumps({"status": "in_review"}).encode(),
        headers={"Authorization": TOKEN, "Content-Type": "application/json"}, method="PUT")
    try: urllib.request.urlopen(_req, timeout=10)
    except Exception: pass
    sys.exit(0)

# Criteria: an explicit `criteria:` tag overrides; otherwise the desc block.
criteria = ""
crit = [t for t in tags if isinstance(t, str) and t.startswith("criteria:")]
if crit:
    criteria = "\n".join(c[len("criteria:"):] for c in crit)
elif criteria_desc:
    criteria = criteria_desc

# Context/Scope: with criteria extracted, first paragraph = context, rest = scope.
if criteria:
    parts = re.split(r"\n\s*\n", desc_rest, maxsplit=1)
    context = parts[0] if parts else ""
    scope = parts[1] if len(parts) == 2 else ""
else:
    context = description.strip()
    scope = ""

# Per-task wall-clock cap: "Timeout: NN" (minutes) line; research tasks default
# to 90, everything else 45. Passed to spawn-worker.sh and enforced by the
# supervisor.
m_timeout = re.search(r"^\s*Timeout\s*:\s*(\d+)\s*$", description, re.MULTILINE | re.IGNORECASE)
if m_timeout:
    cap_min = max(5, min(int(m_timeout.group(1)), 240))
elif "research" in hay:
    cap_min = 90
else:
    cap_min = 45
deadline_utc = (datetime.now(timezone.utc) + timedelta(minutes=cap_min)).strftime("%Y-%m-%d %H:%M UTC")

# Fill template
template = pathlib.Path(TEMPLATE).read_text()
filled = (template
    .replace("{{TASK_NAME}}", title)
    .replace("{{TASK_ID}}", slug)
    .replace("{{CLICKUP_TASK_ID}}", backend_task_id)
    .replace("{{TASK_CONTEXT}}", context)
    .replace("{{TASK_SCOPE}}", scope)
    .replace("{{TASK_CRITERIA}}", criteria)
    .replace("{{DEADLINE_UTC}}", deadline_utc)
    .replace("{{RELEVANT_SKILLS}}", ""))

def strip_empty_sections(text: str) -> str:
    for head in ("## Scope", "## Acceptance Criteria"):
        text = re.sub(rf"^{re.escape(head)}\s*\n(?:[ \t]*\n)*(?=^#{{1,6}} |\Z)",
                      "", text, flags=re.MULTILINE)
    return text

filled = strip_empty_sections(filled)
prompt_path = pathlib.Path(tempfile.gettempdir()) / f"worker-{slug}-prompt.md"
prompt_path.write_text(filled)

# Launch — spawn-worker.sh <task-id> <backend-task-id> <prompt-file> [timeout-min] [model]
cmd = ["/bin/bash", LAUNCHER, slug, backend_task_id, str(prompt_path), str(cap_min), model]
launch_env = dict(os.environ)
if worker_cwd:
    launch_env["WORKER_WORK_DIR"] = worker_cwd
    print(f"[worker-launcher] routing {backend_task_id} to cwd={worker_cwd}", file=sys.stderr)
res = subprocess.run(cmd, capture_output=True, text=True, env=launch_env)

if res.returncode != 0:
    print(f"spawn-worker failed for {slug}: rc={res.returncode}\n{res.stderr}", file=sys.stderr)
    sys.exit(0)

if subprocess.run(["tmux", "has-session", "-t", f"worker-{slug}"],
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
    print(f"spawn-worker exited 0 but no tmux session for {slug}", file=sys.stderr)
    sys.exit(0)

# Mark in_progress
_req = urllib.request.Request(
    f"https://api.clickup.com/api/v2/task/{backend_task_id}",
    data=json.dumps({"status": "in_progress"}).encode(),
    headers={"Authorization": TOKEN, "Content-Type": "application/json"}, method="PUT")
try:
    urllib.request.urlopen(_req, timeout=10)
except Exception as e:
    print(f"[worker-launcher] status update failed: {e}", file=sys.stderr)

print(f"launched: task#{backend_task_id} {title} (model={model})")

# Operator notification only for user tasks
if not title.startswith("Scheduled:") and os.access(NOTIFY, os.X_OK):
    msg = f"launched worker for {backend_task_id}: {title} ({model.replace('claude-','')})"
    subprocess.run([NOTIFY, "--source", "worker-launcher", "--severity", "info", "--msg", msg], check=False)
PYEOF

exit 0
