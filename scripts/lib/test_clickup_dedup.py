"""Tests for the create-dedup guard (scripts/lib/clickup_dedup.py).

Run: PYTHONDONTWRITEBYTECODE=1 python3 scripts/lib/test_clickup_dedup.py
Covers find_duplicate: the double-create scenario (two auto-pipelines filing
the same problem seconds apart), the 24h window, status filtering
(spelling-insensitive), near-name matching, non-ASCII names, and the
no-false-positive case. No network: the fetch is injected.
"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from clickup_dedup import find_duplicate, _norm_name, _norm_status

NOW = 1784700500000  # fixed "now" so window tests are deterministic

def task(tid, name, status, created_ms):
    return {"id": tid, "name": name, "status": {"status": status},
            "date_created": str(created_ms), "url": f"https://app.clickup.com/t/{tid}"}

NAME = "Health API returns 400 for the second day — morning brief has no data"

fails = []
def check(desc, got, want):
    ok = got == want
    print(f"  [{'OK' if ok else 'FAIL'}] {desc}: got={got!r} want={want!r}")
    if not ok:
        fails.append(desc)

def dup_id(existing, name, **kw):
    d = find_duplicate("L", name, fetch=lambda _lid: existing, now_ms=NOW, **kw)
    return d["id"] if d else None

print("== double-create scenario ==")
# t1 already exists (created 9s earlier, todo) → second create must dedup
check("identical name 9s later -> dup hit",
      dup_id([task("t1", NAME, "todo", NOW - 9000)], NAME), "t1")
check("empty list -> no dup (first create passes)",
      dup_id([], NAME), None)

print("== 24h window ==")
check("same name 23h ago -> dup",
      dup_id([task("t1", NAME, "todo", NOW - 23 * 3600 * 1000)], NAME), "t1")
check("same name 25h ago -> NOT a dup (window expired)",
      dup_id([task("t1", NAME, "todo", NOW - 25 * 3600 * 1000)], NAME), None)

print("== status filter (spelling-insensitive) ==")
check("done -> not a dup (already closed, re-raise is legit)",
      dup_id([task("t1", NAME, "done", NOW - 9000)], NAME), None)
check("in_review -> not a dup",
      dup_id([task("t1", NAME, "in_review", NOW - 9000)], NAME), None)
check("'in progress' (space spelling) -> dup",
      dup_id([task("t1", NAME, "in progress", NOW - 9000)], NAME), "t1")
check("'to do' (product-list spelling) -> dup",
      dup_id([task("t1", NAME, "to do", NOW - 9000)], NAME), "t1")
check("'On Hold' (case) -> dup",
      dup_id([task("t1", NAME, "On Hold", NOW - 9000)], NAME), "t1")

print("== near-name matching ==")
check("punctuation/case noise -> dup",
      dup_id([task("t1", "health api returns 400 for the second day - morning brief has no data!", "todo", NOW - 9000)],
             NAME), "t1")
check("trailing tweak (near-same, ratio>=0.9) -> dup",
      dup_id([task("t1", NAME + " (v2)", "todo", NOW - 9000)], NAME), "t1")
check("different task, same prefix word -> NOT a dup",
      dup_id([task("t1", "Health API token rotation in the vault", "todo", NOW - 9000)], NAME), None)
check("unrelated name -> not a dup",
      dup_id([task("t1", "Set up database backups", "todo", NOW - 9000)], NAME), None)

print("== non-ASCII names (\\w matching is unicode) ==")
CYR = "Настроить бэкап базы данных"
check("identical cyrillic name -> dup",
      dup_id([task("t1", CYR, "todo", NOW - 9000)], CYR), "t1")
check("cyrillic punctuation noise -> dup",
      dup_id([task("t1", "Настроить:  бэкап базы данных!", "todo", NOW - 9000)], CYR), "t1")

print("== best-match & payload ==")
d = find_duplicate("L", NAME, now_ms=NOW, fetch=lambda _lid: [
    task("worse", NAME + " plus an extra unrelated tail", "todo", NOW - 9000),
    task("exact", NAME, "todo", NOW - 5000)])
check("exact beats fuzzy", d and d["id"], "exact")
check("payload has url", bool(d and d["url"].endswith("/exact")), True)
check("payload has ratio 1.0", d and d["match_ratio"], 1.0)

print("== normalizers ==")
check("_norm_status 'In Progress'", _norm_status("In Progress"), "inprogress")
check("_norm_name collapses", _norm_name("  Fix:  API!! "), "fix api")

if fails:
    print(f"\nFAILED: {len(fails)} — {fails}")
    sys.exit(1)
print("\nAll tests passed.")
