"""Regression coverage for the Fedora-to-Betterbird conversion."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PatchApplicationTests(unittest.TestCase):
    def setUp(self):
        # A nested tree reproduces git apply silently ignoring untracked paths.
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.tree = Path(self.tmp.name)
        (self.tree / "comm").mkdir()
        (self.tree / "patches").mkdir()
        (self.tree / "platform.txt").write_text("original\n")
        (self.tree / "comm/mail.txt").write_text("original\n")
        (self.tree / "patches/series-moz").write_text("# comment\n\nplatform.patch # note\n")
        (self.tree / "patches/series").write_text("mail.patch\ncopy.patch")
        for name, filename in [("platform", "platform.txt"), ("mail", "mail.txt")]:
            (self.tree / f"patches/{name}.patch").write_text(
                f"diff --git a/{filename} b/{filename}\n"
                f"--- a/{filename}\n+++ b/{filename}\n"
                "@@ -1 +1 @@\n-original\n+changed\n"
            )
        (self.tree / "patches/copy.patch").write_text(
            "diff --git a/mail.txt b/copied.txt\n"
            "similarity index 100%\ncopy from mail.txt\ncopy to copied.txt\n"
        )

    def apply(self):
        env = dict(os.environ, GIT_DIR=str(ROOT / ".git"), GIT_WORK_TREE=str(ROOT))
        return subprocess.run(
            ["sh", str(ROOT / "bb-prep-helper.sh"), "patches"],
            cwd=self.tree, env=env, capture_output=True, text=True,
        )

    def test_applies_both_series_and_copy_inside_an_outer_repository(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        for filename in ["platform.txt", "comm/mail.txt", "comm/copied.txt"]:
            self.assertEqual((self.tree / filename).read_text(), "changed\n")

    def test_rejects_mismatched_sources(self):
        (self.tree / "platform.txt").write_text("different release\n")
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("platform.patch", result.stderr)
        self.assertEqual((self.tree / "comm/mail.txt").read_text(), "original\n")

    def test_rejects_missing_patches(self):
        (self.tree / "patches/platform.patch").unlink()
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing Betterbird patch", result.stderr)


if __name__ == "__main__":
    unittest.main()
