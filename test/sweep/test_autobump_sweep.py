#!/usr/bin/env python3
"""End-to-end checks for scripts/autobump-sweep.py without GitHub or git."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


def overlay_root():
    """The overlay checkout these tests drive; the driver they test lives there, not here."""
    root = os.environ.get("AUTOBUMP_OVERLAY")
    if not root:
        raise SystemExit("set AUTOBUMP_OVERLAY to an overlay checkout")
    return Path(root)


ROOT = overlay_root()
SWEEP = ROOT / "scripts" / "autobump-sweep.py"


GIT = """#!/usr/bin/env python3
import sys
if sys.argv[1:] == ["branch", "--show-current"]:
    print("test-branch")
"""


GH = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["GH_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")

if args[:2] == ["issue", "list"]:
    print("1\\n2\\n3\\n4\\n5\\n6\\n7")
elif args[:2] == ["issue", "view"]:
    titles = {
        "1": "[nvchecker] cat/skip can be bump to 1.0",
        "2": "[nvchecker] cat/done can be bump to 1.0",
        "3": "[nvchecker] cat/bump can be bump to 2.0",
        "4": "[nvchecker] cat/escalate can be bump to 3.0",
        "5": "[nvchecker] cat/transient can be bump to 4.0",
        "6": "[nvchecker] cat/comment-fail can be bump to 5.0",
        "7": "[nvchecker] cat/regex can be bump to 6.0",
        "8": "[nvchecker] cat/noisy can be bump to 7.0",
        "11": "[nvchecker] cat/bump can be bump to 2.0",
        "13": "[nvchecker] cat/bump can be bump to 2.1",
        "14": "[nvchecker] cat/bangs can be bump to 10.0",
        "16": "[nvchecker] cat/quoted can be bump to 12.0",
        "15": "[nvchecker] cat/silent can be bump to 11.0",
        "12": "[nvchecker] cat/ahead can be bump to 9.0",
        "9": "[nvchecker] cat/binary can be bump to 8.0",
    }
    if args[2] == "10":
        raise SystemExit(1)
    print(titles[args[2]])
elif args[0] == "api":
    if os.environ.get("GH_API_FAIL"):
        raise SystemExit(1)
elif args[:2] == ["issue", "comment"]:
    issue = args[2]
    state = Path(os.environ["GH_STATE"])
    counts = json.loads(state.read_text()) if state.exists() else {}
    count = counts.get(issue, 0)
    counts[issue] = count + 1
    state.write_text(json.dumps(counts))
    if issue == "6" and count >= 1:
        raise SystemExit(1)
else:
    raise SystemExit(f"unexpected gh command: {args!r}")
"""


ENGINE = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["ENGINE_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")

issue = args[0]
if issue == "3":
    print("stage one")
    print("https://github.com/test/overlay/pull/123")
elif issue == "4":
    if "--accept-surface" in args and "--accept-payload" in args:
        print("retried with the judge's acceptance")
        raise SystemExit(0)
    print(">> current: 2.0 -> target: 3.0")
    print(f"== evidence: {os.environ['EVIDENCE_DIR']} ==")
    raise SystemExit(3)
elif issue == "5":
    print(f"== evidence: {os.environ['EVIDENCE_DIR']} ==")
    print("! build host timed out")
    raise SystemExit(2)
elif issue == "14":
    print("!!! Couldn't download 'x.tar.gz'. Aborting.")
    print("!! vendor bundle unavailable")
    print("!!! ebuild already exists somewhere")
    raise SystemExit(2)
elif issue == "15":
    raise SystemExit(2)
elif issue == "16":
    print("bumped")
elif issue == "12":
    print("!! already at 9.0 on synced master")
    raise SystemExit(2)
elif issue == "8":
    # the abort reason reaches the driver first, then the buffered build log
    print("!! vendor bundle unavailable")
    print("fatal: destination path 'vendor' already exists and is not an empty directory")
    raise SystemExit(2)
elif issue == "9":
    sys.stdout.buffer.write(b"bumped \\xff\\n")
    sys.stdout.flush()
elif issue in {"6", "7"}:
    print("bumped")
else:
    raise SystemExit(f"unexpected engine issue: {issue}")
"""


class AutobumpSweepTest(unittest.TestCase):
    def write_executable(self, path, contents):
        path.write_text(contents)
        path.chmod(0o755)

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.repo = Path(self.tempdir.name) / "overlay"
        self.bin = self.repo / "bin"
        self.state_home = Path(self.tempdir.name) / "state"
        self.evidence = Path(self.tempdir.name) / "evidence"
        self.repo.joinpath(".github", "workflows").mkdir(parents=True)
        self.repo.joinpath("scripts").mkdir()
        self.bin.mkdir()
        self.evidence.mkdir()
        (self.evidence / "escalations.txt").write_text("payload layout changed\n")
        (self.evidence / "tree-added.txt").write_text("usr/lib/libnew.so\n")
        # portage names an elog "<cat>:<pn>-<ver>:<timestamp>.log", which an artifact refuses
        elog = self.evidence / "plog" / "elog"
        elog.mkdir(parents=True)
        (elog / "app-eselect:eselect-notify-send-0.1:20260904-132524.log").write_text("notice\n")
        (self.evidence / "build.log").write_text(
            "  1000K .......... .......... 71% 80.5M 0s\n"
            + "".join(f"build line {index}\n" for index in range(300))
        )
        self.kept = Path(self.tempdir.name) / "kept"
        self.repo.joinpath(".github", "workflows", "overlay.toml").write_text(
            textwrap.dedent(
                """\
                ["cat/skip"]
                source = "github"

                ["cat/done"]
                autobump = true

                ["cat/bump"]
                autobump = true

                ["cat/escalate"]
                autobump = true

                ["cat/transient"]
                autobump = true

                ["cat/comment-fail"]
                autobump = true

                ['cat/quoted']
                autobump = true

                ["cat/bangs"]
                autobump = true

                ["cat/silent"]
                autobump = true

                ["cat/ahead"]
                autobump = true

                ["cat/noisy"]
                autobump = true

                ["cat/binary"]
                autobump = true

                ["cat/regex"]
                autobump = true
                url = "https://example.invalid/releases/${PV}"
                autobump_my_pv_regex = '"release":"([0-9]+)"'
                """
            )
        )
        shutil.copy2(ROOT / "scripts" / "autobump-args.py", self.repo / "scripts")
        shutil.copy2(ROOT / "scripts" / "autobump-judge.sh", self.repo / "scripts")
        self.write_executable(self.bin / "git", GIT)
        self.write_executable(self.bin / "gh", GH)
        self.write_executable(self.bin / "engine", ENGINE)
        self.done = self.state_home / "autobump" / "done.list"
        self.done.parent.mkdir(parents=True)
        self.done.write_text("cat/done 1.0 bumped 2026-09-01\n")
        self.engine_log = Path(self.tempdir.name) / "engine.log"
        self.gh_log = Path(self.tempdir.name) / "gh.log"
        self.gh_state = Path(self.tempdir.name) / "gh.state"

    def run_sweep(self, *args, judge="", environment_extra=None):
        environment = os.environ | (environment_extra or {}) | {
            "AUTOBUMP_ENGINE": str(self.bin / "engine"),
            "AUTOBUMP_REPO": str(self.repo),
            "AUTOBUMP_UPSTREAM_REPO": "test/overlay",
            "XDG_STATE_HOME": str(self.state_home),
            "GH_TOKEN": "test-token",
            "EVIDENCE_DIR": str(self.evidence),
            "AUTOBUMP_EVIDENCE_DIR": str(self.kept),
            "ENGINE_LOG": str(self.engine_log),
            "GH_LOG": str(self.gh_log),
            "GH_STATE": str(self.gh_state),
            "AUTOBUMP_STATUS_BACKOFF": "0",
            "PATH": f"{self.bin}:{os.environ['PATH']}",
        }
        environment.pop("AUTOBUMP_JUDGE", None)
        if judge:
            environment["AUTOBUMP_JUDGE"] = judge
        return subprocess.run(
            [sys.executable, str(SWEEP), *args],
            cwd=self.repo,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def engine_calls(self):
        if not self.engine_log.exists():
            return []
        return [json.loads(line) for line in self.engine_log.read_text().splitlines()]

    def gh_calls(self):
        if not self.gh_log.exists():
            return []
        return [json.loads(line) for line in self.gh_log.read_text().splitlines()]
    def run_worker(self, items, delta, *args):
        return self.run_sweep(
            "--worker",
            json.dumps({"items": items}),
            "--delta",
            str(delta),
            *args,
        )

    def run_collect(self, plan, *deltas):
        return self.run_sweep("--collect", json.dumps(plan), *(str(delta) for delta in deltas))


    def attempt_lines(self):
        attempts = self.state_home / "autobump" / "attempts"
        return attempts.read_text().splitlines() if attempts.exists() else []

    def test_one_broken_issue_does_not_stop_the_sweep(self):
        # the shell this replaced ran without `set -e`; losing that would cost every
        # remaining package its turn and the run its only record.
        self.done.chmod(0o444)
        try:
            run = self.run_sweep("3", "4")
        finally:
            self.done.chmod(0o644)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("==== sweep summary ====", run.stdout)
        self.assertIn("#3  error (", run.stdout)
        self.assertIn("#4  ", run.stdout)

    def test_not_opted_in(self):
        result = self.run_sweep("1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#1  skip (not opted in: no autobump key)", result.stdout)
        self.assertEqual(self.engine_calls(), [])

    def test_already_done(self):
        result = self.run_sweep("2")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#2  skip (cat/done 1.0 bumped 2026-09-01)", result.stdout)
        self.assertEqual(self.engine_calls(), [])

    def test_per_run_limit(self):
        result = self.run_sweep("--limit", "1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#1  skip (not opted in: no autobump key)", result.stdout)
        self.assertIn("#2  skip (cat/done 1.0 bumped 2026-09-01)", result.stdout)
        self.assertIn("#4  skip (per-run attempt limit 1 reached)", result.stdout)
        self.assertEqual([call[0] for call in self.engine_calls()], ["3"])

    def test_exit_0_records_bump_and_posts_comment(self):
        result = self.run_sweep("3", "--comment")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#3  bumped", result.stdout)
        self.assertIn("cat/bump 2.0 bumped", self.done.read_text())
        self.assertTrue(
            any(
                call[:3] == ["issue", "comment", "3"]
                and "**autobump** bumped `cat/bump` → `2.0`" in call[-1]
                for call in self.gh_calls()
            )
        )

    def test_exit_3_escalates_with_evidence_reason(self):
        result = self.run_sweep("4", "--comment")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#4  escalated: payload layout changed", result.stdout)
        self.assertIn("cat/escalate 3.0 deferred", self.done.read_text())
        self.assertTrue(
            any(
                call[:3] == ["issue", "comment", "4"]
                and "payload layout changed" in call[-1]
                for call in self.gh_calls()
            )
        )

    def test_escalation_comment_carries_every_evidence_file(self):
        self.run_sweep("4", "--comment")

        body = [
            call[-1] for call in self.gh_calls() if call[:3] == ["issue", "comment", "4"]
        ][-1]
        self.assertIn("tree-added.txt", body)
        self.assertIn("usr/lib/libnew.so", body)
        # a log is cut from its start, so the failure at its end survives
        self.assertIn("build.log (200 of 300 lines)", body)
        # wget progress lines are not a record of anything
        self.assertNotIn("80.5M", body)
        # the diff comes before the log it would otherwise be buried under
        self.assertLess(body.index("tree-added.txt"), body.index("build.log"))
        self.assertIn("build line 299", body)
        self.assertNotIn("build line 0\n", body)

    def test_kept_evidence_can_be_uploaded_as_an_artifact(self):
        self.run_sweep("4", "--comment")

        kept = self.kept / "cat_escalate-3.0"
        names = [str(p.relative_to(kept)) for p in kept.rglob("*") if p.is_file()]
        self.assertTrue(any(name.endswith("20260904-132524.log") for name in names), names)
        self.assertFalse([name for name in names if set(name) & set(':"<>|*?')], names)

    def test_escalation_evidence_is_kept_for_upload(self):
        self.run_sweep("4", "--comment")

        kept = self.kept / "cat_escalate-3.0"
        self.assertEqual(
            sorted(path.name for path in kept.iterdir()),
            ["build.log", "escalations.txt", "plog", "tree-added.txt"],
        )

    def test_named_issues_are_not_capped_by_the_run_limit(self):
        result = self.run_sweep("3", "6", "7", "--limit", "1", "--plan", "4")

        plan = json.loads(result.stdout)
        planned = [item["issue"] for shard in plan["shards"] for item in shard["items"]]
        self.assertEqual(planned, ["3", "6", "7"])

    def test_two_issues_naming_one_bump_are_planned_once(self):
        result = self.run_sweep("3", "11", "--plan", "4")

        plan = json.loads(result.stdout)
        self.assertEqual([item["issue"] for shard in plan["shards"] for item in shard["items"]], ["3"])
        self.assertEqual(plan["results"]["11"], "skip (#3 already bumps cat/bump this run)")

    def test_a_single_quoted_table_is_an_opt_in_too(self):
        result = self.run_sweep("16")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#16  bumped", result.stdout)

    def test_two_versions_of_one_package_do_not_run_at_once(self):
        result = self.run_sweep("3", "13", "--plan", "4")

        plan = json.loads(result.stdout)
        self.assertEqual([item["issue"] for shard in plan["shards"] for item in shard["items"]], ["3"])
        self.assertIn("already bumps cat/bump", plan["results"]["13"])

    def test_an_engine_log_line_is_not_an_abort_reason(self):
        result = self.run_sweep("14")

        self.assertEqual(result.returncode, 0, result.stderr)
        # portage writes "!!!" into the same stream; only the engine's "!!" is a verdict
        self.assertIn("#14  not attempted (transient, try 1): vendor bundle unavailable", result.stdout)
        self.assertNotIn("cat/bangs", self.done.read_text())

    def test_an_engine_that_printed_nothing_keeps_no_evidence(self):
        for run in range(3):
            delta = Path(self.tempdir.name) / f"delta-{run}.json"
            self.run_worker(
                [{"issue": "15", "package": "cat/silent", "version": "11.0", "args": [],
                  "footer": "", "attempt": 1, "attempts": len(self.attempt_lines())}],
                delta,
            )
            self.run_collect({"matrix": {"include": []}, "issues": ["15"], "results": {}}, delta)

        # an empty output has no evidence path, and Path("") is the checkout
        self.assertEqual(sorted(p.name for p in self.kept.iterdir()) if self.kept.exists() else [], [])

    def test_a_failed_gh_lookup_is_not_an_unparseable_title(self):
        result = self.run_sweep("10")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#10  gh issue view failed", result.stdout)

    def test_the_same_delta_delivered_twice_is_one_attempt(self):
        delta = Path(self.tempdir.name) / "delta.json"
        worker = self.run_worker(
            [{"issue": "5", "package": "cat/transient", "version": "4.0", "args": [],
              "footer": "", "attempt": 1, "attempts": 0}],
            delta,
        )
        self.assertEqual(worker.returncode, 0, worker.stderr)
        plan = {"matrix": {"include": []}, "issues": ["5"], "results": {}}
        self.run_collect(plan, delta)
        self.run_collect(plan, delta)

        self.assertEqual(len(self.attempt_lines()), 1)

    def test_a_terminal_transient_defer_keeps_its_evidence(self):
        for run in range(3):
            delta = Path(self.tempdir.name) / f"delta-{run}.json"
            self.run_worker(
                [{"issue": "5", "package": "cat/transient", "version": "4.0", "args": [],
                  "footer": "", "attempt": 1, "attempts": len(self.attempt_lines())}],
                delta,
            )
            self.run_collect({"matrix": {"include": []}, "issues": ["5"], "results": {}}, delta)

        self.assertTrue((self.kept / "cat_transient-4.0" / "escalations.txt").exists())

    def test_the_attempts_cap_advances_within_one_day(self):
        summaries = []
        for run in range(3):
            delta = Path(self.tempdir.name) / f"delta-{run}.json"
            worker = self.run_worker(
                [{"issue": "5", "package": "cat/transient", "version": "4.0", "args": [],
                  "footer": "", "attempt": 1, "attempts": len(self.attempt_lines())}],
                delta,
            )
            self.assertEqual(worker.returncode, 0, worker.stderr)
            collected = self.run_collect({"matrix": {"include": []}, "issues": ["5"], "results": {}}, delta)
            self.assertEqual(collected.returncode, 0, collected.stderr)
            summaries.append(collected.stdout)

        self.assertIn("try 1", summaries[0])
        self.assertIn("try 2", summaries[1])
        self.assertIn("#5  deferred after 3 transient attempts", summaries[2])
        self.assertIn("cat/transient 4.0 deferred-transient", self.done.read_text())

    def run_sweep_with_judge(self, *args, verdict='{"verdict":"proceed","reasons":[],"use_flags_needed":[],"deps_changed":[],"issue_comment":"ok"}'):
        self.write_executable(self.repo / "scripts" / "autobump-judge.sh", f'#!/bin/sh\nprintf \'%s\' \'{verdict}\'\n')
        return self.run_sweep(*args, judge="stub")

    def test_a_failed_comment_lookup_posts_nothing_and_says_so(self):
        result = self.run_sweep("3", "--comment", environment_extra={"GH_API_FAIL": "1"})

        self.assertEqual(result.returncode, 0, result.stderr)
        # never fall through to a create: the sweep would add a second status comment per run
        self.assertEqual([call for call in self.gh_calls() if call[:2] == ["issue", "comment"]], [])
        self.assertIn("(status comment not posted)", result.stdout)

    def test_a_precondition_is_recorded_once_and_not_retried(self):
        result = self.run_sweep("12")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#12  done (precondition: overlay already at/ahead of 9.0)", result.stdout)
        self.assertIn("cat/ahead 9.0 done-precondition", self.done.read_text())

    def test_a_judge_that_accepts_gets_the_bump_retried(self):
        result = self.run_sweep_with_judge("4")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#4  bumped (judge accepted surface delta)", result.stdout)
        self.assertIn("cat/escalate 3.0 bumped-after-judge", self.done.read_text())
        retry = self.engine_calls()[-1]
        # the retry must carry the acceptance, or it just re-runs the escalation it came from
        self.assertIn("--accept-surface", retry)
        self.assertIn("--accept-payload", retry)

    def test_a_judge_that_declines_leaves_the_escalation(self):
        result = self.run_sweep_with_judge(
            "4", verdict='{"verdict":"human","reasons":["needs a person"],"use_flags_needed":[],"deps_changed":[],"issue_comment":"x"}'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#4  escalated", result.stdout)
        self.assertEqual([call for call in self.engine_calls() if "--accept-surface" in call], [])

    def test_a_build_log_saying_already_exists_still_defers(self):
        result = self.run_sweep("8")

        self.assertEqual(result.returncode, 0, result.stderr)
        # the reason comes off the engine's abort line, not off whatever it printed last
        self.assertIn("#8  not attempted (transient, try 1): vendor bundle unavailable", result.stdout)
        self.assertNotIn("cat/noisy", self.done.read_text())

    def test_non_utf8_engine_output_does_not_lose_the_bump(self):
        result = self.run_sweep("9")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#9  bumped", result.stdout)
        self.assertIn("cat/binary 8.0 bumped", self.done.read_text())

    def test_exit_2_retries(self):
        result = self.run_sweep("5")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#5  not attempted (transient, try 1): build host timed out", result.stdout)
        self.assertEqual(len(self.attempt_lines()), 1)
        self.assertNotIn("cat/transient 4.0 deferred-transient", self.done.read_text())

    def test_exit_2_past_cap_becomes_terminal_defer(self):
        self.assertEqual(self.run_sweep("5").returncode, 0)
        self.assertEqual(self.run_sweep("5").returncode, 0)
        result = self.run_sweep("5")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#5  deferred after 3 transient attempts: build host timed out", result.stdout)
        self.assertIn("cat/transient 4.0 deferred-transient", self.done.read_text())
        self.assertEqual(len(self.attempt_lines()), 3)
        self.assertTrue(
            all(
                # date plus the run the attempt came from, so a redelivered delta is not a retry
                re.fullmatch(r"cat/transient 4\.0 \d{4}-\d{2}-\d{2} \S+", line)
                for line in self.attempt_lines()
            )
        )

    def test_status_comment_failure_marks_summary(self):
        result = self.run_sweep("6", "--comment")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#6  bumped (status comment not posted)", result.stdout)

    def test_autobump_args_reach_engine_unchanged(self):
        result = self.run_sweep("7")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            [
                "7",
                "--rewrite-var",
                "MY_PV",
                "--rewrite-url",
                "https://example.invalid/releases/${PV}",
                "--rewrite-regex",
                '"release":"([0-9]+)"',
            ],
            self.engine_calls(),
        )


    def test_planning_output_is_disjoint_and_covers_eligible_issues(self):
        result = self.run_sweep("--plan", "3")

        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        items = [
            item
            for shard in plan["shards"]
            for item in shard["items"]
        ]
        self.assertEqual({item["issue"] for item in items}, {"3", "4", "5", "6", "7"})
        self.assertEqual(len(items), len({item["issue"] for item in items}))
        self.assertEqual(self.engine_calls(), [])

    def test_planning_keeps_existing_terminal_skip_wording(self):
        result = self.run_sweep("--plan", "3")

        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        # nothing bulky in the matrix: GitHub would make it the job title
        self.assertEqual(
            [sorted(entry) for entry in plan["matrix"]["include"]],
            [["packages", "shard"]] * len(plan["matrix"]["include"]),
        )
        self.assertEqual(plan["results"]["1"], "skip (not opted in: no autobump key)")
        self.assertEqual(plan["results"]["2"], "skip (cat/done 1.0 bumped 2026-09-01)")

    def test_worker_only_processes_its_shard_and_delta(self):
        plan = json.loads(self.run_sweep("--plan", "1").stdout)
        item = plan["shards"][0]["items"][0]
        delta = Path(self.tempdir.name) / "worker-0.json"
        done_before = self.done.read_text()

        result = self.run_worker([item], delta)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in self.engine_calls()], ["3"])
        self.assertEqual(self.done.read_text(), done_before)
        worker_delta = json.loads(delta.read_text())
        self.assertEqual(set(worker_delta["results"]), {"3"})
        self.assertEqual(len(worker_delta["done"]), 1)
        self.assertEqual(self.attempt_lines(), [])

    def test_collect_merges_worker_deltas_without_duplicates(self):
        plan = json.loads(self.run_sweep("--plan", "2").stdout)
        items = {
            item["issue"]: item
            for shard in plan["shards"]
            for item in shard["items"]
        }
        first = Path(self.tempdir.name) / "worker-0.json"
        second = Path(self.tempdir.name) / "worker-1.json"
        self.assertEqual(self.run_worker([items["3"]], first).returncode, 0)
        self.assertEqual(self.run_worker([items["6"]], second).returncode, 0)
        second_delta = json.loads(second.read_text())
        second_delta["done"].append(json.loads(first.read_text())["done"][0])
        second.write_text(json.dumps(second_delta))

        result = self.run_collect({"issues": ["3", "6"], "results": {}}, first, second)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.done.read_text().count("cat/bump 2.0 bumped"), 1)
        self.assertIn("#3  bumped", result.stdout)
        self.assertIn("#6  bumped", result.stdout)

    def test_planning_enforces_the_run_limit_across_shards(self):
        result = self.run_sweep("--limit", "2", "--plan", "3")

        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        deltas = []
        for index, shard in enumerate(plan["shards"]):
            delta = Path(self.tempdir.name) / f"worker-{index}.json"
            worker = self.run_worker(shard["items"], delta, "--limit", "2")
            self.assertEqual(worker.returncode, 0, worker.stderr)
            deltas.append(delta)
        collected = self.run_collect(plan, *deltas)

        self.assertEqual(collected.returncode, 0, collected.stderr)
        self.assertEqual([call[0] for call in self.engine_calls()], ["3", "4"])
        self.assertIn("#5  skip (per-run attempt limit 2 reached)", collected.stdout)
        self.assertIn("#7  skip (per-run attempt limit 2 reached)", collected.stdout)

    def test_single_job_invocation_keeps_existing_output(self):
        result = self.run_sweep("3", "--limit", "5")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "==== #3 cat/bump -> 2.0 (1/5) ====\n"
            "stage one\nhttps://github.com/test/overlay/pull/123\n\n"
            "==== sweep summary ====\n#3  bumped\n",
        )

    def test_no_limit_runs_the_whole_queue(self):
        result = self.run_sweep("3", "6")

        self.assertEqual(result.returncode, 0, result.stderr)
        # the header drops the "of N" when nothing caps the run
        self.assertIn("==== #3 cat/bump -> 2.0 (1) ====", result.stdout)
        self.assertIn("#3  bumped", result.stdout)
        self.assertIn("#6  bumped", result.stdout)
        self.assertNotIn("attempt limit", result.stdout)

if __name__ == "__main__":
    unittest.main()
