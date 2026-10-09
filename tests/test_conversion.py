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


class SpecConversionTests(unittest.TestCase):
    def test_preserves_openpgp_provides_and_uses_matching_sources_and_icons(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = Path(tmp) / "betterbird.spec"
            spec.write_text("""Name: thunderbird
Version: 153.0.2
Release: %autorelease
Summary: Thunderbird
URL: https://www.thunderbird.net/
Source0: thunderbird-%{version}.source.tar.xz
Source1: thunderbird-langpacks.tar.xz
Source10: thunderbird-mozconfig
Source11: thunderbird-mozconfig-branded
Source12: thunderbird-redhat-default-prefs.js
Source25: thunderbird-symbolic.svg
Source33: net.thunderbird.Thunderbird.desktop
Source34: net.thunderbird.Thunderbird.appdata.xml
BuildRequires: make
Requires: (thunderbird-librnp%{?_isa} or librnp%{?_isa})
%description
Original description.
%package librnp-rnp
Summary: OpenPGP implementation for Thunderbird based on RNP
Provides: thunderbird-librnp
Provides: thunderbird-librnp%{?_isa}
Conflicts: thunderbird-librnp%{?_isa}
%prep
%setup -q
%patch -P 1 -p1
%{__rm} -f .mozconfig
%{__cp} %{SOURCE10} .mozconfig
echo 'export MOZ_APP_REMOTINGNAME=net.thunderbird.Thunderbird' >> .mozconfig
%install
cp default${s}.png %{buildroot}/icons/hicolor/${s}x${s}/apps/thunderbird.png
%files
%{_datadir}/icons/hicolor/16x16/apps/thunderbird.png
%changelog
Old changelog.
""")
            source_url = "https://archive.mozilla.org/pub/thunderbird/candidates/153.4.0esr-candidates/build1/source/thunderbird-153.4.0esr.source.tar.xz"
            subprocess.run(
                [str(ROOT / "spec-edit.sh"), str(spec), str(ROOT / "description.txt"),
                 "betterbird-langpacks", "bb10", "153.4.0", source_url],
                check=True, capture_output=True, text=True,
            )
            result = spec.read_text()
            self.assertIn("Requires: (betterbird-librnp%{?_isa} or librnp%{?_isa})", result)
            self.assertIn("Provides: betterbird-librnp%{?_isa}", result)
            self.assertIn("Version: 153.4.0", result)
            self.assertIn("Release: 1.bb10%{?dist}", result)
            self.assertIn(source_url, result)
            self.assertIn("%setup -q -n thunderbird-%{version}", result)
            self.assertIn("Source10: thunderbird-mozconfig", result)
            self.assertIn("/icons/hicolor/${s}x${s}/apps/eu.betterbird.Betterbird.png", result)
            self.assertIn("/icons/hicolor/16x16/apps/eu.betterbird.Betterbird.png", result)
            self.assertIn("export MOZ_APP_REMOTINGNAME=eu.betterbird.Betterbird'", result)
            self.assertLess(result.index("%patch -P 1"), result.index("./.bb-prep.sh bb-patches"))
            self.assertNotIn("Old changelog", result)


if __name__ == "__main__":
    unittest.main()
