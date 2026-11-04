#!/usr/bin/env python3
"""Run the real verification wrapper with owned files and fake native commands."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(os.environ.get("VERIFY_RECEIPTS_SCRIPT", Path(__file__).with_name("verify-change.sh")))


class VerifyReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="verify-receipts-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / ".build/verify"
        self.output.mkdir(parents=True)
        self.bin = self.root / "fake-bin"
        self.bin.mkdir()
        (self.root / "scripts/dev").mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.root / "scripts/dev/verify-change.sh")
        self.write("scripts/ops/native-smoke-isolation.py", "import sys\nsys.exit(3)\n")
        for directory in ("deps-libs", "deps-modules"):
            self.write(f"{directory}/owned-fixture", "fixture")
        self.write("build.sh", '#!/bin/bash\nif [ "${FAKE_BUILD:-}" = interrupt ]; then kill -TERM "$PPID"; exit 1; fi\nexit "${FAKE_BUILD:-0}"\n')
        self.write("build-deps.sh", "#!/bin/bash\nexit 99\n")
        self.write("fake-bin/pgrep", '#!/bin/bash\nexit "${FAKE_APP_RUNNING:-1}"\n')
        self.write("fake-bin/swift", """#!/usr/bin/env python3
import json, os, pathlib, sys
status = int(os.environ.get('FAKE_SMOKE', '0'))
if status == 0:
    report = pathlib.Path(sys.argv[sys.argv.index('--report') + 1])
    report.write_text(json.dumps({'ownedFixture': 'current'}))
sys.exit(status)
""")
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"}
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Owned fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-qm", "Owned verification fixture")
        self.stale = ("meetings.json", "ui.json", "launch-latency.json", "paste.log",
                      "meetings.log", "ui.log", "speed.log", "speed-preflight.log", "build.log", "deps.log")
        for name in (*self.stale, "summary.md"):
            (self.output / name).write_text("OLD PASS")

    def write(self, relative, contents):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        path.chmod(0o700)

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def run_verify(self, *arguments, **environment):
        return subprocess.run(["bash", "scripts/dev/verify-change.sh", "--base", "HEAD", *arguments],
                              cwd=self.root, env={**self.env, **environment},
                              capture_output=True, text=True, timeout=15)

    def assert_no_old_reports(self):
        for name in self.stale:
            path = self.output / name
            if path.exists():
                self.assertNotEqual(path.read_text(), "OLD PASS", name)
        self.assertNotIn("OLD PASS", (self.output / "summary.md").read_text())

    def test_running_app_skips_and_invalidates_all_previous_reports(self):
        result = self.run_verify("--only", "meetings,ui,speed", FAKE_APP_RUNNING="0")
        self.assertEqual(result.returncode, 0)
        summary = (self.output / "summary.md").read_text()
        self.assertIn("| meetings | SKIP |", summary)
        self.assertIn("| ui | SKIP |", summary)
        self.assertIn("| speed | SKIP |", summary)
        self.assert_no_old_reports()
        for name in ("meetings.json", "ui.json", "launch-latency.json"):
            self.assertFalse((self.output / name).exists())

    def test_incomplete_smoke_does_not_reuse_previous_native_report(self):
        result = self.run_verify("--only", "meetings,ui", FAKE_SMOKE="3")
        self.assertEqual(result.returncode, 0)
        self.assert_no_old_reports()
        self.assertFalse((self.output / "meetings.json").exists())
        self.assertFalse((self.output / "ui.json").exists())

    def test_build_failure_cannot_reuse_previous_reports(self):
        result = self.run_verify("--only", "meetings,ui", FAKE_BUILD="1")
        self.assertEqual(result.returncode, 1)
        self.assert_no_old_reports()
        self.assertIn("| meetings | FAIL |", (self.output / "summary.md").read_text())

    def test_success_keeps_only_reports_produced_by_this_selection(self):
        result = self.run_verify("--only", "meetings")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.output / "meetings.json").read_text()), {"ownedFixture": "current"})
        self.assertFalse((self.output / "ui.json").exists())
        self.assertIn("| meetings | PASS |", (self.output / "summary.md").read_text())
        self.assert_no_old_reports()

    def test_isolation_preflight_skip_removes_previous_launch_samples(self):
        result = self.run_verify("--only", "speed")
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.output / "launch-latency.json").exists())
        self.assertIn("| speed | SKIP |", (self.output / "summary.md").read_text())
        self.assert_no_old_reports()

    def test_invalid_base_leaves_current_incomplete_summary(self):
        result = self.run_verify("--base", "missing-owned-ref", "--only", "ui")
        self.assertEqual(result.returncode, 2)
        self.assert_no_old_reports()
        self.assertIn("INCOMPLETE", (self.output / "summary.md").read_text())

    def test_unknown_option_invalidates_old_proof(self):
        result = self.run_verify("--not-a-verification-option")
        self.assertEqual(result.returncode, 2)
        self.assert_no_old_reports()
        self.assertIn("INCOMPLETE", (self.output / "summary.md").read_text())

    def test_missing_option_value_invalidates_old_proof(self):
        result = self.run_verify("--only")
        self.assertEqual(result.returncode, 2)
        self.assert_no_old_reports()
        self.assertIn("INCOMPLETE", (self.output / "summary.md").read_text())

    def test_interrupted_build_does_not_expose_old_success(self):
        result = self.run_verify("--only", "meetings", FAKE_BUILD="interrupt")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_old_reports()
        self.assertIn("INCOMPLETE", (self.output / "summary.md").read_text())

    def test_listing_and_help_are_read_only(self):
        for flag in ("--list", "--help"):
            result = self.run_verify("--only", "ui", flag)
            self.assertEqual(result.returncode, 0)
            for name in (*self.stale, "summary.md"):
                self.assertEqual((self.output / name).read_text(), "OLD PASS", name)

    def test_summary_symlink_is_replaced_without_touching_its_target(self):
        outside = self.root / "other-owned-summary.md"
        outside.write_text("UNRELATED EVIDENCE")
        summary = self.output / "summary.md"
        summary.unlink()
        summary.symlink_to(outside)
        result = self.run_verify("--only", "ui", FAKE_APP_RUNNING="0")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(outside.read_text(), "UNRELATED EVIDENCE")
        self.assertFalse(summary.is_symlink())
        self.assertIn("| ui | SKIP |", summary.read_text())

    def test_symlinked_receipt_directory_does_not_erase_other_evidence(self):
        outside = self.root / "other-owned-evidence"
        self.output.rename(outside)
        self.output.symlink_to(outside, target_is_directory=True)
        result = self.run_verify("--only", "ui")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Refusing", result.stderr)
        self.assertEqual((outside / "ui.json").read_text(), "OLD PASS")


if __name__ == "__main__":
    unittest.main()
