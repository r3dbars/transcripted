#!/usr/bin/env python3
"""Run release registration against owned fixtures and fake external tools only."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[2]


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="transcripted-sentry-registration-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        release = self.root / "scripts/release"
        release.mkdir(parents=True)
        for name in ("register-sentry-release.sh", "sentry-release-metadata.py"):
            shutil.copyfile(SOURCE_ROOT / "scripts/release" / name, release / name)
        with (self.root / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleShortVersionString": "9.9.9", "CFBundleVersion": "999"}, handle)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        self.tool("sentry-cli", '''#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
if [ "$1 $2" = "releases info" ] && [ -n "${REPLACE_DSYM_UUID:-}" ]; then
  printf '%s' "$REPLACE_DSYM_UUID" > "$SENTRY_DEBUG_FILES_PATH/uuid"
fi
if [ "$1 $2" = "releases info" ]; then exit "${RELEASE_EXISTS_EXIT:-1}"; fi
exit 0
''')
        self.tool("dwarfdump", '''#!/bin/bash
case "$2" in
  *app-binary) printf 'UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64) fixture\\n' ;;
  *)
    uuid="${DSYM_UUID:-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"
    if [ -f "$2/uuid" ]; then uuid="$(cat "$2/uuid")"; fi
    printf 'UUID: %s (arm64) fixture\\n' "$uuid" ;;
esac
''')
        self.app = self.root / "app-binary"
        self.app.touch()
        self.dsym = self.root / "release.dSYM"
        self.dsym.mkdir()
        # Do not inherit release credentials/config or invoke a real Sentry client.
        self.env = {"PATH": str(self.bin) + os.pathsep + os.defpath,
                    "CALL_LOG": str(self.calls), "SENTRY_SET_COMMITS": "0",
                    "SENTRY_APP_BINARY_PATH": str(self.app),
                    "SENTRY_DEBUG_FILES_PATH": str(self.dsym)}

    def tool(self, name, body):
        target = self.bin / name
        target.write_text(body)
        target.chmod(0o700)

    def register(self, **overrides):
        result = subprocess.run(["bash", str(self.root / "scripts/release/register-sentry-release.sh")],
                                env={**self.env, **overrides}, capture_output=True, text=True)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return result, calls

    def test_missing_required_symbols_prevent_all_sentry_calls(self):
        self.dsym.rmdir()
        result, calls = self.register()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Missing Sentry debug files", result.stderr)
        self.assertEqual(calls, [])

    def test_mismatched_symbols_prevent_all_sentry_calls(self):
        result, calls = self.register(DSYM_UUID="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("do not match", result.stderr)
        self.assertEqual(calls, [])

    def test_missing_binary_prevents_all_sentry_calls(self):
        self.app.unlink()
        result, calls = self.register()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Missing app binary", result.stderr)
        self.assertEqual(calls, [])

    def test_matching_symbols_create_and_upload_release(self):
        result, calls = self.register()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 3)
        self.assertTrue(calls[0].startswith("releases info "), calls)
        self.assertTrue(calls[1].startswith("releases new "), calls)
        self.assertTrue(calls[2].startswith("debug-files upload "), calls)
        self.assertIn("--no-sources", calls[2])

    def test_existing_release_is_not_finalized_again(self):
        result, calls = self.register(RELEASE_EXISTS_EXIT="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertFalse(any("releases new" in call for call in calls), calls)

    def test_symbols_replaced_during_registration_are_not_uploaded(self):
        result, calls = self.register(REPLACE_DSYM_UUID="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("do not match", result.stderr)
        self.assertFalse(any("debug-files upload" in call for call in calls), calls)

    def test_optional_missing_symbols_keep_explicit_warning(self):
        self.dsym.rmdir()
        result, calls = self.register(SENTRY_REQUIRE_DEBUG_FILES="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release is yellow", result.stdout)
        self.assertEqual(len(calls), 2)

    def test_explicitly_disabled_upload_does_not_require_symbols(self):
        self.dsym.rmdir()
        result, calls = self.register(SENTRY_UPLOAD_DEBUG_FILES="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release is yellow", result.stdout)
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
