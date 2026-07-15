"""ClickUp upsert helper — one canonical task per (generator, key) pair.

Generators (escalation aggregators, scheduled checks, watchers) often need to
keep exactly one open ClickUp task per underlying entity. A naive `POST /task`
on every tick produces duplicates — a daily check that fires for 30 days leaves
30 near-identical tasks and the queue turns to noise.

Pattern: tag each managed task with a single COMPOSITE identity tag
`upsert:<gen_id>:<key>` (plus a bare `gen:<gen_id>` for analytics). On every
tick: search by the identity tag, update the match if found, otherwise create a
fresh task.

**Why one composite tag, not two (gen + key)?**
The ClickUp REST `GET /team/{id}/task?tags[]=A&tags[]=B` does **OR**, not AND —
verified against a live workspace: a search for `gen:blocked-aging` +
`key:item-1284` returned a task carrying only the gen tag. The dev docs imply
AND but the wire behaviour is OR. So identity MUST collapse into one unique
tag, otherwise upserts collide across keys sharing a generator.

Tags are first-class in the ClickUp REST API and do NOT need pre-creation in
the Space when set via `POST /task`.

Configuration (nothing is hardcoded — same convention as clickup.sh):
  CLICKUP_API_TOKEN     personal token (falls back to CLICKUP_PERSONAL_TOKEN)
  CLICKUP_TEAM_ID       team/workspace id — required, the tag search is team-scoped
  CLICKUP_LIST_ID       default list for the CLI (optional; --list-id overrides)
  CLICKUP_TODO_STATUS   status a stale task is re-queued into (default "todo")
  CLICKUP_DONE_STATUS   status close_task() writes (default "done")
Any of these may live in the env file instead (AGENT_OS_ENV_FILE, default
/etc/agent-os/agent-os.env). Status names must exist in the destination List's
status schema — ClickUp's unextended default schema uses "to do" / "complete",
a customized Space may use "todo" / "done", hence the overrides.

Usage:
    from clickup_upsert import upsert_task
    upsert_task(
        list_id="<clickup_list_id>",
        gen_id="blocked-aging",
        key="item-752",
        title="Escalation: blocked item#752 — Fix Timing MCP",
        description="Body refreshed each tick.",
        priority=3,
        extra_tags=["escalation"],
    )

Returns the ClickUp task id (existing or newly created).
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Iterable

API_BASE = "https://api.clickup.com/api/v2"

DEFAULT_ENV_FILE = "/etc/agent-os/agent-os.env"
TOKEN_KEYS = ("CLICKUP_API_TOKEN", "CLICKUP_PERSONAL_TOKEN")

# Parsed env-file cache: the file is read at most once per process. Keyed by
# path so tests (and callers that repoint AGENT_OS_ENV_FILE) are not poisoned
# by a previous read.
_env_file_cache: dict[str, dict[str, str]] = {}


def _env_file_path() -> str:
    return os.environ.get("AGENT_OS_ENV_FILE") or DEFAULT_ENV_FILE


def _env_file_values() -> dict[str, str]:
    """Parse `KEY=value` / `export KEY=value` lines out of the env file.

    Best-effort: a missing or unreadable file is not an error (the values may
    just as well come from the process environment).
    """
    path = _env_file_path()
    if path in _env_file_cache:
        return _env_file_cache[path]
    values: dict[str, str] = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[len("export ") :].lstrip()
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                    val = val[1:-1]
                if key and key not in values:
                    values[key] = val
    except OSError:
        pass
    _env_file_cache[path] = values
    return values


def _setting(*names: str) -> str | None:
    """First non-empty value among `names`, process env winning over the env file."""
    for name in names:
        val = os.environ.get(name)
        if val:
            return val
    file_values = _env_file_values()
    for name in names:
        val = file_values.get(name)
        if val:
            return val
    return None


def _token() -> str:
    tok = _setting(*TOKEN_KEYS)
    if not tok:
        raise RuntimeError(
            f"ClickUp token not found. Set {TOKEN_KEYS[0]} (or {TOKEN_KEYS[1]}) "
            f"in the environment or in {_env_file_path()}."
        )
    return tok


def _team_id() -> str:
    team = _setting("CLICKUP_TEAM_ID")
    if not team:
        raise RuntimeError(
            "CLICKUP_TEAM_ID is not set (export it or add it to "
            f"{_env_file_path()}) — the identity-tag search is team-scoped."
        )
    return team


def _todo_status() -> str:
    return _setting("CLICKUP_TODO_STATUS") or "todo"


def _done_status() -> str:
    return _setting("CLICKUP_DONE_STATUS") or "done"


def _request(method: str, path: str, body: dict | None = None, timeout: int = 15) -> dict:
    url = f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": _token()}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        # ClickUp puts the actionable reason in the response body ("Status not
        # found", "Tag name already exists", ...). The bare HTTPError repr shows
        # only "HTTP Error 400: Bad Request", which is undebuggable from a log.
        detail = ""
        try:
            detail = (e.read() or b"").decode(errors="replace").strip()
        except Exception:
            pass
        raise RuntimeError(
            f"ClickUp API {e.code} on {method} {path}: {detail or e.reason}"
        ) from e


def _identity_tag(gen_id: str, key: str) -> str:
    return f"upsert:{gen_id}:{key}"


def _find_by_tags(gen_id: str, key: str, include_closed: bool = True) -> dict | None:
    """Return the most recent task carrying the composite identity tag.

    `include_closed=True` by default — we want to find a previously-closed
    canonical row and reopen it, so that one (gen_id, key) pair maps to
    exactly one ClickUp task forever.
    """
    qs = urllib.parse.urlencode(
        [
            ("tags[]", _identity_tag(gen_id, key)),
            ("include_closed", "true" if include_closed else "false"),
            ("subtasks", "true"),
            ("page", "0"),
        ]
    )
    try:
        resp = _request("GET", f"/team/{_team_id()}/task?{qs}")
    except Exception as e:
        print(f"[clickup_upsert] search failed: {e}", file=sys.stderr)
        return None
    tasks = resp.get("tasks", [])
    return tasks[0] if tasks else None


def upsert_task(
    *,
    list_id: str,
    gen_id: str,
    key: str,
    title: str,
    description: str = "",
    priority: int | None = 3,
    extra_tags: Iterable[str] = (),
    reopen_if_closed: bool = True,
) -> str:
    """Find-or-create a ClickUp task identified by the (gen_id, key) identity tag.

    Returns the ClickUp task id. Updates an existing task's body, name and (if
    parked and reopen_if_closed=True) status back into the work loop.
    """
    tags = list(extra_tags) + [_identity_tag(gen_id, key), f"gen:{gen_id}"]
    existing = _find_by_tags(gen_id, key)
    if existing:
        # markdown_content (NOT plain description) so **bold**/###/`code`/lists
        # render in the ClickUp UI instead of showing raw markdown.
        body: dict = {"name": title, "markdown_content": description}
        if priority is not None:
            body["priority"] = priority
        # Reopen a stale managed task back into the work loop. The canonical
        # upsert invariant is: one (gen,key) pair -> one task that upsert keeps
        # runnable. Reopen from ANY parked/terminal status (closed, done,
        # in_review, blocked, on_hold) -> todo, NOT only from ClickUp's "closed"
        # status *type*. A `type == "closed"` test misses custom statuses like
        # "in_review", which silently strands a task forever: the periodic
        # upsert no-ops instead of re-queuing it.
        # The ONLY status we must not disturb is an actively-running one
        # ("in progress"): a worker holds the task right now, so resetting it to
        # todo would double-launch. "open"-type statuses are already todo-like
        # (no-op). Everything else is stale -> re-queue.
        status_obj = existing.get("status") or {}
        status_name = (status_obj.get("status") or "").strip().lower()
        status_type = status_obj.get("type")
        active = status_name in {"in progress", "in_progress"}
        already_todo = status_type == "open"
        if reopen_if_closed and not already_todo and not active:
            body["status"] = _todo_status()
        try:
            _request("PUT", f"/task/{existing['id']}", body)
        except Exception as e:
            print(f"[clickup_upsert] update failed for {existing['id']}: {e}", file=sys.stderr)
            raise
        # Re-ensure requested tags. ClickUp's PUT /task does NOT touch tags, so a
        # task that lost a tag (or never had one a caller now requires, e.g. a
        # routing tag added in a later release) would never re-acquire it.
        # Adding the missing ones via the tag endpoint keeps upsert idempotent on
        # identity AND routing tags. Best-effort: a tag failure must not break
        # the upsert — the task itself is already correct.
        existing_tag_names = {
            (t.get("name") if isinstance(t, dict) else t)
            for t in (existing.get("tags") or [])
        }
        for tag in tags:
            if tag not in existing_tag_names:
                try:
                    _request("POST", f"/task/{existing['id']}/tag/{urllib.parse.quote(tag)}")
                except Exception as e:
                    print(f"[clickup_upsert] tag add '{tag}' failed for {existing['id']}: {e}", file=sys.stderr)
        return existing["id"]

    payload: dict = {"name": title, "markdown_content": description, "tags": tags}
    if priority is not None:
        payload["priority"] = priority
    created = _request("POST", f"/list/{list_id}/task", payload)
    return created["id"]


def close_task(task_id: str, status: str | None = None) -> None:
    """Archive a managed task (e.g. when its trigger condition cleared).

    The status name must exist in the destination List's status schema; pass
    `status` explicitly or set CLICKUP_DONE_STATUS (default "done"). ClickUp's
    unextended default schema calls this status "complete".
    """
    _request("PUT", f"/task/{task_id}", {"status": status or _done_status()})


def main(argv: list[str] | None = None) -> int:
    import argparse

    p = argparse.ArgumentParser(description="ClickUp upsert helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    u = sub.add_parser("upsert", help="find-or-create the task for (gen, key)")
    u.add_argument(
        "--list-id",
        default=os.environ.get("CLICKUP_LIST_ID"),
        help="destination list id (default: $CLICKUP_LIST_ID)",
    )
    u.add_argument("--gen", required=True, help="generator id, e.g. blocked-aging")
    u.add_argument("--key", required=True, help="unique key, e.g. item-752")
    u.add_argument("--title", required=True)
    u.add_argument("--desc", default="")
    u.add_argument("--priority", type=int, default=3)
    u.add_argument("--tag", action="append", default=[], help="extra tag (repeatable)")

    c = sub.add_parser("close", help="close a managed task")
    c.add_argument("task_id")
    c.add_argument("--status", default=None, help="default: $CLICKUP_DONE_STATUS or 'done'")

    f = sub.add_parser("find", help="print the managed task for (gen, key), if any")
    f.add_argument("--gen", required=True)
    f.add_argument("--key", required=True)

    args = p.parse_args(argv)
    if args.cmd == "upsert":
        if not args.list_id:
            p.error("--list-id is required (or set CLICKUP_LIST_ID)")
        print(
            upsert_task(
                list_id=args.list_id, gen_id=args.gen, key=args.key,
                title=args.title, description=args.desc,
                priority=args.priority, extra_tags=args.tag,
            )
        )
    elif args.cmd == "close":
        close_task(args.task_id, args.status)
    elif args.cmd == "find":
        existing = _find_by_tags(args.gen, args.key)
        if not existing:
            return 1
        print(json.dumps({
            "id": existing["id"],
            "name": existing["name"],
            "status": (existing.get("status") or {}).get("status"),
        }))
    return 0


if __name__ == "__main__":
    # A misconfigured run (no token, no team id) is an operator error, not a bug:
    # from cron/Dagu it must read as one actionable line, not a traceback. Exit 2
    # keeps it distinct from 1, which `find` already uses for "no such task".
    # Library callers still get the RuntimeError — only the CLI edge converts it.
    try:
        sys.exit(main())
    except RuntimeError as e:
        print(f"[clickup_upsert] {e}", file=sys.stderr)
        sys.exit(2)
