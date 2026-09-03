"""The contract between .github/workflows/autobump.yml and scripts/autobump-sweep.py.

Renaming a flag or an environment variable on either side leaves the driver's own tests green
and breaks every production run at the first job, so the two are compared here directly. Both
sides are parsed; neither list is written out, or this file becomes a third copy to keep in sync.
"""
import ast
from fnmatch import fnmatch
import re
import shlex
import unittest
import os
from pathlib import Path

import yaml

def overlay_root():
    """The overlay checkout these tests drive; the driver they test lives there, not here."""
    root = os.environ.get("AUTOBUMP_OVERLAY")
    if not root:
        raise SystemExit("set AUTOBUMP_OVERLAY to an overlay checkout")
    return Path(root)


ROOT = overlay_root()
WORKFLOW = ROOT / ".github/workflows/autobump.yml"
DRIVER = ROOT / "scripts/autobump-sweep.py"


def driver_source():
    return DRIVER.read_text()


def accepted_flags():
    """Flags parse_args() understands, from the tables it branches on."""
    tree = ast.parse(driver_source())
    flags = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Dict):
            flags.update(k.value for k in node.keys if isinstance(k, ast.Constant) and str(k.value).startswith("--"))
        if isinstance(node, ast.Compare) and isinstance(node.left, ast.Name) and node.left.id == "arg":
            flags.update(
                c.value for c in node.comparators if isinstance(c, ast.Constant) and str(c.value).startswith("--")
            )
    return flags


def value_flags():
    tree = ast.parse(driver_source())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == "VALUE_FLAGS" for t in node.targets
        ):
            return {k.value for k in node.value.keys if isinstance(k, ast.Constant)}
    raise AssertionError("VALUE_FLAGS not found in the driver")


def read_environment():
    return set(re.findall(r"os\.environ\.get\(\s*[\"']([A-Z_]+)[\"']", driver_source()))


def tokens_of(line):
    """The shell words of a run line. `${{ x }}` is two words to shlex, so flatten it first."""
    return shlex.split(line.replace("${{", "${").replace("}}", "}"))


def placeholders(text):
    """A path with every shell or workflow expression replaced by one marker."""
    return re.sub(r"\$\{\{[^}]*\}\}|\$\{?[A-Za-z_][A-Za-z_0-9]*\}?", "*", text)


def jobs():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


def driver_steps():
    """(job name, step) for every step that runs the driver."""
    for name, job in jobs().items():
        for step in job.get("steps", []) or []:
            if "autobump-sweep.py" in (step.get("run") or ""):
                yield name, step


class AutobumpWorkflowContractTest(unittest.TestCase):
    def test_the_workflow_runs_the_driver(self):
        self.assertTrue(list(driver_steps()), "no job runs autobump-sweep.py")

    def test_every_flag_the_workflow_passes_is_one_the_driver_accepts(self):
        known = accepted_flags()
        for job, step in driver_steps():
            for line in step["run"].splitlines():
                if "autobump-sweep.py" not in line:
                    continue
                for token in tokens_of(line):
                    if token.startswith("--"):
                        self.assertIn(token, known, f"{job}: {token} is not a flag the driver accepts")

    def test_a_flag_that_takes_a_value_is_given_one(self):
        takes_value = value_flags()
        for job, step in driver_steps():
            for line in step["run"].splitlines():
                if "autobump-sweep.py" not in line:
                    continue
                tokens = tokens_of(line)
                for index, token in enumerate(tokens):
                    if token in takes_value:
                        rest = tokens[index + 1 : index + 2]
                        self.assertTrue(rest and not rest[0].startswith("--"), f"{job}: {token} has no value")

    def test_the_ledger_jobs_say_where_the_ledgers_live(self):
        # only the planner and the collector touch the ledgers; a worker is handed its items
        for job, step in driver_steps():
            if not re.search(r"--(plan|collect)\b", step["run"]):
                continue
            environment = set(step.get("env") or {}) | set(jobs()[job].get("env") or {})
            self.assertIn("XDG_STATE_HOME", environment, f"{job} reads the ledgers from an unset state dir")

    def test_the_delta_a_worker_writes_is_the_one_collect_downloads(self):
        written, uploaded, downloaded, collected = set(), set(), set(), ""
        for name, job in jobs().items():
            for step in job.get("steps", []) or []:
                run = step.get("run") or ""
                uses = step.get("uses") or ""
                with_ = step.get("with") or {}
                written.update(re.findall(r"--delta \"?([^\" ]+\.json)", run))
                if uses.startswith("actions/upload-artifact") and "delta" in str(with_.get("name", "")):
                    uploaded.add((with_["name"], with_["path"]))
                if uses.startswith("actions/download-artifact") and "delta" in str(with_.get("pattern", "")):
                    downloaded.add((with_["pattern"], with_.get("path", "")))
                if "--collect" in run:
                    collected = run

        self.assertEqual(len(written), 1, f"expected one delta name, got {written}")
        self.assertEqual(len(uploaded), 1, f"expected one delta artifact, got {uploaded}")
        self.assertEqual(len(downloaded), 1, f"expected one delta download, got {downloaded}")
        (artifact, path), = uploaded
        (pattern, into), = downloaded
        # $SHARD_ID in the shell, matrix.shard in the YAML: compare the shape around it
        self.assertEqual(placeholders(path), placeholders(next(iter(written))),
                         "the artifact does not carry the file the worker wrote")
        self.assertTrue(fnmatch(artifact, pattern), f"{pattern!r} does not match the artifact {artifact!r}")
        self.assertIn(f"{into}/", collected, "collect does not read the directory the deltas landed in")


if __name__ == "__main__":
    unittest.main()
