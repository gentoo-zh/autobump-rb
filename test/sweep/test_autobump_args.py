"""What a package's autobump value asks the engine for.

The value carries the retention policy, so a misread turns "keep one old version" into
"replace it" - which is a git rm the maintainer did not ask for.
"""
import subprocess
import sys
import tempfile
import textwrap
import unittest
import os
from pathlib import Path


def overlay_root():
    """The overlay checkout these tests drive; the driver they test lives there, not here."""
    root = os.environ.get("AUTOBUMP_OVERLAY")
    if not root:
        raise SystemExit("set AUTOBUMP_OVERLAY to an overlay checkout")
    return Path(root)


ROOT = overlay_root()
ARGS = ROOT / "scripts/autobump-args.py"


class AutobumpArgsTest(unittest.TestCase):
    def flags(self, table, package="cat/pkg"):
        with tempfile.TemporaryDirectory() as tmp:
            toml = Path(tmp) / ".github/workflows/overlay.toml"
            toml.parent.mkdir(parents=True)
            toml.write_text(textwrap.dedent(table))
            result = subprocess.run(
                [sys.executable, str(ARGS), package, str(toml)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.split()

    def test_true_is_plain_enablement(self):
        self.assertEqual(self.flags('["cat/pkg"]\nautobump = true\n'), [])

    def test_one_keeps_one_old_version(self):
        # `1` compares equal to True in Python; it must still mean the number
        self.assertEqual(self.flags('["cat/pkg"]\nautobump = 1\n'), ["--keep-old=1"])

    def test_a_count_keeps_that_many(self):
        self.assertEqual(self.flags('["cat/pkg"]\nautobump = 3\n'), ["--keep-old=3"])

    def test_all_keeps_every_version(self):
        self.assertEqual(self.flags('["cat/pkg"]\nautobump = "all"\n'), ["--keep-old"])

    def test_zero_keeps_nothing_extra(self):
        self.assertEqual(self.flags('["cat/pkg"]\nautobump = 0\n'), [])


if __name__ == "__main__":
    unittest.main()
