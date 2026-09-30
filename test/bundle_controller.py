#!/usr/bin/env python3
"""bin/bundles.py, the vendor bundle controller, against a scripted GitHub API.

The controller runs as it does in CI: a subprocess talking HTTP, here to a local server whose
answers each test scripts, from a synthetic overlay checkout. Ledger lines move between runs the
way autobump.yml moves them, through the plan's delta and collect.
"""

import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest


BUNDLES = Path(__file__).resolve().parents[1] / "bin" / "bundles.py"


def load_bundles():
    # bin/ is not the place for a __pycache__
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("bundles", BUNDLES)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bundles = load_bundles()

OVERLAY_TOML = """\
["cat/drafts"]
autobump = true
bundle = [
  { id = "node_modules", repo = "gentoo-zh-drafts/drafts", workflow = "node_modules.yml", tag = "v{bundle_pv}", inputs = { version = "{bundle_pv}" } },
]
bundle_pv = [["_rc", "-rc."]]

["cat/deps"]
source = "github"
github = "up/deps"
deps = "golang"

["cat/ready"]
autobump = true
bundle = [
  { id = "crates", repo = "gentoo-zh/gentoo-deps", workflow = "generator.yml", tag = "{P}" },
]

["cat/plain"]
autobump = true

["cat/pair"]
bundle = [
  { id = "service", repo = "gentoo-zh-drafts/pair", workflow = "service.yml", tag = "{P}" },
  { id = "core", repo = "gentoo-zh-drafts/pair", workflow = "core.yml", tag = "core-{PV}" },
]
"""

DRAFTS = "/repos/gentoo-zh-drafts/drafts"
DEPS = "/repos/gentoo-zh/gentoo-deps"
DRAFTS_RUNS = f"{DRAFTS}/actions/workflows/node_modules.yml/runs?per_page=100"
DEPS_RUNS = f"{DEPS}/actions/workflows/generator.yml/runs?per_page=100"
DRAFTS_TAG = f"{DRAFTS}/releases/tags/v1.0-rc.2"
DEPS_TAG = f"{DEPS}/releases/tags/deps-2.0"
READY_TAG = f"{DEPS}/releases/tags/ready-3.0"
DRAFTS_DISPATCH = f"{DRAFTS}/actions/workflows/node_modules.yml/dispatches"
DEPS_DISPATCH = f"{DEPS}/actions/workflows/generator.yml/dispatches"
PAIR = "/repos/gentoo-zh-drafts/pair"
SERVICE_RUNS = f"{PAIR}/actions/workflows/service.yml/runs?per_page=100"
CORE_RUNS = f"{PAIR}/actions/workflows/core.yml/runs?per_page=100"
SERVICE_TAG = f"{PAIR}/releases/tags/pair-5.0"
CORE_TAG = f"{PAIR}/releases/tags/core-5.0"
SERVICE_DISPATCH = f"{PAIR}/actions/workflows/service.yml/dispatches"
CORE_DISPATCH = f"{PAIR}/actions/workflows/core.yml/dispatches"


def run(status, title, *, branch="main", conclusion=None, created="2026-09-30T01:00:00Z",
        updated="2026-09-30T01:20:00Z", number=1):
    return {"id": number, "status": status, "conclusion": conclusion, "head_branch": branch,
            "display_title": title, "html_url": f"https://github.com/x/y/actions/runs/{number}",
            "created_at": created, "updated_at": updated}


def runs(*items):
    return (200, {}, {"workflow_runs": list(items)})


RELEASED = (200, {}, {"html_url": "https://github.com/x/y/releases/tag/t"})
MISSING = (404, {}, {"message": "Not Found"})
ACCEPTED = (204, {}, None)
REPO = (200, {}, {"default_branch": "main"})
# payloads the fake cannot send as JSON: the connection closes before a reply, or inside its body
DROPPED = "dropped"
TRUNCATED = "truncated"


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    def reply(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        self.server.calls.append((method, self.path, self.headers.get("Authorization"), body))
        answers = self.server.routes.get((method, self.path))
        if not answers:
            status, headers, payload = 404, {}, {"message": "Not Found"}
        else:
            status, headers, payload = answers[0] if len(answers) == 1 else answers.pop(0)
        if payload == DROPPED:
            self.close_connection = True
            return
        data = b"" if payload in (None, TRUNCATED) else json.dumps(payload).encode()
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data) + 100 if payload == TRUNCATED else len(data)))
        self.close_connection = payload == TRUNCATED
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply("GET")

    def do_POST(self):
        self.reply("POST")

    def log_message(self, *args):
        pass


class Harness(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        self.server.routes, self.server.calls = {}, []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.tmp = Path(self.tempdir.name)
        self.repo = self.tmp / "overlay"
        (self.repo / ".github" / "workflows").mkdir(parents=True)
        (self.repo / ".github" / "workflows" / "overlay.toml").write_text(OVERLAY_TOML)
        self.state = self.tmp / "state"
        self.ledger = self.state / "autobump" / "bundles"
        self.ledger.parent.mkdir(parents=True)
        self.ledger.touch()
        self.run_id = 0

    def route(self, method, path, *answers):
        self.server.routes[(method, path)] = list(answers)

    def posts(self, path=None):
        return [c for c in self.server.calls if c[0] == "POST" and (path is None or c[1] == path)]

    def environment(self, **extra):
        self.run_id += 1
        environment = {
            "PATH": os.environ["PATH"],
            "BUNDLES_API_URL": f"http://127.0.0.1:{self.server.server_address[1]}",
            "GITHUB_ACTIONS": "true",
            "GITHUB_RUN_ID": str(self.run_id),
            "GH_TOKEN_GENTOO_ZH": "token-zh",
            "GH_TOKEN_GENTOO_ZH_DRAFTS": "token-drafts",
        }
        return environment | extra

    def controller(self, *args, **extra):
        return subprocess.run([sys.executable, str(BUNDLES), *args],
                              cwd=self.repo, env=self.environment(**extra), capture_output=True, text=True)

    def plan(self, targets, **extra):
        """One autobump plan of the controller; its delta lands in the ledger as collect would."""
        path = self.tmp / "targets.json"
        path.write_text(json.dumps(targets))
        result = self.controller("plan", "--targets", str(path), "--ledger", str(self.ledger),
                                 "--out", str(self.tmp / "bundles.json"), "--delta", str(self.tmp / "delta.json"),
                                 **extra)
        delta = json.loads((self.tmp / "delta.json").read_text())
        # collect merges a line it already holds once
        seen = set(self.ledger.read_text().splitlines())
        with self.ledger.open("a") as f:
            for line in delta["bundles"]:
                if line not in seen:
                    f.write(line + "\n")
                    seen.add(line)
        snapshot = json.loads((self.tmp / "bundles.json").read_text())
        return result, {t["package"]: t for t in snapshot["targets"]}, snapshot

    def ledger_kinds(self):
        return [line.split()[2] for line in self.ledger.read_text().splitlines()]


DRAFTS_TARGET = {"issue": "1", "package": "cat/drafts", "version": "1.0_rc2"}
DEPS_TARGET = {"issue": "2", "package": "cat/deps", "version": "2.0"}


class ControllerTest(Harness):
    def test_accepted_invisible_queued_ready(self):
        self.route("GET", DRAFTS, REPO)
        self.route("POST", DRAFTS_DISPATCH, ACCEPTED)
        # accepted: nothing released, nothing running
        self.route("GET", DRAFTS_TAG, MISSING)
        self.route("GET", DRAFTS_RUNS, runs())
        _, first, _ = self.plan([DRAFTS_TARGET])
        self.assertEqual(first["cat/drafts"]["state"], "pending")
        self.assertEqual(first["cat/drafts"]["dispatched"], ["node_modules"])
        self.assertEqual(self.posts()[0][3], {"ref": "main", "inputs": {"version": "1.0-rc.2"}})
        self.assertEqual(self.posts()[0][2], "Bearer token-drafts")

        # invisible: the dispatch has not produced a visible run yet
        _, second, _ = self.plan([DRAFTS_TARGET])
        self.assertEqual(second["cat/drafts"]["state"], "pending")

        # queued: the run shows up under its run-name
        self.route("GET", DRAFTS_RUNS, runs(run("queued", "deepseek-harness 1.0-rc.2", number=5)))
        _, third, _ = self.plan([DRAFTS_TARGET])
        self.assertEqual(third["cat/drafts"]["state"], "pending")
        self.assertEqual(third["cat/drafts"]["dispatched"], [])
        self.assertEqual(third["cat/drafts"]["bundles"][0]["producers"][0]["status"], "queued")

        # ready: released and the producer finished
        self.route("GET", DRAFTS_TAG, RELEASED)
        self.route("GET", DRAFTS_RUNS, runs(run("completed", "deepseek-harness 1.0-rc.2", conclusion="success", number=5)))
        _, fourth, _ = self.plan([DRAFTS_TARGET])
        self.assertEqual(fourth["cat/drafts"]["state"], "ready")
        self.assertEqual(len(self.posts()), 2)
        self.assertEqual(self.ledger_kinds().count("escalate"), 0)

    def test_persistent_pending_escalates_once_after_four_observations(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs(run("in_progress", "deps-2.0 v2.0")))
        states = []
        for _ in range(5):
            _, targets, _ = self.plan([DEPS_TARGET])
            states.append((targets["cat/deps"]["state"], targets["cat/deps"]["escalated_now"]))
        self.assertEqual(states, [("pending", False)] * 3 + [("escalate", True), ("escalate", False)])
        self.assertEqual(self.posts(), [])
        self.assertEqual(self.ledger_kinds().count("observe"), 4)

    def test_a_retry_starts_the_count_over(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs(run("in_progress", "deps-2.0 v2.0")))
        for _ in range(4):
            self.plan([DEPS_TARGET])
        _, targets, _ = self.plan([DEPS_TARGET | {"retry": True}])
        self.assertEqual((targets["cat/deps"]["state"], targets["cat/deps"]["observations"]), ("pending", 1))

    def test_ready_bundle_hands_the_engine_its_producer(self):
        # the engine escalates a wrong filename from these: success, run URL, completion time
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs(run("completed", "ready-3.0 v3.0", conclusion="success", number=7)))
        _, targets, _ = self.plan([{"issue": "3", "package": "cat/ready", "version": "3.0"}])
        bundle = targets["cat/ready"]["bundles"][0]
        self.assertEqual(targets["cat/ready"]["state"], "ready")
        self.assertEqual(bundle["release_tag"], "ready-3.0")
        self.assertEqual(bundle["producers"], [{
            "workflow": "generator.yml", "run_url": "https://github.com/x/y/actions/runs/7",
            "status": "completed", "conclusion": "success", "completed_at": "2026-09-30T01:20:00Z"}])
        self.assertEqual(self.ledger_kinds(), [])

    def test_a_released_bundle_with_no_run_history_is_ready_without_success_evidence(self):
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        _, targets, _ = self.plan([{"package": "cat/ready", "version": "3.0"}])
        self.assertEqual(targets["cat/ready"]["state"], "ready")
        self.assertEqual(targets["cat/ready"]["bundles"][0]["producers"][0]["status"], "missing")

    def test_api_failures_are_unknown_uncounted_and_never_dispatch(self):
        # rate limiting waits for the next run; anything else fails this one
        cases = [
            (401, {}, 1),
            (403, {"x-ratelimit-remaining": "0"}, 0),
            (429, {"retry-after": "60"}, 0),
            (502, {}, 1),
        ]
        for status, headers, code in cases:
            with self.subTest(status=status):
                self.server.calls.clear()
                self.ledger.write_text("")
                self.route("GET", DEPS_TAG, (status, headers, {"message": "nope"}))
                self.route("GET", DEPS_RUNS, runs())
                result, targets, _ = self.plan([DEPS_TARGET])
                self.assertEqual(targets["cat/deps"]["state"], "unknown")
                self.assertEqual(self.ledger_kinds(), [])
                self.assertEqual(self.posts(), [])
                self.assertEqual(result.returncode, code, result.stderr)

    def test_a_reply_cut_short_is_unknown_and_the_plan_goes_on(self):
        self.route("GET", DRAFTS_RUNS, runs())
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        for status in (200, 502):
            with self.subTest(status=status):
                (self.tmp / "delta.json").unlink(missing_ok=True)
                self.route("GET", DRAFTS_TAG, (status, {}, TRUNCATED))
                result, targets, _ = self.plan([DRAFTS_TARGET, {"package": "cat/ready", "version": "3.0"}])
                self.assertEqual(targets["cat/drafts"]["state"], "unknown")
                self.assertEqual(targets["cat/ready"]["state"], "ready")
                self.assertEqual(result.returncode, 1)

    def test_an_unreadable_run_list_is_unknown_not_empty(self):
        # read as no runs, a release whose producer is still at work would pass as ready
        self.route("GET", READY_TAG, RELEASED)
        for body in ({"total_count": 1}, {"workflow_runs": ["ready-3.0"]}):
            with self.subTest(body=body):
                self.route("GET", DEPS_RUNS, (200, {}, body))
                _, targets, _ = self.plan([{"package": "cat/ready", "version": "3.0"}])
                self.assertEqual(targets["cat/ready"]["state"], "unknown")
                self.assertIn("unreadable run list", targets["cat/ready"]["reason"])

    def test_a_release_read_refused_to_the_app_token_is_retried_anonymously(self):
        self.route("GET", READY_TAG, (403, {}, {"message": "Resource not accessible by integration"}), RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        _, targets, _ = self.plan([{"package": "cat/ready", "version": "3.0"}])
        self.assertEqual(targets["cat/ready"]["state"], "ready")
        auth = [c[2] for c in self.server.calls if c[1] == READY_TAG]
        self.assertEqual(auth, ["Bearer token-zh", None])

    def stop_one_owner(self, answer):
        """gentoo-zh answers the first read with `answer`; gentoo-zh-drafts works."""
        self.route("GET", DEPS_TAG, answer)
        self.route("GET", DRAFTS_TAG, MISSING)
        self.route("GET", DRAFTS_RUNS, runs())
        self.route("GET", DRAFTS, REPO)
        self.route("POST", DRAFTS_DISPATCH, ACCEPTED)
        result, targets, _ = self.plan([DEPS_TARGET, {"package": "cat/ready", "version": "3.0"}, DRAFTS_TARGET])
        self.assertEqual(targets["cat/deps"]["state"], "unknown")
        # the same owner is not asked again once it said stop
        self.assertEqual(targets["cat/ready"]["state"], "unknown")
        self.assertFalse(any(c[1] == READY_TAG for c in self.server.calls))
        self.assertEqual(targets["cat/drafts"]["state"], "pending")
        self.assertEqual(len(self.posts(DRAFTS_DISPATCH)), 1)
        return result

    def test_a_rate_limited_owner_waits_for_the_next_run(self):
        result = self.stop_one_owner((429, {"retry-after": "600"}, {"message": "slow down"}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: gentoo-zh: stopped asking after HTTP 429", result.stderr)
        self.assertNotIn("failed:", result.stderr)

    def test_a_refused_token_fails_the_run(self):
        result = self.stop_one_owner((401, {}, {"message": "Bad credentials"}))
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed: gentoo-zh: stopped asking after HTTP 401", result.stderr)

    def test_a_server_error_fails_the_run_even_when_rate_limiting_follows(self):
        self.route("GET", READY_TAG, RELEASED)
        cases = [
            ("alone", runs(), "ready"),
            ("rate limited after it", (429, {"retry-after": "60"}, {"message": "slow down"}), "unknown"),
        ]
        for name, answer, ready in cases:
            with self.subTest(name):
                self.server.calls.clear()
                self.route("GET", DEPS_TAG, (502, {}, {"message": "Server Error"}))
                self.route("GET", DEPS_RUNS, answer)
                result, targets, _ = self.plan([DEPS_TARGET, {"package": "cat/ready", "version": "3.0"}])
                self.assertEqual(targets["cat/deps"]["state"], "unknown")
                self.assertEqual(targets["cat/ready"]["state"], ready)
                self.assertEqual(result.returncode, 1)
                self.assertIn("failed: cat/deps 2.0: gentoo-zh/gentoo-deps@deps-2.0: HTTP 502", result.stderr)

    def test_a_rate_limited_dispatch_is_uncounted_and_waits(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, (403, {"x-ratelimit-remaining": "0"}, {"message": "API rate limit exceeded"}))
        result, targets, _ = self.plan([DEPS_TARGET])
        self.assertEqual(targets["cat/deps"]["state"], "unknown")
        self.assertEqual(self.ledger_kinds(), [])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_broken_entry_does_not_stop_the_other_packages(self):
        toml = self.repo / ".github" / "workflows" / "overlay.toml"
        toml.write_text(toml.read_text().replace('deps = "golang"', 'deps = "cobol"'))
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        result, targets, _ = self.plan([DEPS_TARGET, {"package": "cat/ready", "version": "3.0"}])
        self.assertIn("deps lang 'cobol'", targets["cat/deps"]["bundles"][0]["reason"])
        self.assertTrue(targets["cat/deps"]["escalated_now"])
        self.assertEqual(targets["cat/ready"]["state"], "ready")
        self.assertEqual(result.returncode, 1)

    def test_at_most_three_dispatches_per_version(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, ACCEPTED)
        for _ in range(5):
            self.plan([DEPS_TARGET])
        self.assertEqual(len(self.posts(DEPS_DISPATCH)), 3)
        self.assertEqual(self.posts(DEPS_DISPATCH)[0][3]["inputs"], {"LANG": "golang", "REPO": "up/deps", "TAG": "2.0", "P": "deps-2.0"})

    def test_two_issues_for_one_version_share_its_dispatches(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, ACCEPTED)
        for _ in range(5):
            _, _, snapshot = self.plan([DEPS_TARGET, DEPS_TARGET | {"issue": "9"}])
            self.assertEqual(len(snapshot["targets"]), 1)
        self.assertEqual(len(self.posts(DEPS_DISPATCH)), 3)

    def test_each_bundle_counts_its_own_dispatches(self):
        # service is never produced; core runs through three plans, then fails and needs a dispatch
        self.route("GET", PAIR, REPO)
        self.route("GET", SERVICE_TAG, MISSING)
        self.route("GET", SERVICE_RUNS, runs())
        self.route("POST", SERVICE_DISPATCH, ACCEPTED)
        self.route("GET", CORE_TAG, MISSING)
        self.route("GET", CORE_RUNS, *[runs(run("in_progress", "core-5.0"))] * 3,
                   runs(run("completed", "core-5.0", conclusion="failure")))
        self.route("POST", CORE_DISPATCH, ACCEPTED)
        for _ in range(4):
            self.plan([{"issue": "5", "package": "cat/pair", "version": "5.0"}])
        self.assertEqual(len(self.posts(SERVICE_DISPATCH)), 3)
        self.assertEqual(len(self.posts(CORE_DISPATCH)), 1)
        dispatches = [line.split() for line in self.ledger.read_text().splitlines() if " dispatch " in line]
        self.assertEqual([fields[5] for fields in dispatches], ["service"] * 3 + ["core"])

    def test_a_dispatch_counts_unless_github_refused_it(self):
        # a lost reply or a 5xx may still have queued the run; a 4xx says it did not
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, (204, {}, DROPPED), (502, {}, {"message": "Server Error"}),
                   (403, {}, {"message": "Resource not accessible by integration"}), (204, {}, DROPPED))
        states = [self.plan([DEPS_TARGET])[1]["cat/deps"]["state"] for _ in range(5)]
        self.assertEqual(states, ["unknown"] * 4 + ["pending"])
        self.assertEqual(len(self.posts(DEPS_DISPATCH)), 4)
        self.assertEqual(self.ledger_kinds(), ["dispatch"] * 3 + ["observe"])

    def test_a_rerun_counts_the_dispatches_of_its_earlier_attempts(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, ACCEPTED)
        for attempt in range(1, 6):
            self.plan([DEPS_TARGET], GITHUB_RUN_ID="42", GITHUB_RUN_ATTEMPT=str(attempt))
        self.assertEqual(len(self.posts(DEPS_DISPATCH)), 3)

    def test_a_ready_target_clears_its_escalation(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs(run("in_progress", "deps-2.0 v2.0")))
        for _ in range(4):
            _, targets, _ = self.plan([DEPS_TARGET])
        self.assertEqual(targets["cat/deps"]["state"], "escalate")
        self.route("GET", DEPS_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs(run("completed", "deps-2.0 v2.0", conclusion="success")))
        _, targets, _ = self.plan([DEPS_TARGET])
        self.assertEqual(targets["cat/deps"]["state"], "ready")
        self.assertEqual(self.ledger_kinds()[-1], "reset")
        # a maintainer reruns the producer: the target waits again instead of staying escalated
        self.route("GET", DEPS_RUNS, runs(run("in_progress", "deps-2.0 v2.0", created="2026-09-30T03:00:00Z", number=2)))
        _, targets, _ = self.plan([DEPS_TARGET])
        self.assertEqual((targets["cat/deps"]["state"], targets["cat/deps"]["observations"]), ("pending", 1))

    def test_a_ready_target_starts_a_later_wait_over(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs(run("in_progress", "deps-2.0 v2.0")))
        for _ in range(3):
            self.plan([DEPS_TARGET])
        self.route("GET", DEPS_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs(run("completed", "deps-2.0 v2.0", conclusion="success")))
        self.plan([DEPS_TARGET])
        self.route("GET", DEPS_RUNS, runs(run("in_progress", "deps-2.0 v2.0", created="2026-09-30T03:00:00Z", number=2)))
        _, targets, _ = self.plan([DEPS_TARGET])
        self.assertEqual((targets["cat/deps"]["state"], targets["cat/deps"]["observations"]), ("pending", 1))

    def test_an_older_run_still_at_work_keeps_a_release_pending(self):
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs(
            run("completed", "ready-3.0", conclusion="success", created="2026-09-30T02:00:00Z", number=2),
            run("in_progress", "ready-3.0", created="2026-09-30T01:00:00Z", number=1)))
        _, targets, _ = self.plan([{"package": "cat/ready", "version": "3.0"}])
        self.assertEqual(targets["cat/ready"]["state"], "pending")
        producer, = targets["cat/ready"]["bundles"][0]["producers"]
        self.assertEqual((producer["status"], producer["run_url"]), ("in_progress", "https://github.com/x/y/actions/runs/1"))

    def test_an_owner_without_a_token_is_not_dispatched_anonymously(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, ACCEPTED)
        self.route("GET", DRAFTS_TAG, MISSING)
        self.route("GET", DRAFTS_RUNS, runs())
        self.route("GET", DRAFTS, REPO)
        self.route("POST", DRAFTS_DISPATCH, ACCEPTED)
        # a failed token mint leaves its output empty
        result, targets, _ = self.plan([DEPS_TARGET, DRAFTS_TARGET], GH_TOKEN_GENTOO_ZH="")
        self.assertEqual(self.posts(DEPS_DISPATCH), [])
        self.assertEqual(targets["cat/deps"]["state"], "unknown")
        self.assertEqual(len(self.posts(DRAFTS_DISPATCH)), 1)
        self.assertEqual(targets["cat/drafts"]["state"], "pending")
        self.assertEqual(result.returncode, 1)

    def test_a_refused_dispatch_escalates(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, (422, {}, {"message": "Unexpected inputs provided"}))
        _, targets, _ = self.plan([DEPS_TARGET])
        self.assertEqual(targets["cat/deps"]["state"], "escalate")
        self.assertIn("refused the dispatch", targets["cat/deps"]["bundles"][0]["reason"])

    def test_status_never_writes_or_dispatches(self):
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        result = self.controller("status", "cat/deps", "--version", "2.0", "--out", str(self.tmp / "s.json"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        target, = json.loads((self.tmp / "s.json").read_text())["targets"]
        self.assertEqual(target["state"], "pending")
        self.assertIn("prepare would dispatch", target["bundles"][0]["reason"])

    def test_prepare_skips_an_existing_release(self):
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        result = self.controller("prepare", "cat/ready", "--version", "3.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])

    def test_snapshot_follows_schema_1(self):
        self.route("GET", DRAFTS_TAG, MISSING)
        self.route("GET", DRAFTS_RUNS, runs(run("waiting", "deepseek-harness 1.0-rc.2")))
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs(run("completed", "ready-3.0", conclusion="odd", updated="yesterday")))
        _, _, snapshot = self.plan([DRAFTS_TARGET, {"package": "cat/ready", "version": "3.0"}])
        self.assertEqual(snapshot["schema"], 1)
        self.assertEqual(snapshot["controller_run"], str(self.run_id))
        self.assertRegex(snapshot["observed_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        for target in snapshot["targets"]:
            self.assertIn(target["state"], {"ready", "pending", "unknown", "escalate"})
            self.assertTrue(target["bundles"])
            for bundle in target["bundles"]:
                self.assertTrue({"id", "repo", "release_tag", "state", "reason", "producers", "release_url"} <= set(bundle))
                self.assertNotIn("/", bundle["release_tag"])
                for producer in bundle["producers"]:
                    self.assertIn(producer["status"], {"queued", "in_progress", "completed", "missing"})
                    self.assertTrue(producer["completed_at"] is None
                                    or re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", producer["completed_at"]))
        # a producer carries one of these or None; each must be one autobump-rb's BundleStatus accepts
        self.assertLessEqual(bundles.CONCLUSIONS, {"success", "failure", "cancelled", "skipped", "timed_out", "neutral",
                                                   "action_required", "stale", "startup_failure"})
        drafts, ready = snapshot["targets"]
        # waiting has not started either; an unknown conclusion is no evidence
        self.assertEqual(drafts["bundles"][0]["producers"][0]["status"], "queued")
        self.assertEqual(ready["bundles"][0]["producers"][0]["conclusion"], None)
        self.assertEqual(ready["bundles"][0]["producers"][0]["completed_at"], "2026-09-30T01:00:00Z")


    def test_overlay_names_the_checkout_to_read(self):
        (self.repo / "cat" / "ready").mkdir(parents=True)
        (self.repo / "cat" / "ready" / "ready-3.0.ebuild").touch()
        result = subprocess.run([sys.executable, str(BUNDLES), "where", "cat/ready", "--overlay", str(self.repo)],
                                cwd=self.tmp, env=self.environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "cat/ready 3.0")


class IndexTest(unittest.TestCase):
    def parse(self, text):
        return bundles.parse_package(__import__("tomllib").loads(text)["p"])

    def test_invalid_entries_are_refused(self):
        entry = 'id = "v", repo = "gentoo-zh/gentoo-deps", workflow = "g.yml", tag = "{P}"'
        cases = {
            "unknown template": entry.replace("{P}", "{V}"),
            "bad owner": entry.replace("gentoo-zh/", "someone/"),
            "bad workflow": entry.replace("g.yml", "g.sh"),
            "empty field": entry.replace('tag = "{P}"', 'tag = ""'),
            "unknown key": entry + ', asset = "x"',
            # the dispatched run would never be seen, so each plan would dispatch again
            "producers without workflow": entry + ', producers = ["h.yml"]',
        }
        for name, text in cases.items():
            with self.subTest(name):
                with self.assertRaises(bundles.ConfigError):
                    self.parse(f'[p]\nbundle = [{{ {text} }}]\n')
        with self.assertRaises(bundles.ConfigError):
            self.parse(f'[p]\nbundle = [{{ {entry} }}, {{ {entry} }}]\n')

    def test_templates_and_the_version_rewrite(self):
        spec = self.parse(textwrap.dedent('''\
            [p]
            bundle = [{ id = "n", repo = "gentoo-zh-drafts/d", workflow = "n.yml", tag = "v{bundle_pv}", inputs = { version = "{bundle_pv}", p = "{P}" } }]
            bundle_pv = [["_rc", "-rc."]]
            '''))
        b, = bundles.expanded_bundles(spec, "dev-util/deepseek-harness", "0.2.0_rc2")
        self.assertEqual(b["tag"], "v0.2.0-rc.2")
        self.assertEqual(b["inputs"], {"version": "0.2.0-rc.2", "p": "deepseek-harness-0.2.0_rc2"})
        self.assertEqual(b["producers"], ["n.yml"])

    def test_deps_stands_for_its_generator_entries(self):
        gen = 'repo = "gentoo-zh/gentoo-deps", workflow = "generator.yml"'
        cases = [
            ("app-crypt/cotp", 'github = "replydev/cotp"\nprefix = "v"', 'deps = "rust"',
             f'{{ id = "crates", {gen}, tag = "{{P}}", inputs = {{ LANG = "rust", REPO = "replydev/cotp", TAG = "v{{PV}}", P = "{{P}}" }} }}'),
            ("dev-util/fvm", 'github = "leoafarias/fvm"', 'deps = "dart"',
             f'{{ id = "pubcache", {gen}, tag = "{{P}}", inputs = {{ LANG = "dart", REPO = "leoafarias/fvm", TAG = "{{PV}}", P = "{{P}}" }} }}'),
            ("net-dns/ddns-go", 'github = "jeessy2/ddns-go"\nprefix = "v"', 'deps = { lang = "golang", vendordir = "{P}" }',
             f'{{ id = "vendor", {gen}, tag = "{{P}}", inputs = {{ LANG = "golang", REPO = "jeessy2/ddns-go", TAG = "v{{PV}}", P = "{{P}}", VENDORDIR = "{{P}}" }} }}'),
            ("net-proxy/v2rayA", 'github = "v2rayA/v2rayA"\nprefix = "v"', 'deps = { lang = "golang", modules = ["service", "core"] }',
             ", ".join(f'{{ id = "{m}", {gen}, tag = "v2rayA-{m}-{{PV}}", inputs = {{ LANG = "golang", REPO = "v2rayA/v2rayA", TAG = "v{{PV}}", P = "v2rayA-{m}-{{PV}}", WORKDIR = "{m}", VENDORDIR = "{{P}}/{m}" }} }}'
                       for m in ("service", "core"))),
            ("net-proxy/zashboard", 'github = "Zephyruso/zashboard"\nprefix = "v"', 'deps = "javascript"',
             f'{{ id = "node_modules", {gen}, tag = "{{P}}", inputs = {{ LANG = "javascript", REPO = "Zephyruso/zashboard", TAG = "v{{PV}}", P = "{{P}}" }} }}'),
        ]
        for package, tracker, deps, full in cases:
            with self.subTest(package):
                short = self.parse(f'[p]\nsource = "github"\n{tracker}\n{deps}\n')
                long = self.parse(f'[p]\nsource = "github"\n{tracker}\nbundle = [{full}]\n')
                self.assertEqual(bundles.expanded_bundles(short, package, "2.5.8"),
                                 bundles.expanded_bundles(long, package, "2.5.8"))

    def test_invalid_deps_are_refused(self):
        cases = {
            "unknown lang": 'source = "github"\ngithub = "o/n"\ndeps = "python"',
            "deps and bundle": 'source = "github"\ngithub = "o/n"\ndeps = "rust"\nbundle = []',
            "no repo": 'source = "pypi"\npypi = "n"\ndeps = "rust"',
            # the version nvchecker reports is no longer the tag with its prefix
            "from_pattern without tag": 'source = "github"\ngithub = "o/n"\nfrom_pattern = "_"\ndeps = "rust"',
            "modules with workdir": 'source = "github"\ngithub = "o/n"\ndeps = { lang = "golang", modules = ["a"], workdir = "a" }',
            "unknown key": 'source = "github"\ngithub = "o/n"\ndeps = { lang = "rust", dir = "a" }',
        }
        for name, text in cases.items():
            with self.subTest(name):
                with self.assertRaises(bundles.ConfigError):
                    self.parse(f'[p]\n{text}\n')

    def test_run_names_match_whole_words_only(self):
        bundle = {"tag": "v1.2", "p": "x-1.2"}
        match = lambda title, branch="main": bundles.run_matches({"display_title": title, "head_branch": branch}, bundle)
        self.assertTrue(match("x 1.2"))
        self.assertTrue(match("dart-sdk-v1.2"))
        self.assertTrue(match("anything", branch="v1.2"))
        self.assertFalse(match("x 1.2.1"))
        self.assertFalse(match("x v1.2-beta.1"))
        self.assertFalse(match("x 11.2"))

    def test_the_tree_version_skips_live_ebuilds_only(self):
        with tempfile.TemporaryDirectory() as root:
            package = Path(root, "cat", "pkg")
            package.mkdir(parents=True)
            for version in ("8.1-r2", "9", "9999-r1", "99999999"):
                (package / f"pkg-{version}.ebuild").touch()
            self.assertEqual(bundles.tree_version("cat/pkg", root), "9")



if __name__ == "__main__":
    unittest.main()
