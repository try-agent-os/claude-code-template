#!/usr/bin/env python3
"""Fixture test for scripts/lib/clickup_fetch.py — run: python3 test_clickup_fetch.py

The point of the module is that ONE queue walk is correct for everybody, so the
test asserts the properties whose absence caused real incidents:

  1. >100 tasks come back WHOLE (the page-0 truncation regression);
  2. a walk cut short by max_pages is flagged `capped` (silent = data loss);
  3. an error on page N>0 keeps the pages already gathered (partial work);
  4. an error on page 0 yields nothing and an error, not a fake-empty queue.

It runs against a throwaway http.server on localhost — no network, no token.
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from clickup_fetch import fetch_tasks  # noqa: E402

TOTAL = 250          # > 2 full pages: the exact shape page-0-only silently ate
PAGE_SIZE = 100
FAIL_ON_PAGE = None  # set by the error tests


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):                                   # noqa: N802
        page = int(parse_qs(urlparse(self.path).query).get("page", ["0"])[0])
        if FAIL_ON_PAGE is not None and page >= FAIL_ON_PAGE:
            self.send_response(500)
            self.end_headers()
            return
        start = page * PAGE_SIZE
        batch = [{"id": f"t{i}", "name": f"task {i}"}
                 for i in range(start, min(start + PAGE_SIZE, TOTAL))]
        body = json.dumps({"tasks": batch}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):                      # silence the server
        pass


def check(label, condition, detail=""):
    print(f"{'ok  ' if condition else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
    return condition


def main():
    global FAIL_ON_PAGE
    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    passed = True

    # 1. full pagination over >100 tasks
    res = fetch_tasks("tok", "team1", statuses=["in_progress"], base_url=base)
    passed &= check("250 tasks over 3 pages come back whole",
                    len(res.tasks) == TOTAL and res.pages == 3 and not res.capped
                    and res.error is None,
                    f"tasks={len(res.tasks)} pages={res.pages} capped={res.capped}")
    passed &= check("no duplicates / no gaps across pages",
                    [t["id"] for t in res.tasks] == [f"t{i}" for i in range(TOTAL)])

    # 2. the regression baseline: one page only is exactly the page-0 truncation
    #    that shipped in every copy of this loop. It must be LOUD, never silent.
    logged = []
    res = fetch_tasks("tok", "team1", base_url=base, max_pages=1, log=logged.append)
    passed &= check("page-0-only walk → 100 of 250 BUT capped=True + a loud line",
                    res.capped and len(res.tasks) == 100
                    and any("capped" in m for m in logged),
                    f"capped={res.capped} tasks={len(res.tasks)} log={logged}")

    # 3. failure on a later page keeps what was already gathered
    FAIL_ON_PAGE = 2
    logged = []
    res = fetch_tasks("tok", "team1", base_url=base, log=logged.append)
    passed &= check("error on page 2 → 200 tasks kept + error reported",
                    len(res.tasks) == 200 and res.error is not None
                    and any("API error on page 2" in m for m in logged),
                    f"tasks={len(res.tasks)} error={res.error}")

    # 4. failure on page 0 is not a fake-empty queue
    FAIL_ON_PAGE = 0
    res = fetch_tasks("tok", "team1", base_url=base)
    passed &= check("error on page 0 → empty result WITH an error",
                    res.tasks == [] and res.error is not None)

    # 5. missing credentials degrade to an empty, flagged result
    res = fetch_tasks("", "team1", base_url=base)
    passed &= check("missing token → empty result WITH an error",
                    res.tasks == [] and res.error is not None)

    server.shutdown()
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
