#!/usr/bin/env python3
"""Offline behavior tests for the nightly security checker.

They call the checker's functions on synthetic fixtures in a temp directory:
no signing, keychain, network, Sentry, git tags, or hardware access.
"""

import argparse
import copy
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
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


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RELEASE_HEALTH_FLAGS = (
    "live_release_surfaces",
    "github_release_json",
    "sentry_release_health",
    "require_sentry_release_health",
    "require_release_debug_files",
)


def load_manifest():
    return json.loads((ROOT / "config/security/nightly-security-manifest.json").read_text())


def namespace(**overrides):
    values = {name: False for name in RELEASE_HEALTH_FLAGS}
    values["github_release_json"] = None
    values["automation_toml"] = None
    values.update(overrides)
    return argparse.Namespace(**values)


def check_ids(items):
    return {item["check_id"] for item in items}


class TempRootTestCase(unittest.TestCase):
    def setUp(self):
        self.manifest = load_manifest()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, relative_path, text):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            path.write_bytes(text)
        else:
            path.write_text(text)


class CommandLineTests(unittest.TestCase):
    def test_release_health_gate_flags_parse(self):
        argv = [
            "nightly-security-check.py",
            "--strict",
            "--live-release-surfaces",
            "--github-release-json", "fixture.json",
            "--sentry-release-health",
            "--require-sentry-release-health",
            "--require-release-debug-files",
            "--automation-toml", "automation.toml",
        ]
        with patch.object(sys, "argv", argv):
            args = CHECKER.parse_args()
        self.assertTrue(args.strict)
        self.assertTrue(args.live_release_surfaces)
        self.assertEqual(args.github_release_json, "fixture.json")
        self.assertTrue(args.sentry_release_health)
        self.assertTrue(args.require_sentry_release_health)
        self.assertTrue(args.require_release_debug_files)
        self.assertEqual(args.automation_toml, "automation.toml")

    def test_plain_nightly_run_is_not_a_release_health_run(self):
        with patch.object(sys, "argv", ["nightly-security-check.py"]):
            args = CHECKER.parse_args()
        self.assertFalse(args.strict)
        self.assertFalse(CHECKER.release_health_mode(args))


class ReleaseHealthGateTests(unittest.TestCase):
    def test_required_sentry_and_debug_file_failures_fail_without_strict(self):
        sentry = [{"check_id": "sentry-release-missing"}]
        dsym = [{"check_id": "release-dsym-uuid-mismatch"}]
        self.assertTrue(CHECKER.has_required_release_health_failure(namespace(require_sentry_release_health=True), sentry))
        self.assertFalse(CHECKER.has_required_release_health_failure(namespace(sentry_release_health=True), sentry))
        self.assertTrue(CHECKER.has_required_release_health_failure(namespace(require_release_debug_files=True), dsym))
        self.assertFalse(CHECKER.has_required_release_health_failure(namespace(require_sentry_release_health=True), dsym))

    def test_stale_appcast_watch_item_blocks_only_release_health_runs(self):
        watch = [{"check_id": "appcast-release-candidate"}]
        for flag in RELEASE_HEALTH_FLAGS:
            value = "fixture.json" if flag == "github_release_json" else True
            with self.subTest(flag=flag):
                self.assertTrue(CHECKER.has_blocking_release_health_watch_item(namespace(**{flag: value}), watch))
        self.assertFalse(CHECKER.has_blocking_release_health_watch_item(namespace(), watch))
        self.assertFalse(CHECKER.has_blocking_release_health_watch_item(namespace(live_release_surfaces=True), []))

    def test_release_health_runs_skip_local_automation_state_unless_given(self):
        self.assertTrue(CHECKER.should_check_automation_prompt(namespace()))
        self.assertFalse(CHECKER.should_check_automation_prompt(namespace(live_release_surfaces=True)))
        self.assertTrue(
            CHECKER.should_check_automation_prompt(namespace(live_release_surfaces=True, automation_toml="automation.toml"))
        )

    def test_live_appcast_checks_include_the_installed_apps_sparkle_feed(self):
        manifest = load_manifest()
        urls = CHECKER.live_appcast_urls(manifest)
        self.assertIn(manifest["expected_info_plist"]["SUFeedURL"], urls)
        self.assertIn(manifest["live_release_surfaces"]["appcast"], urls)
        self.assertEqual(len(urls), len(set(urls)))

    def test_live_release_asset_feed_is_skipped_until_the_legacy_feed_is_frozen(self):
        manifest = load_manifest()
        feed = manifest["expected_info_plist"]["SUFeedURL"]
        website = manifest["live_release_surfaces"]["appcast"]
        self.assertTrue(feed.endswith(CHECKER.RELEASE_ASSET_FEED_SUFFIX))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            before = CHECKER.live_appcast_urls(manifest, root)
            self.assertNotIn(feed, before)
            self.assertIn(website, before)

            record = root / "config/release/legacy-appcast-freeze.json"
            record.parent.mkdir(parents=True)
            record.write_text("{}\n", encoding="utf-8")
            after = CHECKER.live_appcast_urls(manifest, root)
            self.assertIn(feed, after)
            self.assertIn(website, after)


class ReleaseMetadataTests(TempRootTestCase):
    """Info.plist, appcast and cask fixtures in a temp root shaped like the repo."""

    def setUp(self):
        super().setUp()
        self.write_info()
        self.write_appcast()
        self.write_cask()

    def write_info(self, short="1.2.3", build="1.2.3"):
        info = dict(self.manifest["expected_info_plist"])
        info.update({
            "CFBundleShortVersionString": short,
            "CFBundleVersion": build,
            "TranscriptedSentryDSN": "https://public@example.invalid/1",
        })
        self.write(self.manifest["paths"]["info_plist"], plistlib.dumps(info))

    def write_appcast(self, short="1.2.3", build="1.2.3"):
        version = short or build
        fields = ""
        if short:
            fields += f"<sparkle:shortVersionString>{short}</sparkle:shortVersionString>"
        if build:
            fields += f"<sparkle:version>{build}</sparkle:version>"
        url = f"https://github.com/{self.manifest['repo_slug']}/releases/download/v{version}/Transcripted-{version}.dmg"
        minimum = self.manifest["expected_info_plist"]["LSMinimumSystemVersion"]
        self.write(
            self.manifest["paths"]["appcast"],
            f'<?xml version="1.0"?><rss xmlns:sparkle="{SPARKLE}"><channel><item>{fields}'
            f"<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>"
            "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
            f'<enclosure url="{url}" length="42" sparkle:edSignature="c2lnbmF0dXJl"/>'
            "</item></channel></rss>",
        )

    def write_cask(self, version="1.2.3"):
        slug = self.manifest["repo_slug"]
        self.write(
            self.manifest["paths"]["homebrew_cask"],
            'cask "transcripted" do\n'
            f'  version "{version}"\n'
            f'  sha256 "{"a" * 64}"\n'
            f'  url "https://github.com/{slug}/releases/download/v#{{version}}/Transcripted-#{{version}}.dmg"\n'
            "  livecheck do\n    url :url\n    strategy :github_latest\n  end\n"
            "end\n",
        )

    def appcast_ids(self, tags=lambda root, tag: False):
        with patch.object(CHECKER, "git_tag_exists", side_effect=tags):
            findings, watch = CHECKER.check_appcast(self.root, self.manifest)
        return check_ids(findings), check_ids(watch)

    def test_matching_release_metadata_passes(self):
        self.assertEqual(check_ids(CHECKER.check_info_plist(self.root, self.manifest)), set())
        self.assertEqual(self.appcast_ids(), (set(), set()))
        self.assertEqual(check_ids(CHECKER.check_cask(self.root, self.manifest)), set())

    def test_bundle_short_and_build_version_drift_fails(self):
        self.write_info(short="1.2.3", build="124")
        self.assertIn("info-version-build-mismatch", check_ids(CHECKER.check_info_plist(self.root, self.manifest)))

    def test_appcast_missing_either_sparkle_version_field_fails(self):
        for short, build in [("1.2.3", ""), ("", "1.2.3")]:
            with self.subTest(short=short, build=build):
                self.write_appcast(short=short, build=build)
                self.assertIn("appcast-version-field-missing", self.appcast_ids()[0])

    def test_appcast_short_and_build_version_drift_fails(self):
        self.write_appcast(short="1.2.3", build="124")
        self.assertIn("appcast-version-build-mismatch", self.appcast_ids()[0])

    def test_one_unreleased_patch_ahead_is_a_watch_item_not_a_finding(self):
        self.write_info(short="1.2.4", build="1.2.4")
        findings, watch = self.appcast_ids(tags=lambda root, tag: tag == "v1.2.3")
        self.assertNotIn("appcast-version-mismatch", findings)
        self.assertEqual(watch, {"appcast-release-candidate"})

    def test_drift_that_is_not_one_unreleased_patch_fails(self):
        cases = [
            ("1.2.5", lambda root, tag: tag == "v1.2.3"),  # two patches ahead
            ("1.2.4", lambda root, tag: True),  # candidate already tagged
            ("1.2.4", lambda root, tag: False),  # published version never tagged
        ]
        for index, (info_version, tags) in enumerate(cases):
            with self.subTest(case=index):
                self.write_info(short=info_version, build=info_version)
                findings, watch = self.appcast_ids(tags=tags)
                self.assertIn("appcast-version-mismatch", findings)
                self.assertEqual(watch, set())

    def test_cask_version_drift_from_the_appcast_fails(self):
        self.write_cask(version="1.2.2")
        self.assertIn("cask-version-mismatch", check_ids(CHECKER.check_cask(self.root, self.manifest)))


class ObservabilitySchemaTests(TempRootTestCase):
    def test_raw_payload_keys_in_policy_allowlists_or_registry_fail(self):
        paths = self.manifest["paths"]
        for source in paths["observability_policy_sources"]:
            self.write(source, '"app_launched": .init(properties: ["build_channel"])\n')
        self.write(paths["analytics_event_registry"], "# comment\napp_launched|build_channel\n")
        self.assertEqual(CHECKER.check_observability_payload_keys(self.root, self.manifest), [])

        self.write(paths["observability_policy_sources"][0], '"app_launched": .init(properties: ["transcript_text"])\n')
        self.write(paths["analytics_event_registry"], "app_launched|audio_path,build_channel\n")
        self.assertEqual(
            check_ids(CHECKER.check_observability_payload_keys(self.root, self.manifest)),
            {"raw-observability-payload-key", "raw-analytics-registry-payload-key"},
        )

    def write_posthog_sources(self, probe_first_value, digest_first_value):
        paths = self.manifest["paths"]
        events = sorted(set(self.manifest["required_posthog_first_value_events"]) | {"app_launched", "onboarding_shown"})
        self.write(paths["analytics_event_registry"], "".join(f"{event}|\n" for event in events))

        def quoted(names):
            return ",".join(f"'{name}'" for name in names)

        self.write(
            paths["health_probe"],
            f'  workflow_events="{quoted(["app_launched"])}"\n'
            f'  onboarding_events="{quoted(["onboarding_shown"])}"\n'
            f'  first_value_events="{quoted(probe_first_value)}"\n',
        )

        def python_tuple(names):
            return "".join(f'    "{name}",\n' for name in names)

        self.write(
            paths["nightly_digest"],
            f'POSTHOG_ACTIVE_EVENTS = (\n{python_tuple(["app_launched"])})\n'
            f"POSTHOG_FIRST_VALUE_EVENTS = (\n{python_tuple(digest_first_value)})\n",
        )

    def test_each_first_value_probe_source_is_checked_on_its_own(self):
        required = list(self.manifest["required_posthog_first_value_events"])
        self.write_posthog_sources(required, required)
        self.assertEqual(CHECKER.check_posthog_health_schema(self.root, self.manifest), [])

        self.write_posthog_sources(required, required[1:])
        self.assertEqual(
            check_ids(CHECKER.check_posthog_health_schema(self.root, self.manifest)),
            {"posthog-first-value-schema-nightly-digest"},
        )
        self.write_posthog_sources(required[1:], required)
        self.assertEqual(
            check_ids(CHECKER.check_posthog_health_schema(self.root, self.manifest)),
            {"posthog-first-value-schema-health-probe"},
        )

    def test_probe_events_outside_the_analytics_policy_fail(self):
        required = list(self.manifest["required_posthog_first_value_events"])
        self.write_posthog_sources(required + ["made_up_event"], required)
        self.assertIn(
            "posthog-schema-unknown-events",
            check_ids(CHECKER.check_posthog_health_schema(self.root, self.manifest)),
        )


class SentryReleaseHealthTests(TempRootTestCase):
    def setUp(self):
        super().setUp()
        info = dict(self.manifest["expected_info_plist"], CFBundleShortVersionString="1.2.3")
        self.write(self.manifest["paths"]["info_plist"], plistlib.dumps(info))

    def lookup(self, returncode, required):
        result = subprocess.CompletedProcess(args=[], returncode=returncode, stdout="", stderr="")
        # No SENTRY_AUTH_TOKEN in the environment: sentry-cli's own config may hold the auth.
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(CHECKER, "command_exists", return_value=True), \
             patch.object(CHECKER, "run", return_value=result) as run:
            findings, watch = CHECKER.check_sentry_release_health(self.root, self.manifest, True, required)
        return run, check_ids(findings), check_ids(watch)

    def test_configured_sentry_cli_auth_attempts_the_lookup_without_an_env_token(self):
        run, findings, watch = self.lookup(0, required=True)
        self.assertEqual(run.call_count, 1)
        self.assertIn("transcripted@1.2.3", run.call_args.args[0])
        self.assertEqual((findings, watch), (set(), set()))

    def test_missing_release_fails_when_required_and_warns_otherwise(self):
        self.assertEqual(self.lookup(1, required=True)[1:], ({"sentry-release-missing"}, set()))
        self.assertEqual(self.lookup(1, required=False)[1:], (set(), {"sentry-release-health-failed"}))

    def test_missing_sentry_cli_fails_only_when_required(self):
        with patch.object(CHECKER, "command_exists", return_value=False):
            required = CHECKER.check_sentry_release_health(self.root, self.manifest, False, True)
            optional = CHECKER.check_sentry_release_health(self.root, self.manifest, True, False)
        self.assertEqual(check_ids(required[0]), {"sentry-cli-missing"})
        self.assertEqual((check_ids(optional[0]), check_ids(optional[1])), (set(), {"sentry-cli-missing"}))


class CommittedEntitlementTests(TempRootTestCase):
    def write_entitlements(self, label, entitlements):
        self.write(self.manifest["paths"][f"{label}_entitlements"], plistlib.dumps(entitlements))

    def test_committed_entitlement_plists_reject_forbidden_broad_permissions(self):
        for label in ("local", "beta"):
            self.write_entitlements(label, self.manifest["expected_entitlements"][label])
        self.assertEqual(CHECKER.check_entitlements(self.root, self.manifest), [])

        for forbidden in self.manifest["forbidden_entitlements"]:
            with self.subTest(forbidden=forbidden):
                broadened = dict(self.manifest["expected_entitlements"]["beta"], **{forbidden: True})
                self.write_entitlements("beta", broadened)
                self.assertIn("beta-forbidden-entitlements", check_ids(CHECKER.check_entitlements(self.root, self.manifest)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
