#!/usr/bin/env python3
"""bin/wait.py, the bundle waiter, against a scripted GitHub API and a fake clock.

The waiter runs in this process so its sleeps only move the clock; GitHub, the artifact blobs and
the release assets are one local server whose answers each test scripts.
"""

import contextlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock
import zipfile


WAIT = Path(__file__).resolve().parents[1] / "bin" / "wait.py"


def load_wait():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("wait", WAIT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wait = load_wait()

OVERLAY_TOML = """\
["cat/drafts"]
autobump = true
bundle = [
  { id = "node_modules", repo = "gentoo-zh-drafts/drafts", workflow = "node_modules.yml", tag = "v{PV}" },
]

["cat/manual"]
bundle = [
  { id = "node_modules", repo = "gentoo-zh-drafts/manual", workflow = "node_modules.yml", tag = "v{PV}" },
]

["cat/plain"]
autobump = true

["cat/off"]
autobump = false
"""

OVERLAY = "/repos/gentoo-zh/overlay"
ARTIFACTS = f"{OVERLAY}/actions/runs/77/artifacts?per_page=100&page=1"
RUNS = f"{OVERLAY}/actions/workflows/autobump.yml/runs?per_page=50"
DISPATCHED = f"{RUNS}&event=workflow_dispatch"
DISPATCH = f"{OVERLAY}/actions/workflows/autobump.yml/dispatches"
TAG = "/repos/gentoo-zh-drafts/drafts/releases/tags/v1.0"
PRODUCER = "/repos/gentoo-zh-drafts/drafts/actions/workflows/node_modules.yml/runs?per_page=100"

NOT_FOUND = (404, {}, {"message": "Not Found"})
OPEN = (200, {}, {"state": "open"})
CLOSED = (200, {}, {"state": "closed"})
IDLE = (200, {}, {"workflow_runs": [{"status": "completed", "conclusion": "success",
                                     "created_at": "2020-01-01T00:00:00Z"}]})
RELEASED = (200, {}, {"html_url": "https://github.com/x/y/releases/tag/v1.0"})
BUILT = (200, {}, {"workflow_runs": [{"status": "completed", "conclusion": "success", "head_branch": "v1.0",
                                      "display_title": "drafts 1.0", "created_at": "2026-10-01T00:00:00Z"}]})


def runs(status, conclusion=None, created="2030-01-01T00:00:00Z", issues="3"):
    return (200, {}, {"workflow_runs": [{"status": status, "conclusion": conclusion, "created_at": created,
                                         "display_title": f"autobump issues: {issues}"}]})


def dispatched_runs(status, *issue_sets):
    return (200, {}, {"workflow_runs": [{"status": status, "conclusion": None, "created_at": "2030-01-01T00:00:00Z",
                                         "display_title": f"autobump issues: {issues}"} for issues in issue_sets]})


def archive(name, document):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as z:
        z.writestr(name, json.dumps(document))
    return data.getvalue()


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    def reply(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        self.server.calls.append((method, self.path, self.headers.get("Authorization"), body))
        answers = self.server.routes.get((method, self.path))
        if not answers:
            status, headers, payload = NOT_FOUND
        else:
            status, headers, payload = answers[0] if len(answers) == 1 else answers.pop(0)
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode() if payload else b""
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        self.reply("GET")

    def do_POST(self):
        self.reply("POST")

    def do_HEAD(self):
        self.reply("HEAD")

    def log_message(self, *args):
        pass


class WaitTest(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        self.server.routes, self.server.calls = {}, []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(tempdir.cleanup)
        self.overlay = Path(tempdir.name)
        (self.overlay / ".github" / "workflows").mkdir(parents=True)
        (self.overlay / ".github" / "workflows" / "overlay.toml").write_text(OVERLAY_TOML)
        self.clock = 1_800_000_000.0
        patches = [mock.patch.object(wait.bundles, "API", self.base),
                   mock.patch.object(wait, "now", lambda: self.clock),
                   mock.patch.object(wait, "sleep", self.advance),
                   mock.patch.dict(os.environ, {"GH_TOKEN": "token-overlay", "GITHUB_ACTIONS": "true",
                                                "GH_TOKEN_GENTOO_ZH_DRAFTS": "token-drafts"})]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.artifacts({
            "autobump-bundles": ("bundles.json", {"schema": 1, "targets": [
                {"issue": "1", "package": "cat/drafts", "version": "1.0", "state": "pending"},
                {"issue": "2", "package": "cat/manual", "version": "2.0", "state": "pending"},
                {"issue": "9", "package": "cat/drafts", "version": "0.9", "state": "ready"},
                {"package": "cat/drafts", "version": "0.8", "state": "pending"}]}),
            "autobump-delta-0": ("autobump-delta.json", {"waits": [
                {"issue": "3", "package": "cat/plain", "version": "1.1", "url": f"{self.base}/asset/plain-1.1"},
                {"issue": "4", "package": "cat/off", "version": "1.0", "url": f"{self.base}/asset/off-1.0"}]}),
            "autobump-delta-1": ("autobump-delta.json", {"waits": [
                {"issue": "3", "package": "cat/plain", "version": "1.1", "url": f"{self.base}/asset/plain-1.1"},
                # the sweep writes issues as strings; a number is the same issue
                {"issue": 5, "package": "cat/plain", "version": "1.2", "url": f"{self.base}/asset/plain-1.2"}]}),
            "autobump-delta-plan": ("autobump-delta-plan.json", {"bundles": []}),
            "autobump-evidence-0": ("x.json", {}),
        })
        for issue in ("1", "3", "5"):
            self.route("GET", f"{OVERLAY}/issues/{issue}", OPEN)
        self.route("GET", OVERLAY, (200, {}, {"default_branch": "master"}))
        self.route("GET", RUNS, IDLE)
        self.route("GET", DISPATCHED, dispatched_runs("in_progress", "1 3", "3", "5"))
        self.route("POST", DISPATCH, (204, {}, None))
        self.route("GET", TAG, NOT_FOUND)
        self.route("GET", PRODUCER, (200, {}, {"workflow_runs": []}))

    def advance(self, seconds):
        self.clock += seconds

    def route(self, method, path, *answers):
        self.server.routes[(method, path)] = list(answers)

    def artifacts(self, artifacts):
        listed = []
        for name, (member, document) in artifacts.items():
            listed.append({"name": name, "archive_download_url": f"{self.base}/download/{name}"})
            # the API answers with a redirect to signed storage, which must not see the token
            self.route("GET", f"/download/{name}", (302, {"Location": f"{self.base}/blob/{name}"}, None))
            self.route("GET", f"/blob/{name}", (200, {}, archive(member, document)))
        self.route("GET", ARTIFACTS, (200, {}, {"artifacts": listed}))

    def asset(self, name, *answers):
        self.route("HEAD", f"/asset/{name}", *answers)

    def waiter(self, *extra):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = wait.main(["wait.py", "--repo", "gentoo-zh/overlay", "--run-id", "77",
                              "--overlay", str(self.overlay), *extra])
        return code, output.getvalue()

    def dispatched(self):
        return [c[3]["inputs"]["issues"] for c in self.server.calls if c[0] == "POST"]

    def paths(self):
        return [c[1] for c in self.server.calls]

    def test_items_are_pending_targets_and_waits_of_opted_in_packages(self):
        code, output = self.waiter("--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual([line for line in output.splitlines() if line.startswith("waiting")],
                         ["waiting: #1 cat/drafts 1.0", "waiting: #3 cat/plain 1.1", "waiting: #5 cat/plain 1.2"])
        self.assertNotIn("/download/autobump-evidence-0", self.paths())
        tokens = {c[1].split("/")[1]: c[2] for c in self.server.calls if "autobump-bundles" in c[1]}
        self.assertEqual(tokens, {"download": "Bearer token-overlay", "blob": None})

    def test_ready_items_are_woken_in_one_dispatch_and_only_once(self):
        self.route("GET", TAG, RELEASED)
        self.route("GET", PRODUCER, BUILT)
        self.asset("plain-1.1", (302, {"Location": f"{self.base}/blob-asset/plain-1.1"}, None))
        self.route("HEAD", "/blob-asset/plain-1.1", (200, {}, None))
        self.asset("plain-1.2", NOT_FOUND, NOT_FOUND, (200, {}, None))
        code, output = self.waiter()
        self.assertEqual(code, 0)
        self.assertEqual(self.dispatched(), ["1 3", "5"])
        self.assertNotIn("left waiting", output)
        post = next(c for c in self.server.calls if c[0] == "POST")
        self.assertEqual((post[2], post[3]["ref"]), ("Bearer token-overlay", "master"))

    def test_a_closed_issue_is_dropped(self):
        self.route("GET", f"{OVERLAY}/issues/5", OPEN, CLOSED)
        code, output = self.waiter("--deadline", "600")
        self.assertIn("closed: #5 cat/plain 1.2", output)
        self.assertNotIn("left waiting: #5", output)
        self.assertIn("left waiting: #3 cat/plain 1.1", output)
        self.assertEqual(self.dispatched(), [])

    def test_no_dispatch_while_autobump_is_active(self):
        self.asset("plain-1.1", (200, {}, None))
        self.route("GET", RUNS, runs("in_progress"), runs("queued"), IDLE)
        code, _ = self.waiter("--deadline", "600")
        before = self.paths()[:self.paths().index(DISPATCH)]
        self.assertEqual(before.count(RUNS), 3)
        self.assertEqual(self.dispatched(), ["3"])

    def test_a_woken_run_cancelled_in_the_queue_is_dispatched_again(self):
        self.asset("plain-1.1", (200, {}, None))
        # an older cancelled run is not the one this dispatch started
        self.route("GET", DISPATCHED, runs("cancelled", created="2020-01-01T00:00:00Z"),
                   runs("completed", "cancelled"), runs("queued"), runs("completed", "success"))
        self.waiter("--deadline", "900")
        self.assertEqual(self.dispatched(), ["3", "3"])

    def test_another_waiters_run_is_not_taken_for_this_one(self):
        self.asset("plain-1.1", (200, {}, None))
        # a run another waiter dispatched is in progress; this one's was cancelled in the queue
        self.route("GET", DISPATCHED, dispatched_runs("in_progress", "7"),
                   runs("completed", "cancelled"), runs("in_progress"))
        self.waiter("--deadline", "900")
        self.assertEqual(self.dispatched(), ["3", "3"])

    def test_artifacts_on_a_later_page_are_read(self):
        first = [{"name": f"autobump-evidence-{i}", "archive_download_url": f"{self.base}/none"} for i in range(100)]
        self.route("GET", ARTIFACTS, (200, {}, {"artifacts": first}))
        self.route("GET", f"{OVERLAY}/actions/runs/77/artifacts?per_page=100&page=2", (200, {}, {"artifacts": [
            {"name": "autobump-delta-0", "archive_download_url": f"{self.base}/download/autobump-delta-0"}]}))
        code, output = self.waiter("--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("waiting: #3 cat/plain 1.1", output)
        self.assertNotIn("#1 cat/drafts", output)

    def test_the_deadline_lists_what_is_left(self):
        code, output = self.waiter("--deadline", "600", "--interval", "120")
        self.assertEqual(code, 0)
        self.assertEqual([line for line in output.splitlines() if line.startswith("left")],
                         ["left waiting: #1 cat/drafts 1.0", "left waiting: #3 cat/plain 1.1",
                          "left waiting: #5 cat/plain 1.2"])
        # rounds at 0, 120, ... and the last one at the deadline itself
        self.assertEqual(self.paths().count(f"{OVERLAY}/issues/1"), 6)
        self.assertEqual(self.dispatched(), [])

    def test_dry_run_dispatches_nothing(self):
        self.asset("plain-1.1", (200, {}, None))
        code, output = self.waiter("--dry-run")
        self.assertIn("would dispatch autobump.yml issues=3", output)
        self.assertEqual(self.dispatched(), [])
        self.assertEqual(self.clock, 1_800_000_000.0)

    def test_errors_wait_for_the_next_round(self):
        self.asset("plain-1.1", (502, {}, None), (200, {}, None))
        self.route("GET", f"{OVERLAY}/issues/3", (502, {}, {"message": "bad gateway"}), OPEN)
        code, _ = self.waiter("--deadline", "600")
        self.assertEqual((code, self.dispatched()), (0, ["3"]))

    def test_no_artifacts_is_nothing_to_wait_for(self):
        self.route("GET", ARTIFACTS, (200, {}, {"artifacts": []}))
        self.assertEqual(self.waiter(), (0, ""))
        self.route("GET", ARTIFACTS, (401, {}, {"message": "Bad credentials"}))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stop:
            self.waiter()
        self.assertEqual(stop.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
