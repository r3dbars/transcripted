#!/usr/bin/env python3
"""Check hook diagnostics in owned Git repositories without changing user config."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[2] / "scripts/dev/install-git-hooks.sh"


class GitHooksCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="git-hooks-check-")
        self.root = Path(self.temporary.name).resolve()
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("GIT_")}
        self.environment.update(HOME=str(self.root / "home"),
                                XDG_CONFIG_HOME=str(self.root / "config"),
                                GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.run_git("init", "--quiet", "--template=", ".")

    def tearDown(self):
        self.assertEqual(Path(self.temporary.name).resolve(), self.root)
        self.assertEqual(self.root.parent, Path(tempfile.gettempdir()).resolve())
        self.assertTrue(self.root.name.startswith("git-hooks-check-"))
        self.assertFalse(Path(self.temporary.name).is_symlink())
        self.temporary.cleanup()

    def run_git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=self.root,
                              env=self.environment, check=True, capture_output=True, text=True)

    def check(self):
        config = self.root / ".git/config"
        before = config.read_bytes()
        result = subprocess.run(["/bin/bash", str(INSTALLER), "--check"],
                                cwd=self.root, env=self.environment,
                                capture_output=True, text=True)
        self.assertEqual(config.read_bytes(), before, "--check must never edit Git configuration")
        return result

    def configure_relative(self):
        self.run_git("config", "--local", "core.hooksPath", ".githooks")

    def hook(self, executable=True):
        path = self.root / ".githooks/pre-push"
        path.parent.mkdir()
        path.write_text("#!/bin/bash\nexit 0\n")
        path.chmod(0o700 if executable else 0o600)
        return path

    def test_unset_hooks_path_is_not_installed(self):
        self.assertEqual(self.check().returncode, 1)

    def test_stale_absolute_hooks_path_is_not_installed(self):
        self.run_git("config", "--local", "core.hooksPath", str(self.root / "missing-hooks"))
        self.assertEqual(self.check().returncode, 1)

    def test_relative_path_without_hook_folder_is_not_installed(self):
        self.configure_relative()
        self.assertEqual(self.check().returncode, 1)
        self.assertFalse((self.root / ".githooks").exists(), "a check must not create hook files")

    def test_relative_folder_without_pre_push_is_not_installed(self):
        self.configure_relative()
        (self.root / ".githooks").mkdir()
        self.assertEqual(self.check().returncode, 1)

    def test_nonexecutable_hook_is_not_installed_or_chmodded(self):
        self.configure_relative()
        path = self.hook(executable=False)
        self.assertEqual(self.check().returncode, 1)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_a_directory_cannot_stand_in_for_the_executable_hook(self):
        self.configure_relative()
        (self.root / ".githooks/pre-push").mkdir(parents=True)
        self.assertEqual(self.check().returncode, 1)

    def test_executable_relative_hook_passes_without_mutation(self):
        self.configure_relative()
        path = self.hook()
        before = path.read_bytes()
        self.assertEqual(self.check().returncode, 0)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(path.stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
