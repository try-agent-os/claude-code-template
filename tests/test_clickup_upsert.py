#!/usr/bin/env python3
"""Offline unit tests for scripts/lib/clickup_upsert.py.

No network: every test swaps `clickup_upsert._request` for a recorder that
returns canned responses, so the whole ClickUp wire protocol is asserted from
the request log. Run directly:

    python3 tests/test_clickup_upsert.py
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "lib"))

import clickup_upsert  # noqa: E402


class _Recorder:
    """Stand-in for `_request` — records calls, replays queued responses."""

    def __init__(self, responses=None):
        self.calls = []
        self.responses = list(responses or [])

    def __call__(self, method, path, body=None, timeout=15):
        self.calls.append({"method": method, "path": path, "body": body})
        if self.responses:
            return self.responses.pop(0)
        return {}

    def find(self, method, path_contains):
        return [
            c for c in self.calls
            if c["method"] == method and path_contains in c["path"]
        ]


class ClickUpUpsertTest(unittest.TestCase):
    def setUp(self):
        # Isolate every test from the host's real env file and real settings.
        self._saved_env = dict(os.environ)
        clickup_upsert._env_file_cache.clear()
        for key in (
            "CLICKUP_API_TOKEN", "CLICKUP_PERSONAL_TOKEN", "CLICKUP_TEAM_ID",
            "CLICKUP_LIST_ID", "CLICKUP_TODO_STATUS", "CLICKUP_DONE_STATUS",
        ):
            os.environ.pop(key, None)
        os.environ["AGENT_OS_ENV_FILE"] = "/nonexistent/agent-os.env"
        os.environ["CLICKUP_API_TOKEN"] = "tok-test"
        os.environ["CLICKUP_TEAM_ID"] = "team-test"
        self._saved_request = clickup_upsert._request

    def tearDown(self):
        clickup_upsert._request = self._saved_request
        os.environ.clear()
        os.environ.update(self._saved_env)
        clickup_upsert._env_file_cache.clear()

    def _install(self, responses):
        rec = _Recorder(responses)
        clickup_upsert._request = rec
        return rec

    # --- identity -----------------------------------------------------------
    def test_identity_tag_is_one_composite_tag(self):
        # The search is OR over tags[], so identity must be a single tag.
        self.assertEqual(
            clickup_upsert._identity_tag("blocked-aging", "item-752"),
            "upsert:blocked-aging:item-752",
        )

    def test_search_is_team_scoped_and_includes_closed(self):
        rec = self._install([{"tasks": []}, {"id": "new1"}])
        clickup_upsert.upsert_task(
            list_id="L1", gen_id="g", key="k", title="T",
        )
        search = rec.find("GET", "/team/team-test/task")[0]
        self.assertIn("tags%5B%5D=upsert%3Ag%3Ak", search["path"])
        self.assertIn("include_closed=true", search["path"])

    # --- create path --------------------------------------------------------
    def test_creates_when_no_existing_task(self):
        rec = self._install([{"tasks": []}, {"id": "new1"}])
        task_id = clickup_upsert.upsert_task(
            list_id="L1", gen_id="g", key="k", title="T",
            description="body", priority=2, extra_tags=["escalation"],
        )
        self.assertEqual(task_id, "new1")
        created = rec.find("POST", "/list/L1/task")[0]["body"]
        self.assertEqual(created["name"], "T")
        # markdown_content, not description — else the UI shows raw markdown.
        self.assertEqual(created["markdown_content"], "body")
        self.assertEqual(created["priority"], 2)
        self.assertEqual(
            created["tags"], ["escalation", "upsert:g:k", "gen:g"],
        )

    # --- update / reopen path ----------------------------------------------
    def test_reopens_parked_custom_status(self):
        # "in_review" is not ClickUp's "closed" *type* — a type-based test would
        # strand the task forever. It must still be re-queued.
        rec = self._install([
            {"tasks": [{
                "id": "t1", "tags": [{"name": "upsert:g:k"}, {"name": "gen:g"}],
                "status": {"status": "in_review", "type": "custom"},
            }]},
            {},
        ])
        task_id = clickup_upsert.upsert_task(
            list_id="L1", gen_id="g", key="k", title="T",
        )
        self.assertEqual(task_id, "t1")
        self.assertEqual(rec.find("PUT", "/task/t1")[0]["body"]["status"], "todo")

    def test_does_not_disturb_an_in_progress_task(self):
        # A worker holds it right now; resetting to todo would double-launch.
        rec = self._install([
            {"tasks": [{
                "id": "t1", "tags": [{"name": "upsert:g:k"}, {"name": "gen:g"}],
                "status": {"status": "in progress", "type": "custom"},
            }]},
            {},
        ])
        clickup_upsert.upsert_task(list_id="L1", gen_id="g", key="k", title="T")
        self.assertNotIn("status", rec.find("PUT", "/task/t1")[0]["body"])

    def test_does_not_touch_an_already_open_task(self):
        rec = self._install([
            {"tasks": [{
                "id": "t1", "tags": [{"name": "upsert:g:k"}, {"name": "gen:g"}],
                "status": {"status": "todo", "type": "open"},
            }]},
            {},
        ])
        clickup_upsert.upsert_task(list_id="L1", gen_id="g", key="k", title="T")
        self.assertNotIn("status", rec.find("PUT", "/task/t1")[0]["body"])

    def test_reopen_status_is_configurable(self):
        os.environ["CLICKUP_TODO_STATUS"] = "to do"
        rec = self._install([
            {"tasks": [{
                "id": "t1", "tags": [{"name": "upsert:g:k"}, {"name": "gen:g"}],
                "status": {"status": "complete", "type": "closed"},
            }]},
            {},
        ])
        clickup_upsert.upsert_task(list_id="L1", gen_id="g", key="k", title="T")
        self.assertEqual(rec.find("PUT", "/task/t1")[0]["body"]["status"], "to do")

    def test_missing_tags_are_re_added_on_update(self):
        # PUT /task does not touch tags, so a lost routing tag never returns.
        rec = self._install([
            {"tasks": [{
                "id": "t1", "tags": [{"name": "upsert:g:k"}],
                "status": {"status": "todo", "type": "open"},
            }]},
            {}, {}, {},
        ])
        clickup_upsert.upsert_task(
            list_id="L1", gen_id="g", key="k", title="T", extra_tags=["auto-worker"],
        )
        added = [c["path"] for c in rec.find("POST", "/tag/")]
        self.assertIn("/task/t1/tag/auto-worker", added)
        self.assertIn("/task/t1/tag/gen%3Ag", added)  # url-encoded
        self.assertNotIn("/task/t1/tag/upsert%3Ag%3Ak", added)  # already present

    def test_tag_failure_does_not_break_the_upsert(self):
        class _Flaky(_Recorder):
            def __call__(self, method, path, body=None, timeout=15):
                if "/tag/" in path:
                    raise RuntimeError("ClickUp API 400: tag rejected")
                return super().__call__(method, path, body, timeout)

        rec = _Flaky([
            {"tasks": [{
                "id": "t1", "tags": [],
                "status": {"status": "todo", "type": "open"},
            }]},
            {},
        ])
        clickup_upsert._request = rec
        self.assertEqual(
            clickup_upsert.upsert_task(list_id="L1", gen_id="g", key="k", title="T"),
            "t1",
        )

    # --- close --------------------------------------------------------------
    def test_close_uses_configured_done_status(self):
        os.environ["CLICKUP_DONE_STATUS"] = "complete"
        rec = self._install([{}])
        clickup_upsert.close_task("t1")
        self.assertEqual(rec.calls[0]["body"], {"status": "complete"})

    def test_close_explicit_status_wins(self):
        rec = self._install([{}])
        clickup_upsert.close_task("t1", "archived")
        self.assertEqual(rec.calls[0]["body"], {"status": "archived"})

    # --- configuration ------------------------------------------------------
    def test_nothing_is_hardcoded_team_id_is_required(self):
        del os.environ["CLICKUP_TEAM_ID"]
        with self.assertRaises(RuntimeError) as cm:
            clickup_upsert._team_id()
        self.assertIn("CLICKUP_TEAM_ID", str(cm.exception))

    def test_token_missing_raises(self):
        del os.environ["CLICKUP_API_TOKEN"]
        with self.assertRaises(RuntimeError) as cm:
            clickup_upsert._token()
        self.assertIn("CLICKUP_API_TOKEN", str(cm.exception))

    def test_settings_fall_back_to_the_env_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write(
                "# comment line\n"
                "\n"
                'export CLICKUP_PERSONAL_TOKEN="tok-from-file"\n'
                "CLICKUP_TEAM_ID='team-from-file'\n"
            )
            path = f.name
        self.addCleanup(os.unlink, path)
        os.environ["AGENT_OS_ENV_FILE"] = path
        del os.environ["CLICKUP_API_TOKEN"]
        del os.environ["CLICKUP_TEAM_ID"]
        clickup_upsert._env_file_cache.clear()
        # export prefix stripped, quotes stripped, both key spellings honoured.
        self.assertEqual(clickup_upsert._token(), "tok-from-file")
        self.assertEqual(clickup_upsert._team_id(), "team-from-file")

    def test_process_env_wins_over_the_env_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("CLICKUP_API_TOKEN=tok-from-file\n")
            path = f.name
        self.addCleanup(os.unlink, path)
        os.environ["AGENT_OS_ENV_FILE"] = path
        os.environ["CLICKUP_API_TOKEN"] = "tok-from-env"
        clickup_upsert._env_file_cache.clear()
        self.assertEqual(clickup_upsert._token(), "tok-from-env")

    def test_api_token_takes_precedence_over_personal_token(self):
        os.environ["CLICKUP_API_TOKEN"] = "tok-api"
        os.environ["CLICKUP_PERSONAL_TOKEN"] = "tok-personal"
        self.assertEqual(clickup_upsert._token(), "tok-api")

    def test_status_defaults(self):
        self.assertEqual(clickup_upsert._todo_status(), "todo")
        self.assertEqual(clickup_upsert._done_status(), "done")


if __name__ == "__main__":
    unittest.main(verbosity=2)
