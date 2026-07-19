---
description: Finalize worker task — comment (with branch-state link) + status=in_review + notify operator + kill own tmux session
argument-hint: [optional override summary]
---

# Finalize this worker task

You're closing this worker session. Execute these steps in order. Don't skip any.

## 0. Merge your isolated worktree into main (git) — REQUIRED if you committed code

Each worker that runs in the main repo gets its OWN `git worktree` on branch
`worker/<slug>-<epoch>` (env `AGENTOS_WORKER_WORKTREE` / `AGENTOS_WORKER_BRANCH`), so
your commits never touch the operator's main tree. The merge back to `main` happens
HERE, atomically, by fast-forward-pushing your branch straight to `origin/main`
(no local checkout switch → zero contention with operator/sibling workers).

```bash
WT="${AGENTOS_WORKER_WORKTREE:-}"; BR="${AGENTOS_WORKER_BRANCH:-}"
MAIN="${AGENTOS_WORKER_MAIN_REPO:-$(git rev-parse --show-toplevel)}"
DELIVERY_STATUS="n/a"    # n/a (no code) | ok (HEAD in origin/main) | FAILED (orphaned)
if [ -n "$WT" ] && [ -d "$WT" ]; then
  cd "$WT"
  if [ -n "$(git log origin/main..HEAD --oneline 2>/dev/null)" ]; then
    git push -u origin "$BR"                       # unique per-worker branch — never races a sibling
    merged=0
    for i in 1 2 3 4 5; do                         # retry: sibling worker may push first
      git fetch origin main
      git rebase origin/main || { git rebase --abort 2>/dev/null; break; }
      if git push origin HEAD:main; then merged=1; echo "MERGED $BR -> origin/main"; break; fi
      sleep 2
    done
    # VERIFY GATE — a green /done must NOT be reported while ANY commit is missing
    # from origin/main. Without it a lost ff-push race is indistinguishable from
    # success: the worker reports `outcome: done`, the branch is orphaned, and the
    # work is only found by hand days later (GitHub happily serves dangling commits
    # by SHA, so even a commit link in the report looks healthy). The gate runs
    # BEFORE the comment and BEFORE any cleanup: every commit still listed in
    # `origin/main..HEAD` is by definition NOT delivered, so a non-empty list =
    # FAILED. Never take a commit SHA for the report before this passes.
    git fetch origin main -q 2>/dev/null || true
    UNDELIVERED=""
    for sha in $(git rev-list origin/main..HEAD 2>/dev/null); do
      git merge-base --is-ancestor "$sha" origin/main 2>/dev/null || UNDELIVERED="$UNDELIVERED $sha"
    done
    if [ -z "$UNDELIVERED" ] && git merge-base --is-ancestor "$(git rev-parse HEAD)" origin/main 2>/dev/null; then
      DELIVERY_STATUS="ok"; echo "DELIVERY OK: every commit is an ancestor of origin/main"
    else
      DELIVERY_STATUS="FAILED"
      echo "DELIVERY FAILED: not in origin/main —$UNDELIVERED (branch '$BR' orphaned, work NOT delivered)"
      # Sentinel: tells spawn-worker.sh's orphan GC that this worktree holds
      # undelivered work and must NOT be reaped when this session dies (the GC keys
      # on a dead tmux session, which /done is about to cause). Self-clearing: the
      # GC reaps the worktree once the commits genuinely land in origin/main.
      printf 'branch=%s\nhead=%s\nundelivered=%s\ntask=%s\nat=%s\n' \
        "$BR" "$(git rev-parse HEAD)" "$UNDELIVERED" "${AGENTOS_WORKER_CLICKUP_TASK_ID:-unknown}" \
        "$(date -u +%FT%TZ)" > "$WT/.agentos-undelivered"
      git push -u origin "$BR" 2>/dev/null || true   # best-effort: keep work reachable from the remote too
      [ -x "${MAIN}/scripts/notify-operator.sh" ] && "${MAIN}/scripts/notify-operator.sh" \
        --source worker --severity warn \
        --msg "worker ${AGENTOS_WORKER_TASK_ID:-$BR}: /done verify-gate FAILED — commits never reached main, branch '${BR}' orphaned, worktree preserved, needs a manual re-merge" \
        2>/dev/null || true
    fi
  else
    echo "no commits on $BR — nothing to merge"
  fi
fi
```

Read `DELIVERY_STATUS` and let it steer the finalization below — it is the source of
truth for whether your code actually landed:

- **`ok`** — your work is on `origin/main`; the operator's main tree picks it up on its
  next pull or the next worker spawn's fetch. Proceed normally.
- **`FAILED`** — the gate caught undelivered commits. **STOP: do not run steps 1-5 of this
  skill.** DO NOT force-push, DO NOT report a clean success, and above all **DO NOT remove
  the worktree** — it is the only place the work is guaranteed to be reachable, and deleting
  it (or its branch) is what turns a lost race into permanently orphaned commits. The alert
  already fired and `.agentos-undelivered` now protects the worktree from the orphan GC.
  Hand off to the blocked path:

  ```
  /blocked merge-to-main FAILED — branch <BR> orphaned, commits NOT in origin/main, worktree preserved for re-merge
  ```

  `/blocked` posts `outcome: blocked` with the branch-tree link, sets status `blocked`
  (never `done` — a silent `done` on lost work is exactly the defect this gate exists to
  kill), and skips the worktree cleanup while the sentinel is present.
- **`n/a`** — no commits to merge (no-op / read-only run); nothing to deliver, proceed normally.

(If `AGENTOS_WORKER_WORKTREE` is empty — a submodule-routed worker or the shared-tree
fallback — skip this step and follow that project's own git flow.)

## 1. Task-backend comment (markdown, REQUIRED)

Read `{{CLICKUP_TASK_ID}}` from the prompt context (or the `/goal` condition you've been working under). Post a comment via the wrapper so markdown renders in the task-backend UI:

```bash
scripts/clickup/clickup.sh comment --task <CLICKUP_TASK_ID> --markdown --text "## What I did

<2-4 bullets: concrete actions, files touched, decisions made>

## Result / impact

<what changed for the user, or what was learned>

## Branch state — where the code is (REQUIRED if you wrote ANY code)

<The owner reads the ticket on their phone and must reach the code in one tap. Fill REAL values
 from your session — never leave a placeholder. Pick whatever exists:>
- **PR (if opened):** https://github.com/<org>/<repo>/pull/<N>  ← preferred, always link this if a PR exists
- **Branch (always, if you pushed):** \`<branch>\` → https://github.com/<org>/<repo>/tree/<branch>
- **Preview (if the PR builds a demo stand, e.g. Cloudflare Pages):** the deploy bot's preview URL  ← live demo to click and try
- **vs main (optional but nice):** https://github.com/<org>/<repo>/compare/main...<branch>
- **Commit (if no branch pushed — e.g. direct commit):** [<sha>](https://github.com/<org>/<repo>/commit/<sha>)

<Resolve <org>/<repo>/<branch>/<N> from your actual context:
 \`git remote get-url origin\` → org/repo; \`git rev-parse --abbrev-ref HEAD\` → branch;
 \`gh pr view --json number,url -q .url\` → PR url (if any).>

<**Preview URL** — only for repos with a PR-preview integration (e.g. a Cloudflare Pages bot
 that comments a stable Branch Preview URL on the PR). Pull the URL from that bot's PR comment —
 DON'T hand-build it. Timing: previews usually deploy ~1-3 min AFTER the PR push; if the comment
 isn't there yet, poll a few times, and if still empty after ~2 min write "**Preview:** pending"
 and finalize anyway — NEVER block finalization on the preview. If the repo has no preview
 integration, omit the Preview line entirely.>

## Links

- Files changed: https://github.com/<org>/<repo>/blob/<branch>/<path>

outcome: done | score: X/5 | note: <1 line what worked or what was tricky>"
```

Score guide: 5=smooth, 4=minor friction, 3=workarounds needed, 2=partial, 1=barely done.

If `$ARGUMENTS` is non-empty, use it as the override summary text instead of composing your own.

## 2. Task status → in_review (or `done` for a no-op scheduled run)

Default: you finalize at `in_review` and hand the task to the owner. **Never set `done`/`complete` yourself for delegated work** — the final close is the owner's after they review.

**Exception — a no-op scheduled monitor run auto-closes to `done`.** A scheduled
cron check that produced **no commits** is a pure no-op report: there is nothing to
review, so leaving it `in_review` clutters the review queue with a ghost task and —
if `/done` races the supervisor — can strand it in a sticky `in_review`. Such a run
closes to `done` directly. Keep `in_review` whenever there ARE commits (real work to
review) or the task came from a human.

Which slugs count as scheduled is a deployment setting: `AGENTOS_NOOP_SLUG_RE`
(default `^scheduled-`). Set it to something unmatchable to disable the exception.
The block below decides automatically from the env the launcher set — run it verbatim:

```bash
SLUG="${AGENTOS_WORKER_TASK_ID:-}"
WT="${AGENTOS_WORKER_WORKTREE:-}"
NOOP_RE="${AGENTOS_NOOP_SLUG_RE:-^scheduled-}"
# Default to "there were commits": an unknown worktree or a missing origin/main
# must NOT read as a no-op, or a run that DID commit would be auto-closed.
HAD_COMMITS=1
if [ -n "$WT" ] && [ -d "$WT" ] && git -C "$WT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  [ -z "$(git -C "$WT" log origin/main..HEAD --oneline 2>/dev/null)" ] && HAD_COMMITS=0
fi
if [ "$HAD_COMMITS" = 0 ] && printf '%s' "$SLUG" | grep -qE "$NOOP_RE"; then
  # no-op scheduled run — nothing to review, auto-close
  scripts/clickup/clickup.sh update --task <CLICKUP_TASK_ID> --status done
  echo "no-op scheduled run → status=done (auto-closed, nothing to review)"
else
  scripts/clickup/clickup.sh update --task <CLICKUP_TASK_ID> --status in_review
fi
```

(If the list has no `in_review` status and the task was a pure no-op / nothing to review, `awaiting` is the fallback — but for any task with a real result, `in_review` + the branch-state comment above is the right terminal state.)

## 3. Append activity line to memory/worker-activity/YYYY-MM.log

One compact line — the success denominator for strategist metrics. Slug and backend id come from env (`AGENTOS_WORKER_TASK_ID` / `AGENTOS_WORKER_CLICKUP_TASK_ID`, set by spawn-worker.sh), start time from the worker state dir; if a value is missing, the fallbacks keep it honest (`duration=unknown`) — don't invent numbers:

```bash
H="${AGENTOS_WORKER_MAIN_REPO:-$(git rev-parse --show-toplevel)}"; SLUG="${AGENTOS_WORKER_TASK_ID:-$(tmux display-message -p '#S' 2>/dev/null | sed 's/^worker-//')}"; SLUG="${SLUG:-unknown}"; CU="${AGENTOS_WORKER_CLICKUP_TASK_ID:-<CLICKUP_TASK_ID>}"; ST=$(cat "$H/logs/workers/$SLUG/started-at" 2>/dev/null); DUR=unknown; [ -n "$ST" ] && DUR="$(( ($(date +%s) - ST) / 60 ))m"; mkdir -p "$H/memory/worker-activity"; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) finished $SLUG duration=$DUR clickup=$CU" >> "$H/memory/worker-activity/$(date -u +%Y-%m).log"
```

## 4. Notify the operator via claude-peers

Send a short summary (the owner reads it on their phone — keep to ~5 lines). The operator peer slug is `operator` (override with `AGENTOS_OPERATOR_PEER` if your deployment renames it); no `list_peers` needed:

```
mcp__claude-peers__send_message(to_id: "operator", message: "worker-<TASK_ID> [done, in review]\n\nWhat I did:\n- ...\n\nPR/branch: <PR url, or branch-tree url, or '—' if no code>\nTask: <task-backend link>")
```

If peer-send fails, fall back to `scripts/notify-operator.sh --source worker --severity info --msg "..."` (if that script exists in your deployment).

## 5. Remove your worktree, then kill your own tmux session (FINAL action)

First tear down your isolated worktree (operate from the MAIN repo so you're not
cwd-inside the dir you're removing — `git -C "$MAIN"`), then kill the session.
spawn-worker.sh also prunes stale worktrees on respawn, so a missed cleanup here
is self-healing, but do it anyway to keep `git worktree list` tidy.

The `.agentos-undelivered` guard below is a backstop: cleanup must never run on a
worktree holding undelivered commits, whatever path led here.

```bash
MAIN="${AGENTOS_WORKER_MAIN_REPO:-$(git rev-parse --show-toplevel)}"
if [ -f "${AGENTOS_WORKER_WORKTREE:-/nonexistent}/.agentos-undelivered" ]; then
  echo "REFUSING cleanup: worktree holds undelivered commits (see .agentos-undelivered) — use /blocked"
elif [ -n "${AGENTOS_WORKER_WORKTREE:-}" ]; then
  git -C "$MAIN" worktree remove --force "$AGENTOS_WORKER_WORKTREE" 2>/dev/null || true
  git -C "$MAIN" worktree prune 2>/dev/null || true
  [ -n "${AGENTOS_WORKER_BRANCH:-}" ] && git -C "$MAIN" branch -D "$AGENTOS_WORKER_BRANCH" 2>/dev/null || true
fi
tmux kill-session -t $(tmux display-message -p '#S')
```

After step 5 your process is gone. The `/goal` evaluator will not run again — the condition has been satisfied by you completing all steps.
