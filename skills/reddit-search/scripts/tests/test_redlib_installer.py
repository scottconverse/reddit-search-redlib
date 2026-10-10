"""Windows installer and package integrity checks; all writes stay in temporary roots."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[4]
SKILL = ROOT / "skills" / "reddit-search"
SCRIPTS = SKILL / "scripts"
INSTALLER = SCRIPTS / "install_windows.ps1"
PWSH = Path(r"C:\Program Files\PowerShell\7\pwsh.exe")
PS51 = Path(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe")
PYTHON_DIR = Path(sys.executable).parent
PIN = "a4d36e954cf1bd64f209cd8868c5a29edc81b374"
REPOSITORY = "https://github.com/redlib-org/redlib.git"


def scratch_directory():
    preferred = Path(os.environ.get("REDDITSEARCH_TEST_TMP", Path.home() / "Documents" / "Codex"))
    preferred.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="reddit-search-installer-", dir=preferred)


@unittest.skipUnless(os.name == "nt" and PWSH.is_file(), "requires native Windows PowerShell 7")
class RedlibInstallerTests(unittest.TestCase):
    def run_pwsh(self, args, env=None):
        process_env = dict(os.environ)
        process_env["PATH"] = str(PYTHON_DIR) + os.pathsep + process_env.get("PATH", "")
        if env:
            process_env.update(env)
        return subprocess.run(
            [str(PWSH), "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", *map(str, args)],
            text=True,
            capture_output=True,
            env=process_env,
        )

    def isolated_env(self, root):
        return {
            "LOCALAPPDATA": str(root / "localappdata"),
            "USERPROFILE": str(root / "profile"),
        }

    def test_rss_only_installs_complete_skill_and_writes_honest_receipt(self):
        with scratch_directory() as scratch:
            root = Path(scratch)
            skill_target = root / "profile" / ".agents" / "skills" / "reddit-search"
            skill_target.mkdir(parents=True)
            (skill_target / "SKILL.md").write_text("old skill", encoding="utf-8")
            config_path = root / "localappdata" / "RedditSearch" / "config.json"
            result = self.run_pwsh(
                [INSTALLER, "-SourceRoot", SKILL, "-SkillDirectory", skill_target, "-ConfigPath", config_path, "-RssOnly"],
                self.isolated_env(root),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt["mode"], "rss-only")
            self.assertEqual(receipt["skillVersion"], (ROOT / "VERSION").read_text(encoding="utf-8").strip())
            self.assertTrue(receipt["skillInstalled"])
            self.assertTrue(receipt["parserVerified"])
            self.assertFalse(receipt["redlibInstalled"])
            self.assertFalse(receipt["running"])
            self.assertFalse(receipt["usable"])
            self.assertFalse(receipt["rssVerified"])
            self.assertIsNone(receipt["baseUrl"])
            self.assertIsNone(receipt["previousConfigBackup"])
            self.assertTrue((skill_target / "scripts" / "get_redlib_config.ps1").is_file())
            self.assertTrue((skill_target / "scripts" / "redlib_windows_common.ps1").is_file())
            backup_root = root / "localappdata" / "RedditSearch" / "backups"
            backups = list(backup_root.glob("reddit-search-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual((backups[0] / "SKILL.md").read_text(encoding="utf-8"), "old skill")
            self.assertFalse((root / "localappdata" / "RedditSearch" / "Redlib").exists())

            config = self.run_pwsh([SCRIPTS / "get_redlib_config.ps1", "-ConfigPath", config_path], self.isolated_env(root))
            self.assertEqual(config.returncode, 0, config.stderr)
            self.assertEqual(json.loads(config.stdout)["mode"], "rss-only")

            repeated = self.run_pwsh(
                [INSTALLER, "-SourceRoot", SKILL, "-SkillDirectory", skill_target, "-ConfigPath", config_path, "-RssOnly"],
                self.isolated_env(root),
            )
            self.assertEqual(repeated.returncode, 0, repeated.stderr)
            second_receipt = json.loads(repeated.stdout)
            self.assertTrue(Path(second_receipt["previousConfigBackup"]).is_file())
            self.assertEqual(json.loads(Path(second_receipt["previousConfigBackup"]).read_text(encoding="utf-8"))["mode"], "rss-only")

    @unittest.skipUnless(PS51.is_file(), "requires Windows PowerShell 5.1")
    def test_documented_entrypoint_relaunches_from_windows_powershell_51(self):
        with scratch_directory() as scratch:
            root = Path(scratch)
            skill_target = root / "profile" / ".agents" / "skills" / "reddit-search"
            config_path = root / "localappdata" / "RedditSearch" / "config.json"
            env = dict(os.environ)
            env["PATH"] = str(PYTHON_DIR) + os.pathsep + env.get("PATH", "")
            env.update(self.isolated_env(root))
            result = subprocess.run(
                [str(PS51), "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(INSTALLER), "-SkillDirectory", str(skill_target), "-ConfigPath", str(config_path), "-RssOnly"],
                text=True,
                capture_output=True,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt["mode"], "rss-only")
            self.assertTrue((skill_target / "SKILL.md").is_file())

    def test_bad_pin_fails_without_success_receipt_or_config_overwrite(self):
        with scratch_directory() as scratch:
            root = Path(scratch)
            skill_target = root / "profile" / ".agents" / "skills" / "reddit-search"
            initial = self.run_pwsh(
                [INSTALLER, "-SourceRoot", SKILL, "-SkillDirectory", skill_target, "-ConfigPath", root / "config.json", "-RssOnly"],
                self.isolated_env(root),
            )
            self.assertEqual(initial.returncode, 0, initial.stderr)
            config_path = root / "config.json"
            before = config_path.read_bytes()
            bad_root = self.make_install_root(root / "wrong-pin", commit="0" * 40)
            failed = self.run_pwsh(
                [INSTALLER, "-SourceRoot", SKILL, "-SkillDirectory", skill_target, "-ConfigPath", config_path, "-RedlibInstallRoot", bad_root, "-SkipSkillInstall"],
                self.isolated_env(root),
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("pinned commit", (failed.stdout + failed.stderr).lower())
            self.assertNotIn('"mode": "redlib"', failed.stdout)
            self.assertEqual(config_path.read_bytes(), before)

    def test_skip_skill_install_rejects_missing_or_incomplete_target(self):
        with scratch_directory() as scratch:
            root = Path(scratch)
            target = root / "missing-skill"
            config_path = root / "config.json"
            result = self.run_pwsh(
                [INSTALLER, "-SourceRoot", SKILL, "-SkillDirectory", target, "-ConfigPath", config_path, "-RssOnly", "-SkipSkillInstall"],
                self.isolated_env(root),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("skilldirectory is incomplete", (result.stdout + result.stderr).lower())
            self.assertFalse(config_path.exists())

    def test_saved_redlib_config_discovers_its_recorded_root(self):
        with scratch_directory() as scratch:
            root = Path(scratch)
            skill_target = root / "profile" / ".agents" / "skills" / "reddit-search"
            installed = self.run_pwsh(
                [INSTALLER, "-SourceRoot", SKILL, "-SkillDirectory", skill_target, "-ConfigPath", root / "config.json", "-RssOnly"],
                self.isolated_env(root),
            )
            self.assertEqual(installed.returncode, 0, installed.stderr)
            config_path = root / "config.json"
            configured_root = self.make_install_root(root / "configured-redlib", commit="0" * 40)
            config = {
                "schemaVersion": 1,
                "mode": "redlib",
                "skillDirectory": str(skill_target),
                "skillInstalled": True,
                "installed": True,
                "redlibInstalled": True,
                "running": True,
                "usable": True,
                "rssVerified": None,
                "redlibInstallRoot": str(configured_root),
                "baseUrl": "http://127.0.0.1:18080",
                "port": 18080,
                "expectedCommit": PIN,
                "verifiedAt": "2026-10-09T00:00:00Z",
            }
            config_path.write_text(json.dumps(config), encoding="utf-8")
            helper = self.run_pwsh([SCRIPTS / "get_redlib_config.ps1", "-ConfigPath", config_path], self.isolated_env(root))
            self.assertEqual(helper.returncode, 0, helper.stderr)
            self.assertEqual(json.loads(helper.stdout)["redlibInstallRoot"], str(configured_root))

            config["port"] = 0
            config["baseUrl"] = "http://127.0.0.1:0"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            invalid_endpoint = self.run_pwsh([SCRIPTS / "get_redlib_config.ps1", "-ConfigPath", config_path], self.isolated_env(root))
            self.assertNotEqual(invalid_endpoint.returncode, 0)
            self.assertIn("port is outside", (invalid_endpoint.stdout + invalid_endpoint.stderr).lower())
            config["port"] = 18080
            config["baseUrl"] = "http://127.0.0.1:18080"
            config_path.write_text(json.dumps(config), encoding="utf-8")

            failed = self.run_pwsh(
                [INSTALLER, "-SourceRoot", SKILL, "-SkillDirectory", skill_target, "-ConfigPath", config_path, "-SkipSkillInstall"],
                self.isolated_env(root),
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("pinned commit", (failed.stdout + failed.stderr).lower())

    def test_setup_reuses_pinned_install_without_compiler_tools(self):
        with scratch_directory() as scratch:
            root = Path(scratch)
            redlib = self.make_install_root(root / "existing-redlib", commit=PIN, port=18123)
            git = shutil.which("git")
            self.assertIsNotNone(git, "Git is needed only to verify the retained source pin")
            source = Path(redlib) / "buildsrc" / "a4d36e9"
            subprocess.run([git, "init", "--quiet", str(source)], check=True)
            git_dir = source / ".git"
            (git_dir / "refs" / "heads").mkdir(parents=True, exist_ok=True)
            (git_dir / "refs" / "heads" / "main").write_text(PIN, encoding="ascii")
            subprocess.run([git, "-C", str(source), "symbolic-ref", "HEAD", "refs/heads/main"], check=True)
            subprocess.run([git, "-C", str(source), "remote", "add", "origin", REPOSITORY], check=True)

            git_dir_path = str(Path(git).parent)
            env = self.isolated_env(root)
            env["PATH"] = os.pathsep.join([r"C:\Windows\System32", git_dir_path])
            result = self.run_pwsh(
                [SCRIPTS / "setup_redlib_windows.ps1", "-InstallRoot", redlib],
                env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            record = json.loads(result.stdout)
            self.assertEqual(record["commit"], PIN)
            self.assertEqual(record["port"], 18123)
            self.assertTrue(Path(record["executable"]).is_file())

    def test_process_pin_and_loopback_guards(self):
        with scratch_directory() as scratch:
            result = self.run_pwsh(
                [SCRIPTS / "tests" / "test_redlib_windows_guards.ps1", "-CommonScript", SCRIPTS / "redlib_windows_common.ps1"],
                self.isolated_env(Path(scratch)),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("guards passed", result.stdout)

    def test_package_builder_includes_complete_windows_setup_without_binary(self):
        with scratch_directory() as scratch:
            output = Path(scratch) / "package"
            env = dict(os.environ, REDDIT_SEARCH_PACKAGE_OUT=str(output))
            subprocess.run([sys.executable, str(ROOT / "tools" / "build_package.py")], check=True, env=env, capture_output=True, text=True)
            archive_path = output / "reddit-search-redlib.zip"
            with zipfile.ZipFile(archive_path) as archive:
                members = set(archive.namelist())
                self.assertIsNone(archive.testzip())
                for required in (
                    "SKILL.md",
                    "scripts/install_windows.ps1",
                    "scripts/get_redlib_config.ps1",
                    "scripts/redlib_windows_common.ps1",
                    "scripts/setup_redlib_windows.ps1",
                    "scripts/start_redlib_windows.ps1",
                    "scripts/test_redlib_windows.ps1",
                    "scripts/stop_redlib_windows.ps1",
                    "references/windows-redlib.md",
                ):
                    self.assertIn("reddit-search/" + required, members)
                for required in (
                    "VERSION",
                    "README.md",
                    "USER-MANUAL.md",
                    "CHANGELOG.md",
                    "docs/diagrams/reddit-research-flow.svg",
                    "docs/diagrams/windows-install-flow.svg",
                ):
                    self.assertIn("reddit-search/" + required, members)
                version = archive.read("reddit-search/VERSION").decode("utf-8").strip()
                manifest = archive.read("reddit-search/SKILL.md").decode("utf-8")
                self.assertIn(f'version: "{version}"', manifest)
                self.assertIn(f"Version {version}", archive.read("reddit-search/README.md").decode("utf-8"))
                self.assertIn(f"Project version {version}", archive.read("reddit-search/USER-MANUAL.md").decode("utf-8"))
                self.assertFalse(any(name.lower().endswith(".exe") for name in members))
            self.assertEqual(archive_path.read_bytes(), (output / "reddit-search-redlib.skill").read_bytes())

    def make_install_root(self, root, commit, port=18080):
        root.mkdir(parents=True)
        source = root / "buildsrc" / "a4d36e9"
        source.mkdir(parents=True)
        executable = root / "versions" / "a4d36e9" / "bin" / "redlib.exe"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"scratch executable placeholder")
        record = {
            "schemaVersion": 2,
            "versionId": "a4d36e9",
            "ref": "main",
            "commit": commit,
            "repository": REPOSITORY,
            "executable": str(executable),
            "source": str(source),
            "port": port,
            "baseUrl": f"http://127.0.0.1:{port}",
            "installedAt": "2026-10-09T00:00:00Z",
        }
        (root / "install.json").write_text(json.dumps(record), encoding="utf-8")
        return root


if __name__ == "__main__":
    unittest.main()
