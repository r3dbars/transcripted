#!/usr/bin/env python3
"""Offline built-app contract tests; no signing, keychain, or hardware access."""

import copy
import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("nightly_security", ROOT / "scripts/ops/nightly-security-check.py")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class BuiltAppEntitlementTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / "config/security/nightly-security-manifest.json").read_text())
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Transcripted.app"
        (self.app / "Contents").mkdir(parents=True)

    def check(self, channel, entitlements, info_overrides=None):
        info = dict(self.manifest["expected_info_plist"])
        if channel is not None:
            info["TranscriptedBuildChannel"] = channel
        info.update(info_overrides or {})
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        with patch.object(CHECKER, "parse_codesign_entitlements", return_value=entitlements):
            return {item["check_id"] for item in CHECKER.check_built_app(self.root, self.manifest, str(self.app))}

    def test_each_channel_accepts_only_its_exact_contract(self):
        for channel, contract in [("local", "local"), ("release", "beta")]:
            with self.subTest(channel=channel):
                self.assertEqual(self.check(channel, self.manifest["expected_entitlements"][contract]), set())

    def test_swapped_contracts_fail(self):
        for channel, contract in [("local", "beta"), ("release", "local")]:
            with self.subTest(channel=channel):
                self.assertIn("built-entitlements-drift", self.check(channel, self.manifest["expected_entitlements"][contract]))

    def test_unknown_missing_and_malformed_channels_fail(self):
        for channel in [None, "", "beta", "production", "Release", ["release"]]:
            with self.subTest(channel=channel):
                self.assertIn("built-channel-unknown", self.check(channel, self.manifest["expected_entitlements"]["beta"]))

    def test_added_removed_or_changed_entitlements_fail(self):
        for channel, contract in [("local", "local"), ("release", "beta")]:
            expected = self.manifest["expected_entitlements"][contract]
            altered = [copy.deepcopy(expected) for _ in range(3)]
            altered[0]["com.example.unreviewed"] = True
            altered[1].pop("com.apple.security.device.audio-input")
            altered[2]["com.apple.security.device.audio-input"] = False
            for index, entitlements in enumerate(altered):
                with self.subTest(channel=channel, alteration=index):
                    self.assertIn("built-entitlements-drift", self.check(channel, entitlements))

    def test_forbidden_permissions_fail_even_with_unknown_channel(self):
        for channel in ["local", "release", None]:
            entitlements = dict(self.manifest["expected_entitlements"]["beta"])
            entitlements[self.manifest["forbidden_entitlements"][0]] = True
            with self.subTest(channel=channel):
                self.assertIn("built-forbidden-entitlements", self.check(channel, entitlements))

    def test_unreadable_signature_and_info_drift_still_fail(self):
        self.assertIn("built-entitlements-unreadable", self.check("release", None))
        self.assertIn("built-info-SUFeedURL", self.check("release", self.manifest["expected_entitlements"]["beta"], {"SUFeedURL": "https://invalid.example/feed"}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
