# Task-queue backend adapter

The worker orchestration layer needs a place to read the queue from and write
task state back to. That place used to be hardcoded to ClickUp in every
lifecycle script. It now sits behind one seam: `scripts/lib/task-queue.sh`.

## Why this exists

Four different scripts (launcher, supervisor, trigger evaluator, `/done` and
`/blocked` skills) each need to answer "what is this task's status" and "set it
to X and leave a comment". When each one spoke ClickUp's REST API directly,
adopting any other tracker meant editing all of them and re-testing the whole
worker lifecycle. The adapter reduces that to implementing four functions.

ClickUp remains the **reference backend** — it ships working out of the box and
is what the template is tested against. It is no longer the *only* option.

## The interface

Source it and call the `tq_*` functions:

```bash
source "$REPO/scripts/lib/task-queue.sh"

tq_get_status   <task_id>            # -> prints status slug, "" on failure
tq_set_status   <task_id> <status>   # -> exit 0 on success
tq_comment      <task_id> <text>     # -> exit 0 on success
tq_get_comments <task_id>            # -> comment bodies, newest first, one per line
```

Status slugs are backend-agnostic; the adapter maps them onto whatever the
backend calls them:

```
todo | in_progress | in_review | blocked | on_hold | done
```

## Selecting a backend

```bash
AGENTOS_TASK_BACKEND=clickup   # default — reference implementation
AGENTOS_TASK_BACKEND=custom    # sources $AGENTOS_TASK_BACKEND_SCRIPT
```

With `custom`, your script must define all four `tq_*` functions. The adapter
verifies this at source time and fails loudly if one is missing, rather than
letting a half-implemented backend silently no-op a status flip.

## Writing your own backend

```bash
# my-backend.sh
tq_get_status()   { curl -sS "$MY_API/issues/$1" | jq -r '.state'; }
tq_set_status()   { curl -sS -X PATCH "$MY_API/issues/$1" -d "{\"state\":\"$2\"}" >/dev/null; }
tq_comment()      { curl -sS -X POST "$MY_API/issues/$1/comments" -d "$(jq -Rn --arg t "$2" '{body:$t}')" >/dev/null; }
tq_get_comments() { curl -sS "$MY_API/issues/$1/comments" | jq -r 'reverse | .[].body'; }
```

```bash
export AGENTOS_TASK_BACKEND=custom
export AGENTOS_TASK_BACKEND_SCRIPT=/path/to/my-backend.sh
```

Two rules worth respecting, because the lifecycle scripts depend on them:

- **`tq_get_comments` must return newest-first.** The timeout ladder reads the
  most recent comment to decide whether a worker already finished (`outcome:
  done` → `in_review`) or is parked awaiting a human decision (`on_hold`).
  Reversed order silently inverts both decisions.
- **Failure must be distinguishable from "no data".** Return non-zero and print
  nothing on an API error. A backend that prints an empty status on a 500 makes
  the idempotency guard think the task is untracked and flip it anyway.

## What is not behind the adapter

Listing/querying the queue (the launcher picking the next pickable todo) is
still backend-specific — it needs filtering, sorting and pagination semantics
that vary too much to usefully abstract into a shell function. Those call sites
are marked with an explicit header comment naming what a replacement backend
must return, so they are findable with a grep rather than hidden.
