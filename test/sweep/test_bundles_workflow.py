"""The wiring between the overlay workflows and bin/bundles.py.

The snapshot and the plan's ledger delta cross runners through artifacts; a renamed artifact,
path or flag leaves every script test green while production shards judge bundle 404s blind
or collect drops the counts. Both sides are parsed and compared here.
"""
from fnmatch import fnmatch
import os
from pathlib import Path
import re
import shlex
import unittest

import yaml


def overlay_root():
    root = os.environ.get("AUTOBUMP_OVERLAY")
    if not root:
        raise SystemExit("set AUTOBUMP_OVERLAY to an overlay checkout")
    return Path(root)


ROOT = overlay_root()
WORKFLOWS = ROOT / ".github" / "workflows"
BUNDLES = (Path(__file__).resolve().parents[2] / "bin" / "bundles.py").read_text()
CONTROLLER = "autobump-rb/bin/bundles.py"
SWEEP = (ROOT / "scripts" / "autobump-sweep.py").read_text()


def workflow(name):
    return yaml.safe_load((WORKFLOWS / name).read_text())


def steps(job):
    return job.get("steps", []) or []


def tokens_of(text):
    text = text.replace("\\\n", " ")
    return shlex.split(text.replace("${{", "${").replace("}}", "}"), comments=True)


def flag_value(tokens, flag):
    return tokens[tokens.index(flag) + 1] if flag in tokens else None


def uses(step, action):
    return (step.get("uses") or "").startswith(action)


def fetches_autobump_rb(job):
    return any(uses(s, "actions/checkout") and (s.get("with") or {}).get("repository") == "gentoo-zh/autobump-rb"
               and s["with"].get("path") == "autobump-rb" for s in steps(job))


def owner_env(owner):
    # the variable bundles.py reads a per-owner token from
    return "GH_TOKEN_" + owner.upper().replace("-", "_")


def minted_owners(job):
    return {s["with"]["owner"]: s for s in steps(job) if uses(s, "actions/create-github-app-token")
            and "DRAFTS_BOT" in str(s["with"].get("client-id"))}


class AutobumpBundleWiringTest(unittest.TestCase):
    def setUp(self):
        self.jobs = workflow("autobump.yml")["jobs"]
        self.plan_step = next(s for s in steps(self.jobs["plan"]) if "autobump-sweep.py" in (s.get("run") or ""))
        self.plan_tokens = tokens_of(self.plan_step["run"])

    def test_the_plan_runs_the_controller(self):
        self.assertIn("--bundles", self.plan_tokens)
        self.assertIn("--bundles-delta", self.plan_tokens)
        self.assertEqual(self.plan_step["env"]["AUTOBUMP_BUNDLE_CONTROLLER"], CONTROLLER)
        self.assertTrue(fetches_autobump_rb(self.jobs["plan"]))
        self.assertIn('os.environ.get("AUTOBUMP_BUNDLE_CONTROLLER")', SWEEP)

    def test_the_shards_get_the_snapshot_the_plan_wrote(self):
        snapshot = flag_value(self.plan_tokens, "--bundles")
        uploaded = {s["with"]["name"]: s["with"]["path"] for s in steps(self.jobs["plan"])
                    if uses(s, "actions/upload-artifact")}
        name = next(n for n, path in uploaded.items() if path == snapshot)
        download = next(s for s in steps(self.jobs["bump"])
                        if uses(s, "actions/download-artifact") and s["with"].get("name") == name)
        shard = next(s for s in steps(self.jobs["bump"]) if "autobump-sweep.py" in (s.get("run") or ""))
        self.assertEqual(shard["env"]["AUTOBUMP_BUNDLE_STATUS"],
                         f"{download['with']['path']}/{Path(snapshot).name}")
        self.assertIn('"AUTOBUMP_BUNDLE_STATUS"', SWEEP)
        self.assertIn('"--bundle-status"', SWEEP)

    def test_collect_merges_the_plan_delta_even_when_no_shard_ran(self):
        delta = flag_value(self.plan_tokens, "--bundles-delta")
        upload = next(s for s in steps(self.jobs["plan"])
                      if uses(s, "actions/upload-artifact") and s["with"]["path"] == delta)
        # the waiter reads the delta of a plan that failed after the controller ran
        self.assertEqual(upload.get("if", "always()"), "always()")
        download = next(s for s in steps(self.jobs["collect"]) if uses(s, "actions/download-artifact"))
        self.assertTrue(fnmatch(upload["with"]["name"], download["with"]["pattern"]))
        # a condition on the bump job here would drop the plan's lines whenever it is skipped
        self.assertNotIn("if", download)
        collect = next(s for s in steps(self.jobs["collect"]) if "--collect" in (s.get("run") or ""))
        self.assertIn(f"{download['with']['path']}/", collect["run"])
        self.assertIn("always()", str(self.jobs["collect"]["if"]))
        self.assertIn('delta.get("bundles"', SWEEP)

    def test_a_rerun_of_the_plan_replaces_its_artifacts(self):
        # a name is taken once per run: "Re-run all jobs" would fail the upload after the
        # controller dispatched, and collect would never merge those dispatches
        for step in steps(self.jobs["plan"]):
            if uses(step, "actions/upload-artifact"):
                self.assertIs(step["with"].get("overwrite"), True, step["with"]["name"])

    def test_a_rerun_saves_its_counts_under_a_key_of_its_own(self):
        # a cache key is written once: under the first attempt's key a rerun's dispatches are lost
        save = next(s for s in steps(self.jobs["collect"]) if uses(s, "actions/cache/save"))
        self.assertIn("${{ github.run_attempt }}", save["with"]["key"])
        for job in ("plan", "collect"):
            restore = next(s for s in steps(self.jobs[job]) if uses(s, "actions/cache/restore"))
            self.assertTrue(save["with"]["key"].startswith(restore["with"]["restore-keys"]), job)

    def test_a_controller_failure_skips_no_bump_and_ends_the_run_red(self):
        # the plan writes no snapshot then; the shards of other packages must still run
        download = next(s for s in steps(self.jobs["bump"])
                        if uses(s, "actions/download-artifact") and s["with"].get("name") == "autobump-bundles")
        self.assertIs(download.get("continue-on-error"), True)
        collect = steps(self.jobs["collect"])
        last = collect[-1]
        self.assertIn("bundle_error", str(last.get("if")))
        self.assertIn("always()", str(last.get("if")))
        self.assertRegex(last["run"], r"exit 1\b")
        # after the state is saved, so the counts of this run are kept
        saved = next(i for i, s in enumerate(collect) if uses(s, "actions/cache/save"))
        self.assertLess(saved, len(collect) - 1)
        self.assertIn('"bundle_error"', SWEEP)

    def test_only_the_plan_holds_the_dispatch_tokens(self):
        owners = minted_owners(self.jobs["plan"])
        self.assertEqual(set(owners), {"gentoo-zh", "gentoo-zh-drafts"})
        self.assertEqual(owners["gentoo-zh"]["with"].get("repositories"), "gentoo-deps")
        for owner, step in owners.items():
            self.assertEqual(self.plan_step["env"][owner_env(owner)], f"${{{{ steps.{step['id']}.outputs.token }}}}")
            self.assertIn(owner, BUNDLES)
        for name, job in self.jobs.items():
            if name != "plan":
                self.assertNotIn("DRAFTS_BOT", str(job), f"{name} can reach a dispatch token")

    def test_bundles_only_reaches_the_sweep(self):
        inputs = workflow("autobump.yml")[True]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["bundles_only"]["type"], "boolean")
        self.assertIn("--bundles-only", self.plan_step["env"]["BUNDLES_ONLY"])
        self.assertIn("$BUNDLES_ONLY", self.plan_step["run"])
        self.assertIn('"--bundles-only"', SWEEP)


class BundlesWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.document = workflow("bundles.yml")
        self.job = self.document["jobs"]["bundles"]

    def test_the_inputs_a_maintainer_types(self):
        inputs = self.document[True]["workflow_dispatch"]["inputs"]
        self.assertTrue(inputs["packages"]["required"])
        self.assertIn("version", inputs)
        self.assertEqual(inputs["mode"]["options"], ["status", "prepare"])
        self.assertEqual(inputs["mode"]["default"], "status")

    def test_it_runs_the_controller_with_the_chosen_mode(self):
        step = next(s for s in steps(self.job) if "bundles.py" in (s.get("run") or ""))
        self.assertIn(f'{CONTROLLER} "$MODE" $PACKAGES', step["run"])
        self.assertTrue(fetches_autobump_rb(self.job))
        self.assertEqual(step["env"]["MODE"], "${{ inputs.mode }}")
        for command in ("status", "prepare"):
            self.assertIn(f'"{command}"', BUNDLES)
        owners = minted_owners(self.job)
        self.assertEqual(set(owners), {"gentoo-zh", "gentoo-zh-drafts"})
        for owner, token_step in owners.items():
            self.assertEqual(step["env"][owner_env(owner)], f"${{{{ steps.{token_step['id']}.outputs.token }}}}")

    def test_one_failed_token_mint_leaves_the_other_owner_working(self):
        owners = minted_owners(self.job)
        for owner, step in owners.items():
            self.assertIs(step.get("continue-on-error"), True, owner)
        step = next(s for s in steps(self.job) if "bundles.py" in (s.get("run") or ""))
        self.assertNotIn("if", step)

    def test_the_summary_names_what_a_maintainer_needs(self):
        header = re.search(r'"\| package \| version \| repo \| workflow \| state \| run \| release \|"', BUNDLES)
        self.assertIsNotNone(header)
        self.assertIn("GITHUB_STEP_SUMMARY", BUNDLES)


class TrialAndCutOverTest(unittest.TestCase):
    def test_the_trial_passes_a_read_only_snapshot(self):
        job = workflow("autobump-trial.yml")["jobs"]["trial"]
        self.assertTrue(any((s.get("run") or "").strip() == "scripts/autobump-trial.sh" for s in steps(job)))
        run = (ROOT / "scripts" / "autobump-trial.sh").read_text()
        self.assertIn("ruby autobump-rb/bin/autobump", run)
        self.assertIn(f"{CONTROLLER} status", run)
        self.assertTrue(fetches_autobump_rb(job))
        self.assertNotIn("bundles.py prepare", run)
        self.assertIn("--bundle-status", run)

    def test_the_old_dispatcher_is_gone(self):
        self.assertNotIn("deps-dispatch", workflow("nvchecker.yml")["jobs"])
        self.assertFalse((WORKFLOWS / "gentoo-deps-dispatcher.toml").exists())


if __name__ == "__main__":
    unittest.main()
