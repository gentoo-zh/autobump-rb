#!/usr/bin/env python3
"""A bundle escalation a maintainer already has must not turn the collect job red.

Drives scripts/autobump-sweep.py --plan and --collect against a scripted bundle controller and gh.
The two real cases: run 43174398230 (cc-switch, crate-dist.yml refused the dispatch with HTTP 422)
and run 42573883788 (honk, overlay.toml `deps` needs a tag).
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


def overlay_root():
    root = os.environ.get("AUTOBUMP_OVERLAY")
    if not root:
        raise SystemExit("set AUTOBUMP_OVERLAY to an overlay checkout")
    return Path(root)


ROOT = overlay_root()
SWEEP = ROOT / "scripts" / "autobump-sweep.py"

GH = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["GH_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")
titles = {
    "101": "[nvchecker] cat/ccswitch can be bump to 4.0.30",
    "102": "[nvchecker] cat/honk can be bump to 0.1.0_beta6",
    "103": "[nvchecker] cat/flaky can be bump to 2.0",
}
if args[:2] == ["issue", "view"]:
    print(titles[args[2]])
elif args[0] == "api" and os.environ.get("GH_API_FAIL"):
    raise SystemExit(1)
elif args[0] == "api" or args[:2] == ["issue", "comment"]:
    pass
else:
    raise SystemExit(f"unexpected gh command: {args!r}")
"""

# Writes the snapshot and delta the scenario names, prints its `failed:` lines, exits as told.
CONTROLLER = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

scenario = json.loads(Path(os.environ["SCENARIO"]).read_text())
argv = sys.argv[1:]
Path(argv[argv.index("--out") + 1]).write_text(json.dumps({"schema": 1, "targets": scenario["targets"]}))
Path(argv[argv.index("--delta") + 1]).write_text(json.dumps(
    {"done": [], "attempts": [], "bundles": [], "results": {}, "status_comment_failed": []}))
for line in scenario["failed"]:
    print(f"failed: {line}", file=sys.stderr)
raise SystemExit(scenario["status"])
"""

CC_REASON = ("gentoo-zh-drafts/cc-switch@v4.0.30: crate-dist.yml refused the dispatch "
             "(HTTP 422: Actions has been disabled for this repository.)")
HONK_REASON = "overlay.toml: deps needs tag: from_pattern or to_pattern makes the version differ from the tag"


def target(issue, package, version, state, reason, *, escalated_now=False, view_state=None):
    view = {"id": "distfiles", "repo": "gentoo-zh-drafts/x", "workflow": "-", "release_tag": "-",
            "state": view_state or state, "reason": reason, "producers": [], "release_url": None, "run_url": None}
    return {"package": package, "version": version, "state": state, "reason": reason, "bundles": [view],
            "observations": 0, "observation_limit": 3, "dispatched": [], "escalated_now": escalated_now,
            "issue": issue}


class BundleEscalationTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        base = Path(self.tempdir.name)
        self.repo = base / "overlay"
        self.bin = self.repo / "bin"
        self.bin.mkdir(parents=True)
        (self.repo / "scripts").mkdir()
        (self.repo / ".github" / "workflows").mkdir(parents=True)
        (self.repo / ".github" / "workflows" / "overlay.toml").write_text(textwrap.dedent("""\
            ["cat/ccswitch"]
            autobump = true
            deps = { repo = "gentoo-zh-drafts/ccswitch" }

            ["cat/honk"]
            autobump = true
            deps = { repo = "gentoo-zh-drafts/honk" }

            ["cat/flaky"]
            autobump = true
            deps = { repo = "gentoo-zh-drafts/flaky" }
            """))
        (self.repo / "scripts" / "autobump-args.py").write_bytes((ROOT / "scripts" / "autobump-args.py").read_bytes())
        for name, body in (("gh", GH), ("controller", CONTROLLER)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.state_home = base / "state"
        (self.state_home / "autobump").mkdir(parents=True)
        self.scenario = base / "scenario.json"
        self.gh_log = base / "gh.log"
        self.summary = base / "step-summary.md"

    def plan(self, targets, failed, status=1, **environment):
        self.scenario.write_text(json.dumps({"targets": targets, "failed": failed, "status": status}))
        env = os.environ | {
            "AUTOBUMP_REPO": str(self.repo), "AUTOBUMP_UPSTREAM_REPO": "test/overlay",
            "AUTOBUMP_BUNDLE_CONTROLLER": str(self.bin / "controller"), "SCENARIO": str(self.scenario),
            "XDG_STATE_HOME": str(self.state_home), "GH_TOKEN": "test", "GH_LOG": str(self.gh_log),
            "AUTOBUMP_STATUS_BACKOFF": "0", "GITHUB_STEP_SUMMARY": str(self.summary),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
        } | environment
        env.pop("GITHUB_RUN_ID", None)
        result = subprocess.run(
            [sys.executable, str(SWEEP), "--comment", "--plan", "1", "--bundles", str(self.repo / "bundles.json"),
             "--bundles-delta", str(self.repo / "delta.json"), "101", "102", "103"],
            cwd=self.repo, env=env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout), env

    def collect(self, plan, env):
        return subprocess.run(
            [sys.executable, str(SWEEP), "--collect", json.dumps(plan), str(self.repo / "delta.json")],
            cwd=self.repo, env=env, capture_output=True, text=True, check=False)

    def comments(self):
        return [call for call in map(json.loads, self.gh_log.read_text().splitlines()) if call[:2] == ["issue", "comment"]]

    def test_a_dispatch_refused_this_run_and_commented_is_not_a_bundle_error(self):
        cc = target("101", "cat/ccswitch", "4.0.30", "escalate", CC_REASON, escalated_now=True)
        plan, env = self.plan([cc], [f"cat/ccswitch 4.0.30: {CC_REASON}"])

        self.assertIsNone(plan["bundle_error"])
        self.assertEqual([call[2] for call in self.comments()], ["101"])
        self.assertEqual(len(plan["standing_escalations"]), 1)
        self.assertIn("#101  cat/ccswitch 4.0.30", plan["standing_escalations"][0])

        collected = self.collect(plan, env)
        self.assertEqual(collected.returncode, 0, collected.stderr)
        self.assertIn("bundle escalations awaiting a maintainer", collected.stdout)
        self.assertIn("cat/ccswitch 4.0.30", self.summary.read_text())

    def test_an_escalation_latched_by_an_earlier_run_is_not_a_bundle_error(self):
        honk = target("102", "cat/honk", "0.1.0_beta6", "escalate", HONK_REASON)
        plan, _ = self.plan([honk], [f"cat/honk 0.1.0_beta6: {HONK_REASON}"])

        self.assertIsNone(plan["bundle_error"])
        self.assertEqual([call[2] for call in self.comments()], ["102"])
        self.assertIn("#102  cat/honk", plan["standing_escalations"][0])

    def test_an_unknown_state_beside_a_standing_escalation_still_fails(self):
        honk = target("102", "cat/honk", "0.1.0_beta6", "escalate", HONK_REASON)
        flaky = target("103", "cat/flaky", "2.0", "unknown", "x@v2.0: dispatch not confirmed (HTTP 502)")
        plan, _ = self.plan([honk, flaky], [f"cat/honk 0.1.0_beta6: {HONK_REASON}",
                                            "cat/flaky 2.0: x@v2.0: dispatch not confirmed (HTTP 502)"])

        self.assertIn("exited 1", plan["bundle_error"])
        self.assertEqual(plan.get("standing_escalations", []), [])

    def test_an_owner_the_controller_stopped_asking_still_fails(self):
        honk = target("102", "cat/honk", "0.1.0_beta6", "escalate", HONK_REASON)
        plan, _ = self.plan([honk], [f"cat/honk 0.1.0_beta6: {HONK_REASON}",
                                     "gentoo-zh-drafts: stopped asking after HTTP 401"])

        self.assertIn("exited 1", plan["bundle_error"])

    def test_an_escalation_whose_comment_was_not_posted_still_fails(self):
        cc = target("101", "cat/ccswitch", "4.0.30", "escalate", CC_REASON, escalated_now=True)
        plan, _ = self.plan([cc], [f"cat/ccswitch 4.0.30: {CC_REASON}"], GH_API_FAIL="1")

        self.assertIn("exited 1", plan["bundle_error"])
        self.assertEqual(plan["status_comment_failed"], ["101"])

    def test_a_comment_lost_on_the_first_run_is_posted_on_the_next_not_skipped(self):
        cc = target("101", "cat/ccswitch", "4.0.30", "escalate", CC_REASON, escalated_now=True)
        failed = [f"cat/ccswitch 4.0.30: {CC_REASON}"]
        first, env = self.plan([cc], failed, GH_API_FAIL="1")
        self.assertIn("exited 1", first["bundle_error"])
        self.assertEqual(first["status_comment_failed"], ["101"])
        self.assertEqual(self.collect(first, env).returncode, 0)
        self.assertEqual(self.comments(), [])

        # the latch from run 1 holds, so the controller no longer reports it as new
        cc = target("101", "cat/ccswitch", "4.0.30", "escalate", CC_REASON)
        second, _ = self.plan([cc], failed)

        self.assertEqual([call[2] for call in self.comments()], ["101"])
        self.assertIsNone(second["bundle_error"])
        self.assertEqual(second["status_comment_failed"], [])
        self.assertEqual(len(second["standing_escalations"]), 1)

    def test_a_comment_still_not_posted_on_the_next_run_keeps_failing(self):
        cc = target("101", "cat/ccswitch", "4.0.30", "escalate", CC_REASON)
        plan, _ = self.plan([cc], [f"cat/ccswitch 4.0.30: {CC_REASON}"], GH_API_FAIL="1")

        self.assertIn("exited 1", plan["bundle_error"])
        self.assertEqual(plan["status_comment_failed"], ["101"])
        self.assertEqual(plan["standing_escalations"], [])
        self.assertEqual(self.comments(), [])

    def test_a_controller_that_failed_without_saying_why_still_fails(self):
        honk = target("102", "cat/honk", "0.1.0_beta6", "escalate", HONK_REASON)
        plan, _ = self.plan([honk], [])

        self.assertIn("exited 1", plan["bundle_error"])

    def test_a_clean_controller_run_is_unchanged(self):
        plan, _ = self.plan([], [], status=0)

        self.assertIsNone(plan["bundle_error"])
        self.assertEqual(plan.get("standing_escalations", []), [])


if __name__ == "__main__":
    unittest.main()
