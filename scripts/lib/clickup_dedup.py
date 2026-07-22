"""ClickUp create-dedup guard — same/near-same name in one list within 24h.

Motivating failure class: two auto-pipelines (a monitor and a responder, or the
same cron firing twice) each file an identical task for the same problem seconds
apart — the worker launcher then spawns TWO workers on one problem and the
second has to be stood down by hand.

Guard contract (called BEFORE any auto `POST /list/{id}/task`):
look for an existing task in the target list with the same / near-same
(normalized + difflib) name, created in the last WINDOW hours, in an
open working status (todo / in progress / on hold — any spelling).
Found → the caller must NOT create; it comments on the existing task instead.

Distinct from scripts/lib/clickup_upsert.py: upsert is for generators that OWN
their tasks via a composite identity tag (`upsert:<gen>:<key>`). This guard is
for free-form creates (mention responders, ad-hoc pipelines, clickup.sh
create) where no stable key exists — only the name.

Fail-open by design: an API error must never block task creation (a missed
dedup is noise; a blocked create is data loss). CLI exit codes encode this:
  0 — duplicate found, JSON of the existing task on stdout
  1 — no duplicate (create away)
  2 — guard failed (API/network); caller proceeds with create, warn on stderr

Usage (CLI, from clickup.sh cmd_create):
    python3 scripts/lib/clickup_dedup.py --list <list_id> --name "..." \
        [--window-hours 24] [--threshold 0.9] [--statuses todo,in_progress,on_hold]

Usage (import, from auto-create pipelines):
    from clickup_dedup import find_duplicate
    dup = find_duplicate(list_id, name)   # dict | None; raises on API failure

Auth: same chain as clickup.sh / clickup_upsert.py — CLICKUP_API_TOKEN, else
CLICKUP_PERSONAL_TOKEN, from the environment or the agent-os env file
(AGENT_OS_ENV_FILE, default /etc/agent-os/agent-os.env).
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The token chain lives in ONE place per repo — reuse the resolver from the
# sibling upsert lib instead of copy-pasting the env/env-file logic.
from clickup_upsert import _token as _resolve_token

DEFAULT_WINDOW_HOURS = 24
DEFAULT_THRESHOLD = 0.9
# Working statuses that count as "this problem is already on the board".
# Compared via _norm_status (lowercase, non-alnum stripped), so "to do",
# "todo", "In Progress", "in_progress", "on hold" all land in this set.
DEFAULT_STATUSES = ("todo", "inprogress", "onhold")
_MAX_PAGES = 10  # 1000 open tasks per list is far above any real list here


def _norm_status(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def _norm_name(s: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace — makes «Fix:  API!»
    and «fix api» comparable without hiding real differences."""
    s = (s or "").lower()
    s = re.sub(r"[^\w\s]", " ", s, flags=re.UNICODE)
    return re.sub(r"\s+", " ", s).strip()


def _default_fetch(list_id: str, token: str) -> list[dict]:
    """All open tasks of the list (paginated; subtasks included so nested
    auto-worker tasks count as duplicates too)."""
    rows: list[dict] = []
    for page in range(_MAX_PAGES):
        qs = urllib.parse.urlencode({
            "archived": "false", "include_closed": "false",
            "subtasks": "true", "page": str(page),
        })
        req = urllib.request.Request(
            f"https://api.clickup.com/api/v2/list/{list_id}/task?{qs}",
            headers={"Authorization": token})
        with urllib.request.urlopen(req, timeout=15) as resp:
            batch = json.loads(resp.read()).get("tasks", [])
        rows += batch
        if len(batch) < 100:
            return rows
    # A silent cap would read as "scanned everything" — scream, return what we
    # have; the guard stays fail-open (a missed dup beyond page 10 is only noise).
    print(f"[clickup_dedup] capped at {_MAX_PAGES} pages ({len(rows)} tasks), "
          f"remainder NOT scanned for duplicates", file=sys.stderr)
    return rows


def find_duplicate(list_id: str, name: str,
                   window_hours: float = DEFAULT_WINDOW_HOURS,
                   statuses: tuple[str, ...] | list[str] = DEFAULT_STATUSES,
                   threshold: float = DEFAULT_THRESHOLD,
                   fetch=None, now_ms: int | None = None) -> dict | None:
    """Return the existing duplicate task dict, or None.

    fetch/now_ms are injectable for unit tests. Raises on API failure —
    CLI wrapper / callers translate that into fail-open.
    """
    want = _norm_name(name)
    if not want:
        return None
    allowed = {_norm_status(s) for s in statuses}
    if now_ms is None:
        now_ms = int(time.time() * 1000)
    cutoff_ms = now_ms - int(window_hours * 3600 * 1000)

    if fetch is None:
        tasks = _default_fetch(list_id, _resolve_token())
    else:
        tasks = fetch(list_id)

    best: dict | None = None
    best_ratio = 0.0
    for t in tasks:
        if _norm_status((t.get("status") or {}).get("status", "")) not in allowed:
            continue
        try:
            created = int(t.get("date_created") or 0)
        except (TypeError, ValueError):
            continue
        if created < cutoff_ms:
            continue
        cand = _norm_name(t.get("name", ""))
        if not cand:
            continue
        ratio = 1.0 if cand == want else difflib.SequenceMatcher(None, want, cand).ratio()
        if ratio >= threshold and ratio > best_ratio:
            best, best_ratio = t, ratio
    if best is None:
        return None
    return {
        "id": best["id"],
        "name": best.get("name", ""),
        "status": (best.get("status") or {}).get("status", "?"),
        "url": best.get("url") or f"https://app.clickup.com/t/{best['id']}",
        "date_created": best.get("date_created"),
        "match_ratio": round(best_ratio, 3),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", required=True, dest="list_id")
    ap.add_argument("--name", required=True)
    ap.add_argument("--window-hours", type=float, default=DEFAULT_WINDOW_HOURS)
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    ap.add_argument("--statuses", default=",".join(DEFAULT_STATUSES),
                    help="CSV, spelling-insensitive (todo == 'to do')")
    args = ap.parse_args()
    try:
        dup = find_duplicate(args.list_id, args.name,
                             window_hours=args.window_hours,
                             statuses=[s for s in args.statuses.split(",") if s.strip()],
                             threshold=args.threshold)
    except Exception as e:  # noqa: BLE001 — fail-open is the contract
        print(f"[clickup_dedup] guard failed ({e}) — caller should proceed with create",
              file=sys.stderr)
        return 2
    if dup is None:
        return 1
    print(json.dumps(dup, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
