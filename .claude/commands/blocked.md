---
description: Finalize worker as blocked — record FAILURE + comment + status=blocked + notify + self-kill
argument-hint: <blocker reason — REQUIRED>
---

# Mark this worker as blocked

You cannot finish the task. `$ARGUMENTS` is the blocker reason — REQUIRED, fail loudly if empty.

If `$ARGUMENTS` is empty, ask yourself: what specifically blocks me? Write that down and use it. Do NOT call `/blocked` with no reason.

Execute these steps in order:

## 0. Push your partial worktree branch (git) — REQUIRED if you committed anything

Each worker that runs in the main repo has its own `git worktree` on branch
`worker/<slug>`. When blocking, do NOT merge to main (the work is incomplete) — just
PUSH the branch so the partial progress is reachable from the branch-tree link below,
then let step 6 remove the local worktree. The remote branch survives for pickup.

```bash
WT="${AGENTOS_WORKER_WORKTREE:-}"; BR="${AGENTOS_WORKER_BRANCH:-}"
if [ -n "$WT" ] && [ -d "$WT" ] && [ -n "$(git -C "$WT" log origin/main..HEAD --oneline 2>/dev/null)" ]; then
  git -C "$WT" push -u origin "$BR" && echo "pushed partial branch $BR"
fi
```

## 1. Append FAILURE line to memory/learnings.md

Strict one-line format, no headers:

```
[YYYY-MM-DD] FAILURE <CLICKUP_TASK_ID>: <$ARGUMENTS — what exactly blocks>. Try: <a specific alternative approach or what's needed to unblock>.
```

Append with `>>` to `memory/learnings.md`, then `git add` it.

## 2. Task-backend comment with blocker (markdown)

```bash
scripts/clickup/clickup.sh comment --task <CLICKUP_TASK_ID> --markdown --text "## Blocked

**Reason:** $ARGUMENTS

## What I tried

- <attempt 1>
- <attempt 2>

## What's needed to unblock

- <specific action, missing data, decision needed, or external dependency>

## Branch state — where the partial code is (REQUIRED if you pushed ANY code before blocking)

<So the owner / the next worker can pick up exactly where you stopped. Fill REAL values, no placeholders.>
- **Branch:** \`<branch>\` → https://github.com/<org>/<repo>/tree/<branch>
- **PR (if a draft/WIP PR exists):** https://github.com/<org>/<repo>/pull/<N>
- **Commit (if direct commit):** [<sha>](https://github.com/<org>/<repo>/commit/<sha>)
- (No code pushed → write "no code pushed".)

<Resolve from context: \`git remote get-url origin\`, \`git rev-parse --abbrev-ref HEAD\`,
 \`gh pr view --json url -q .url\`.>

outcome: blocked | score: 1/5 | note: $ARGUMENTS"
```

## 3. Task status → blocked

```bash
scripts/clickup/clickup.sh update --task <CLICKUP_TASK_ID> --status blocked
```

## 4. Append activity line to memory/worker-activity/YYYY-MM.log

One compact line — the success denominator for strategist metrics. Slug and backend id come from env (`AGENTOS_WORKER_TASK_ID` / `AGENTOS_WORKER_CLICKUP_TASK_ID`, set by spawn-worker.sh); if a value is missing, the fallbacks keep it honest (`duration=unknown`) — don't invent numbers:

```bash
H="${AGENTOS_WORKER_MAIN_REPO:-$(git rev-parse --show-toplevel)}"; SLUG="${AGENTOS_WORKER_TASK_ID:-$(tmux display-message -p '#S' 2>/dev/null | sed 's/^worker-//')}"; SLUG="${SLUG:-unknown}"; CU="${AGENTOS_WORKER_CLICKUP_TASK_ID:-<CLICKUP_TASK_ID>}"; ST=$(cat "$H/logs/workers/$SLUG/started-at" 2>/dev/null); DUR=unknown; [ -n "$ST" ] && DUR="$(( ($(date +%s) - ST) / 60 ))m"; mkdir -p "$H/memory/worker-activity"; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) blocked $SLUG duration=$DUR clickup=$CU" >> "$H/memory/worker-activity/$(date -u +%Y-%m).log"
```

## 5. Notify the operator via claude-peers

Short summary (the owner reads it on their phone, ~5 lines). The operator peer slug is `operator` (override with `AGENTOS_OPERATOR_PEER` if your deployment renames it); no `list_peers` needed:

```
mcp__claude-peers__send_message(to_id: "operator", message: "worker-<TASK_ID> [BLOCKED]\n\nReason: $ARGUMENTS\n\nWhat's needed: <2 lines>\n\nBranch with partial progress: <branch-tree url, or 'no code'>\nTask: <task-backend link>")
```

If peer-send fails, fall back to `scripts/notify-operator.sh --source worker --severity warn --msg "..."` (if that script exists in your deployment).

## 6. Remove your worktree, then kill your own tmux session (FINAL action)

Operate from the MAIN repo (not cwd-inside the dir being removed). The remote branch
you pushed in step 0 stays intact for pickup; only the LOCAL worktree + branch go.

**Never on an undelivered worktree.** `/done`'s verify-gate routes here precisely when
commits did NOT reach `origin/main`, leaving a `.agentos-undelivered` sentinel — so this
is the one path where the local worktree and branch may be the last handle on the work
(the remote push in step 0 is best-effort, and a failed push is exactly the correlated
case). Removing them there turns a lost race into permanently orphaned commits. The
guards below skip cleanup while the sentinel is present, and refuse to delete a branch
whose tip is not yet an ancestor of `origin/main`.

```bash
MAIN="${AGENTOS_WORKER_MAIN_REPO:-$(git rev-parse --show-toplevel)}"
if [ -f "${AGENTOS_WORKER_WORKTREE:-/nonexistent}/.agentos-undelivered" ]; then
  echo "REFUSING cleanup: worktree holds undelivered commits (see .agentos-undelivered) — left for manual re-merge"
elif [ -n "${AGENTOS_WORKER_WORKTREE:-}" ]; then
  git -C "$MAIN" worktree remove --force "$AGENTOS_WORKER_WORKTREE" 2>/dev/null || true
  git -C "$MAIN" worktree prune 2>/dev/null || true
  if [ -n "${AGENTOS_WORKER_BRANCH:-}" ]; then
    if git -C "$MAIN" merge-base --is-ancestor "$AGENTOS_WORKER_BRANCH" origin/main 2>/dev/null; then
      git -C "$MAIN" branch -D "$AGENTOS_WORKER_BRANCH" 2>/dev/null || true
    else
      echo "KEEPING branch $AGENTOS_WORKER_BRANCH — commits not in origin/main"
    fi
  fi
fi
tmux kill-session -t $(tmux display-message -p '#S')
```

Do NOT retry the same action >2 times before calling `/blocked`. If the CLI/API doesn't respond after a couple of tries — that's a system issue, not the worker's job to debug forever.
