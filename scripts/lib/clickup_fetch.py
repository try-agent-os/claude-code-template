"""clickup_fetch.py — the ONE paginated task fetch for the worker layer.

Every scheduled component that asks "which tasks are in state X right now?"
(worker launcher, worker supervisor, queue triage, drain doctor, and the
per-instance supervisors a fork adds on top) needs the same three things: walk
every page, stop on a short page, and be LOUD when the walk was cut short.

Each of them used to carry its own copy of that loop. That is exactly why one
bug — the `page=0`-only fetch that silently truncated every queue past the
first 100 tasks — had to be found and fixed in each copy separately, and why
the copy nobody remembered stayed broken. This module is the single place that
loop lives, so the next fix lands once.

Behaviour that MUST NOT regress (it is the reason this file exists):

  * full pagination — loop until a page comes back short (< page_size), never
    a single page=0 request;
  * loud cap — if `max_pages` is exhausted while pages are still full, the
    result is flagged `capped=True` and a message goes to `log`. A truncated
    sweep that looks green is silent data loss;
  * partial-fetch resilience — an HTTP failure on page N>0 keeps the pages
    already gathered (they are still valid work) and reports the error; the
    caller decides whether partial is good enough.

Usage:

    import sys; sys.path.insert(0, f"{REPO}/scripts/lib")
    from clickup_fetch import fetch_tasks

    res = fetch_tasks(token, team_id, statuses=["in_progress"],
                      space_ids=[space_id],
                      log=lambda m: print(m, file=sys.stderr))
    if res.error is not None and not res.tasks:
        sys.exit(0)                 # nothing usable — skip this tick
    for task in res.tasks:
        ...
    sys.exit(3 if res.capped else 0)
"""

import json
import os
import urllib.parse
import urllib.request
from collections import namedtuple

# CLICKUP_API_BASE exists so the walk can be pointed at a local fixture server
# in tests; production never sets it.
CLICKUP_API = os.environ.get("CLICKUP_API_BASE", "https://api.clickup.com/api/v2")

# ClickUp hard-caps the team task endpoint at 100 tasks per page.
PAGE_SIZE = 100
# Bound on a pathological run (an endpoint that never returns a short page).
MAX_PAGES = 20

# tasks:  list of task dicts, in API order, across every page walked
# capped: True  -> max_pages was exhausted with pages still full (INCOMPLETE)
# pages:  number of pages actually requested
# error:  the exception that ended the walk early, or None
FetchResult = namedtuple("FetchResult", "tasks capped pages error")


def build_query(*, statuses=(), space_ids=(), list_ids=(), assignees=(),
                include_closed=False, subtasks=False, extra_params=None):
    """Query params for the team task endpoint, ClickUp's `key[]=v` array form."""
    params = []
    for status in statuses:
        params.append(("statuses[]", status))
    for space_id in space_ids:
        params.append(("space_ids[]", str(space_id)))
    for list_id in list_ids:
        params.append(("list_ids[]", str(list_id)))
    for assignee in assignees:
        params.append(("assignees[]", str(assignee)))
    params.append(("include_closed", "true" if include_closed else "false"))
    if subtasks:
        params.append(("subtasks", "true"))
    for key, value in (extra_params or {}).items():
        params.append((key, str(value)))
    return urllib.parse.urlencode(params)


def fetch_tasks(token, team_id, *, statuses=(), space_ids=(), list_ids=(),
                assignees=(), include_closed=False, subtasks=False,
                extra_params=None, base_url=CLICKUP_API, max_pages=MAX_PAGES,
                page_size=PAGE_SIZE, timeout=15, log=None, label="clickup"):
    """Fetch every page of `GET /team/<id>/task`. Never raises — see FetchResult.

    `log` is an optional callable taking one string; it receives the loud
    messages (cap hit, page error). Pass `lambda m: print(m, file=sys.stderr)`.
    """
    def say(message):
        if log is not None:
            log(f"[{label}] {message}")

    if not token or not team_id:
        say("missing token or team id — fetch skipped")
        return FetchResult([], False, 0, ValueError("missing token or team id"))

    query = build_query(statuses=statuses, space_ids=space_ids,
                        list_ids=list_ids, assignees=assignees,
                        include_closed=include_closed, subtasks=subtasks,
                        extra_params=extra_params)
    endpoint = f"{base_url.rstrip('/')}/team/{urllib.parse.quote(str(team_id))}/task"

    tasks, capped, pages, error = [], False, 0, None
    for page in range(max_pages):
        pages = page + 1
        request = urllib.request.Request(f"{endpoint}?{query}&page={page}",
                                         headers={"Authorization": token})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                batch = json.loads(response.read()).get("tasks", [])
        except Exception as exc:            # noqa: BLE001 — any failure is a page failure
            error = exc
            # Pages already gathered stay valid work; only a page-0 failure
            # leaves the caller with nothing.
            say(f"API error on page {page}: {exc} — "
                f"{len(tasks)} task(s) fetched before the failure")
            break
        tasks += batch
        if len(batch) < page_size:
            break
    else:
        capped = True
        say(f"capped: pagination stopped at {max_pages} pages, {len(tasks)} "
            f"task(s) fetched, remainder DROPPED — result INCOMPLETE")

    return FetchResult(tasks, capped, pages, error)
