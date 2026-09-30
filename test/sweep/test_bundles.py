#!/usr/bin/env python3
"""The overlay's use of bin/bundles.py: the sweep's plan and collect, and the trial's bundle step.

The scripted GitHub API and the synthetic overlay come from test/bundle_controller.py; the
sweep, its helpers and autobump-trial.yml come from the overlay checkout AUTOBUMP_OVERLAY names.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap
import unittest


def overlay_root():
    """The overlay checkout these tests drive; the scripts they test live there, not here."""
    root = os.environ.get("AUTOBUMP_OVERLAY")
    if not root:
        raise SystemExit("set AUTOBUMP_OVERLAY to an overlay checkout")
    return Path(root)


ROOT = overlay_root()


def load(name, path):
    # neither checkout is the place for a __pycache__
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load("bundle_controller", Path(__file__).resolve().parents[1] / "bundle_controller.py")
bundles = controller.bundles
run, runs = controller.run, controller.runs
DEPS, DEPS_TAG, DEPS_RUNS, DEPS_DISPATCH = controller.DEPS, controller.DEPS_TAG, controller.DEPS_RUNS, controller.DEPS_DISPATCH
DRAFTS_TAG, DRAFTS_RUNS, READY_TAG = controller.DRAFTS_TAG, controller.DRAFTS_RUNS, controller.READY_TAG
RELEASED, MISSING, ACCEPTED, REPO = controller.RELEASED, controller.MISSING, controller.ACCEPTED, controller.REPO


GH = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["GH_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")
titles = json.loads(os.environ["GH_TITLES"])
if args[:2] == ["issue", "list"]:
    print("\\n".join(titles))
elif args[:2] == ["issue", "view"]:
    print(titles[args[2]])
elif args[0] == "api" or args[:2] == ["issue", "comment"]:
    pass
else:
    raise SystemExit(f"unexpected gh command: {args!r}")
"""

ENGINE = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ["ENGINE_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
result = {"bundle": True, "exit": 2, "reason": "bundle pending: gentoo-zh/gentoo-deps@ready-3.0 (https://github.com/x/y/actions/runs/7)",
          "bundles": [{"id": "crates", "repo": "gentoo-zh/gentoo-deps", "release_tag": "ready-3.0", "state": "ready",
                       "run_url": "https://github.com/x/y/actions/runs/7"}]}
print("result: " + json.dumps(result))
print("!! " + result["reason"])
raise SystemExit(2)
"""


class Harness(controller.Harness):
    """The controller's harness, plus the overlay's sweep scripts and fakes for gh and the engine."""

    def setUp(self):
        super().setUp()
        (self.repo / "scripts").mkdir()
        for name in ("autobump-sweep.py", "autobump-args.py", "autobump-judge.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.repo / "scripts")
        # a copy, so a test can put a broken controller in its place
        self.bundles = self.tmp / "bundles.py"
        shutil.copy2(controller.BUNDLES, self.bundles)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, text in (("gh", GH), ("engine", ENGINE), ("git", "#!/bin/sh\n")):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        self.titles = {}

    def environment(self, **extra):
        return super().environment(**{
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "AUTOBUMP_REPO": str(self.repo),
            "AUTOBUMP_UPSTREAM_REPO": "test/overlay",
            "AUTOBUMP_ENGINE": str(self.bin / "engine"),
            "AUTOBUMP_BUNDLE_CONTROLLER": str(self.bundles),
            "AUTOBUMP_STATUS_BACKOFF": "0",
            "XDG_STATE_HOME": str(self.state),
            "GH_LOG": str(self.tmp / "gh.log"),
            "ENGINE_LOG": str(self.tmp / "engine.log"),
            "GH_TITLES": json.dumps(self.titles),
        } | extra)

    def sweep(self, *args, **extra):
        return subprocess.run([sys.executable, str(self.repo / "scripts" / "autobump-sweep.py"), *args],
                              cwd=self.repo, env=self.environment(**extra), capture_output=True, text=True)


class IndexTest(unittest.TestCase):
    def test_the_overlay_index_is_valid(self):
        index, errors = bundles.load_index(ROOT / ".github" / "workflows" / "overlay.toml")
        self.assertEqual(errors, {})
        self.assertTrue(index)


def plan_json(result):
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    return json.loads(lines[-1])


class SweepTest(Harness):
    def plan_and_collect(self, *issues):
        plan = self.sweep(*issues, "--plan", "8", "--bundles", str(self.tmp / "bundles.json"),
                          "--bundles-delta", str(self.tmp / "autobump-delta-plan.json"), "--comment")
        self.assertEqual(plan.returncode, 0, plan.stderr)
        parsed = plan_json(plan)
        collect = self.sweep("--collect", json.dumps(parsed), str(self.tmp / "autobump-delta-plan.json"))
        self.assertEqual(collect.returncode, 0, collect.stderr)
        return parsed, collect

    def comments(self):
        log = self.tmp / "gh.log"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return [c[c.index("--body") + 1] for c in calls if c[:2] == ["issue", "comment"]]

    def test_four_zero_shard_runs_escalate_through_collect(self):
        self.titles = {"2": "[nvchecker] cat/deps can be bump to 2.0"}
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs(run("in_progress", "deps-2.0 v2.0", number=9)))
        results = []
        for _ in range(4):
            parsed, _ = self.plan_and_collect()
            self.assertEqual(parsed["matrix"]["include"], [])
            results.append(parsed["results"]["2"])
        self.assertTrue(all(r.startswith("skip (not opted in: no autobump key) · bundle") for r in results))
        self.assertTrue(results[2].endswith("bundle pending"))
        self.assertTrue(results[3].endswith("bundle escalate"))
        escalation, = self.comments()
        self.assertIn("gentoo-zh/gentoo-deps", escalation)
        self.assertIn("https://github.com/x/y/actions/runs/9", escalation)
        self.assertIn("actions/workflows/bundles.yml", escalation)
        self.assertIn("packages=cat/deps", escalation)

    def test_a_target_not_opted_in_is_still_prepared(self):
        self.titles = {"2": "[nvchecker] cat/deps can be bump to 2.0"}
        self.route("GET", DEPS_TAG, MISSING)
        self.route("GET", DEPS_RUNS, runs())
        self.route("GET", DEPS, REPO)
        self.route("POST", DEPS_DISPATCH, ACCEPTED)
        parsed, _ = self.plan_and_collect()
        self.assertEqual(len(self.posts(DEPS_DISPATCH)), 1)
        self.assertEqual(parsed["shards"], [])
        self.assertIn("dispatched generator.yml", self.comments()[0])

    def test_only_ready_bundles_reach_a_shard(self):
        self.titles = {
            "1": "[nvchecker] cat/drafts can be bump to 1.0_rc2",
            "3": "[nvchecker] cat/ready can be bump to 3.0",
            "4": "[nvchecker] cat/plain can be bump to 4.0",
        }
        self.route("GET", DRAFTS_TAG, MISSING)
        self.route("GET", DRAFTS_RUNS, runs(run("queued", "deepseek-harness 1.0-rc.2")))
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        parsed, _ = self.plan_and_collect()
        items = {item["package"]: item for shard in parsed["shards"] for item in shard["items"]}
        self.assertEqual(set(items), {"cat/ready", "cat/plain"})
        self.assertEqual(items["cat/ready"]["bundle_observations"], 0)
        self.assertEqual(items["cat/ready"]["bundle_observation_limit"], bundles.OBSERVATION_LIMIT)
        self.assertNotIn("bundle_observations", items["cat/plain"])
        self.assertTrue(parsed["results"]["1"].startswith("not attempted (bundle pending)"))

    def test_bundles_only_prepares_and_schedules_nothing(self):
        self.titles = {"3": "[nvchecker] cat/ready can be bump to 3.0", "4": "[nvchecker] cat/plain can be bump to 4.0"}
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        plan = self.sweep("--plan", "8", "--bundles", str(self.tmp / "b.json"), "--bundles-delta",
                          str(self.tmp / "d.json"), "--bundles-only")
        parsed = plan_json(plan)
        self.assertEqual(parsed["shards"], [])
        self.assertEqual(parsed["results"]["3"], "skip (bundles_only run)")
        self.assertTrue((self.tmp / "b.json").exists())

    def test_a_failed_controller_holds_back_only_the_bundle_targets(self):
        self.titles = {"3": "[nvchecker] cat/ready can be bump to 3.0", "4": "[nvchecker] cat/plain can be bump to 4.0"}
        controllers = {
            "crash": 'raise RuntimeError("boom")\n',
            "invalid snapshot": textwrap.dedent("""\
                import sys
                out = sys.argv[sys.argv.index("--out") + 1]
                open(out, "w").write('{"schema": 2, "targets": []}')
                """),
        }
        stale = {"schema": 1, "controller_run": "0", "observed_at": "2026-09-29T00:00:00Z", "targets": [
            {"package": "cat/ready", "version": "3.0", "state": "ready", "bundles": [], "observations": 0,
             "dispatched": [], "escalated_now": False}]}
        for name, script in controllers.items():
            with self.subTest(name):
                self.bundles.write_text(script)
                # an earlier run's snapshot must not stand in for this run's
                (self.tmp / "bundles.json").write_text(json.dumps(stale))
                parsed, _ = self.plan_and_collect()
                items = [item["package"] for shard in parsed["shards"] for item in shard["items"]]
                self.assertEqual(items, ["cat/plain"])
                self.assertIn("bundle controller", parsed["bundle_error"])
                self.assertIn("bundle controller", parsed["results"]["3"])

    def test_a_bundle_the_controller_cannot_read_ends_the_run_red(self):
        # a 401, a deleted repository or a 5xx that persists would otherwise stay unknown unseen
        self.titles = {"2": "[nvchecker] cat/deps can be bump to 2.0", "3": "[nvchecker] cat/ready can be bump to 3.0",
                       "4": "[nvchecker] cat/plain can be bump to 4.0"}
        self.route("GET", DEPS_TAG, (502, {}, {"message": "Server Error"}))
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        parsed, _ = self.plan_and_collect()
        items = [item["package"] for shard in parsed["shards"] for item in shard["items"]]
        self.assertEqual(sorted(items), ["cat/plain", "cat/ready"])
        self.assertIn("exited 1", parsed["bundle_error"])
        self.assertTrue(parsed["results"]["2"].endswith("bundle unknown"))

    def test_collect_merges_the_plan_delta_before_the_shards(self):
        # a retry resets the count in the plan; the shard's observation of the same run comes after it
        self.titles = {"3": "[nvchecker] cat/ready can be bump to 3.0"}
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        self.ledger.write_text("cat/ready 3.0 observe 2026-09-29 0\n")
        plan_delta = self.tmp / "autobump-delta-plan.json"
        plan = self.sweep("3", "--retry", "--plan", "8", "--bundles", str(self.tmp / "bundles.json"),
                          "--bundles-delta", str(plan_delta))
        parsed, run_id = plan_json(plan), str(self.run_id)
        shard_delta = self.tmp / "autobump-delta-0.json"
        shard_delta.write_text(json.dumps({"done": [], "attempts": [], "results": {}, "status_comment_failed": [],
                                           "bundles": [f"cat/ready 3.0 observe 2026-09-30 {run_id}"]}))
        # the order the collect step's glob hands them over
        collect = self.sweep("--collect", json.dumps(parsed), str(shard_delta), str(plan_delta))
        self.assertEqual(collect.returncode, 0, collect.stderr)
        self.assertEqual(bundles.history_of(self.ledger.read_text().splitlines(), "cat/ready", "3.0"),
                         [("observe", run_id)])

    def test_a_worker_passes_the_snapshot_and_counts_a_bundle_defer(self):
        snapshot = self.tmp / "bundles.json"
        snapshot.write_text("{}")
        item = {"issue": "3", "package": "cat/ready", "version": "3.0", "args": [], "footer": "",
                "attempt": 1, "attempts": 0, "bundle_observations": 3, "bundle_observation_limit": 4}
        delta = self.tmp / "worker.json"
        result = self.sweep("--worker", json.dumps({"items": [item]}), "--delta", str(delta), "--comment",
                            AUTOBUMP_BUNDLE_STATUS=str(snapshot))
        self.assertEqual(result.returncode, 0, result.stderr)
        engine, = [json.loads(line) for line in (self.tmp / "engine.log").read_text().splitlines()]
        self.assertEqual(engine[-2:], ["--bundle-status", str(snapshot.resolve())])
        written = json.loads(delta.read_text())
        self.assertEqual(written["attempts"], [])
        self.assertEqual([line.split()[2] for line in written["bundles"]], ["observe", "escalate"])
        self.assertIn("escalated: bundle not ready after 4 observations", written["results"]["3"])
        self.assertIn("actions/runs/7", self.comments()[-1])

        # the limit is the controller's, handed over with the count
        item |= {"bundle_observation_limit": 5}
        self.sweep("--worker", json.dumps({"items": [item]}), "--delta", str(delta), AUTOBUMP_BUNDLE_STATUS=str(snapshot))
        written = json.loads(delta.read_text())
        self.assertEqual([line.split()[2] for line in written["bundles"]], ["observe"])
        self.assertIn("observation 4/5", written["results"]["3"])

    def test_a_worker_without_the_snapshot_refuses_to_run_the_engine(self):
        item = {"issue": "3", "package": "cat/ready", "version": "3.0", "args": [], "footer": "",
                "attempt": 1, "attempts": 0, "bundle_observations": 0, "bundle_observation_limit": 4}
        delta = self.tmp / "worker.json"
        result = self.sweep("--worker", json.dumps({"items": [item]}), "--delta", str(delta))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.tmp / "engine.log").exists())
        self.assertIn("bundle snapshot missing", json.loads(delta.read_text())["results"]["3"])


class TrialTest(Harness):
    """The trial's bundle step, cut from autobump-trial.yml and run as the job runs it."""

    def trial(self, package, version):
        text = (ROOT / ".github" / "workflows" / "autobump-trial.yml").read_text()
        start = text.index("bundle=''")
        block = text[start:text.rindex("\n", 0, text.index("ruby autobump-rb/bin/autobump"))]
        block = block.replace("/tmp/autobump-bundles", str(self.tmp / "snapshots"))
        block = block.replace("autobump-rb/bin/bundles.py", str(self.bundles))
        out = self.tmp / "args"
        script = (f"set +e -uo pipefail\nfor n in 7; do\npkg={package}; ver={version}; args=()\n{block}\n"
                  f"printf '%s\\n' \"${{args[@]}}\" > {out}\ndone\n")
        summary = self.tmp / "summary"
        summary.write_text("")
        subprocess.run(["bash", "-c", script], cwd=self.repo, capture_output=True, text=True,
                       env=self.environment(GITHUB_STEP_SUMMARY=str(summary)))
        return (out.read_text().split() if out.exists() else []), summary.read_text()

    def break_entry(self, old, new):
        toml = self.repo / ".github" / "workflows" / "overlay.toml"
        text = toml.read_text()
        self.assertIn(old, text)
        toml.write_text(text.replace(old, new))

    def test_a_broken_entry_elsewhere_keeps_the_snapshot(self):
        self.break_entry('deps = "golang"', 'deps = "cobol"')
        self.route("GET", READY_TAG, RELEASED)
        self.route("GET", DEPS_RUNS, runs())
        args, _ = self.trial("cat/ready", "3.0")
        self.assertEqual(args, ["--bundle-status", str(self.tmp / "snapshots" / "7.json")])

    def test_a_package_without_bundle_runs_without_a_snapshot(self):
        args, summary = self.trial("cat/plain", "4.0")
        self.assertEqual((args, summary), ([], ""))

    def test_an_unreadable_index_is_reported_not_skipped_silently(self):
        for name, (old, new) in {"own entry": ('tag = "{P}" }', 'tag = "{X}" }'),
                                 "toml": ('["cat/plain"]', '["cat/plain"')}.items():
            with self.subTest(name):
                self.setUp()
                self.break_entry(old, new)
                args, summary = self.trial("cat/ready", "3.0")
                self.assertEqual(args, [])
                self.assertIn("SKIP", summary)


if __name__ == "__main__":
    unittest.main()
