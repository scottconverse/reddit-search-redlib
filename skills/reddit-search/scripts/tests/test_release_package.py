"""Cross-platform release metadata, documentation, and line-ending checks."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[4]


class ReleasePackageTests(unittest.TestCase):
    def scratch_directory(self):
        parent = Path(os.environ.get("REDDITSEARCH_TEST_TMP", Path.home() / "Documents" / "Codex"))
        parent.mkdir(parents=True, exist_ok=True)
        return tempfile.TemporaryDirectory(prefix="reddit-search-release-", dir=parent)

    def test_version_is_consistent_across_skill_docs_and_receipt_source(self):
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")

        manifest = (ROOT / "skills" / "reddit-search" / "SKILL.md").read_text(encoding="utf-8")
        match = re.search(r"(?m)^metadata:\s*\n\s+version:\s*[\"']?(\d+\.\d+\.\d+)[\"']?\s*$", manifest)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), version)

        for relative in (
            "README.md",
            "USER-MANUAL.md",
            "CHANGELOG.md",
            "docs/index.html",
            "docs/manual.html",
            "docs/diagrams/windows-install-flow.svg",
        ):
            with self.subTest(file=relative):
                self.assertIn(version, (ROOT / relative).read_text(encoding="utf-8"))
        installer = (ROOT / "skills" / "reddit-search" / "scripts" / "install_windows.ps1").read_text(encoding="utf-8")
        self.assertIn("skillVersion = $skillVersion", installer)
        self.assertIn("Get-SkillVersion", installer)

    def test_release_docs_link_to_packaged_diagrams_and_manual_source_links_are_hosted(self):
        diagram_names = ("reddit-research-flow.svg", "windows-install-flow.svg")
        for name in diagram_names:
            self.assertTrue((ROOT / "docs" / "diagrams" / name).is_file())
            self.assertIn(f"docs/diagrams/{name}", (ROOT / "README.md").read_text(encoding="utf-8"))
            self.assertIn(f"docs/diagrams/{name}", (ROOT / "USER-MANUAL.md").read_text(encoding="utf-8"))
            self.assertIn(f"diagrams/{name}", (ROOT / "docs" / "manual.html").read_text(encoding="utf-8"))
        manual = (ROOT / "docs" / "manual.html").read_text(encoding="utf-8")
        self.assertNotIn('href="CHANGELOG.md"', manual)
        self.assertNotIn('href="docs/diagrams/', manual)
        self.assertIn("github.com/scottconverse/reddit-search-redlib/blob/main/CHANGELOG.md", manual)

    def test_package_is_complete_and_lf_stable_across_crlf_checkout(self):
        with self.scratch_directory() as temporary:
            base = Path(temporary)
            first_output = base / "first-output"
            first_env = dict(os.environ, REDDIT_SEARCH_PACKAGE_OUT=str(first_output))
            first = subprocess.run(
                [sys.executable, str(ROOT / "tools" / "build_package.py")],
                env=first_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)

            with zipfile.ZipFile(first_output / "reddit-search-redlib.zip") as archive:
                members = set(archive.namelist())
                required = {
                    "reddit-search/VERSION",
                    "reddit-search/README.md",
                    "reddit-search/USER-MANUAL.md",
                    "reddit-search/CHANGELOG.md",
                    "reddit-search/docs/diagrams/reddit-research-flow.svg",
                    "reddit-search/docs/diagrams/windows-install-flow.svg",
                    "reddit-search/scripts/install_windows.ps1",
                    "reddit-search/scripts/tests/test_release_package.py",
                }
                self.assertTrue(required.issubset(members))
                self.assertIsNone(archive.testzip())
                version = archive.read("reddit-search/VERSION").decode("utf-8").strip()
                skill = archive.read("reddit-search/SKILL.md").decode("utf-8")
                self.assertIn(f'version: "{version}"', skill)
                self.assertFalse(any(name.lower().endswith(".exe") for name in members))
                for name in members:
                    self.assertNotIn(b"\r", archive.read(name), name)

            crlf_root = base / "crlf-checkout"
            shutil.copytree(ROOT, crlf_root, ignore=shutil.ignore_patterns(".git", "dist", "__pycache__", "*.pyc"))
            for path in crlf_root.rglob("*"):
                if path.is_file():
                    data = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                    try:
                        data.decode("utf-8")
                    except UnicodeDecodeError:
                        continue
                    path.write_bytes(data.replace(b"\n", b"\r\n"))

            second_output = base / "second-output"
            second_env = dict(os.environ, REDDIT_SEARCH_PACKAGE_OUT=str(second_output))
            second = subprocess.run(
                [sys.executable, str(crlf_root / "tools" / "build_package.py")],
                env=second_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual(
                (first_output / "reddit-search-redlib.zip").read_bytes(),
                (second_output / "reddit-search-redlib.zip").read_bytes(),
            )
            self.assertEqual(
                (first_output / "reddit-search-redlib.skill").read_bytes(),
                (second_output / "reddit-search-redlib.skill").read_bytes(),
            )

            manifest_path = crlf_root / "skills" / "reddit-search" / "SKILL.md"
            manifest = manifest_path.read_text(encoding="utf-8")
            manifest_path.write_text(re.sub(r'(version:\s*")[^\"]+(\")', r'\g<1>9.9.9\g<2>', manifest), encoding="utf-8")
            mismatch_env = dict(os.environ, REDDIT_SEARCH_PACKAGE_OUT=str(base / "version-mismatch-output"))
            mismatch = subprocess.run(
                [sys.executable, str(crlf_root / "tools" / "build_package.py")],
                env=mismatch_env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("does not match VERSION", mismatch.stderr)


if __name__ == "__main__":
    unittest.main()
