#!/usr/bin/env python3
"""Offline behavior tests for the nightly security checker.

They call the checker's functions on synthetic fixtures in a temp directory:
no signing, keychain, network, Sentry, git tags, or hardware access.
"""

import argparse
import copy
import hashlib
import io
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
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
            "--root", "/owned/fixture",
            "--appcast", "active.xml",
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
        self.assertEqual(args.root, Path("/owned/fixture"))
        self.assertEqual(args.appcast, "active.xml")
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


class FrozenFeedTests(TempRootTestCase):
    write_info = ReleaseMetadataTests.write_info
    write_appcast = ReleaseMetadataTests.write_appcast
    write_cask = ReleaseMetadataTests.write_cask

    def setUp(self):
        super().setUp()
        network = patch.object(CHECKER, "curl_stdout", side_effect=AssertionError("offline fixture test cannot contact the network"))
        network.start()
        self.addCleanup(network.stop)
        self.write_info("1.1.76", "1.1.76")
        self.write_appcast("1.1.75", "1.1.75")
        legacy = self.root / self.manifest["paths"]["appcast"]
        self.write("config/release/legacy-appcast-freeze.json", json.dumps({
            "frozen_version": "1.1.75",
            "legacy_appcast": self.manifest["paths"]["appcast"],
            "legacy_appcast_sha256": hashlib.sha256(legacy.read_bytes()).hexdigest(),
            "new_feed_url": self.manifest["expected_info_plist"]["SUFeedURL"],
        }))
        self.write_appcast("1.1.76", "1.1.76")
        self.active = legacy.read_text()
        self.write_appcast("1.1.75", "1.1.75")
        self.write("active.xml", self.active)
        self.manifest["_active_appcast_xml"] = self.active
        self.write_cask("1.1.76")
        self.write("release.json", json.dumps({
            "tagName": "v1.1.76", "isDraft": False, "isPrerelease": False,
            "assets": [{"name": "Transcripted-1.1.76.dmg", "size": 42,
                        "url": "https://github.com/r3dbars/transcripted/releases/download/v1.1.76/Transcripted-1.1.76.dmg",
                        "digest": "sha256:" + "a" * 64}],
        }))

    def checks(self):
        with patch.object(CHECKER, "git_tag_exists", return_value=True):
            findings, watch = CHECKER.check_appcast(self.root, self.manifest)
        findings += CHECKER.check_cask(self.root, self.manifest)
        findings += CHECKER.check_github_release_metadata(self.root, self.manifest, False, "release.json")
        return check_ids(findings), check_ids(watch)

    def test_active_76_and_frozen_75_validate_current_metadata(self):
        self.assertEqual(self.checks(), (set(), set()))

    def test_stale_active_75_cannot_validate_published_76(self):
        self.manifest["_active_appcast_xml"] = (self.root / "docs/appcast.xml").read_text()
        findings, _ = self.checks()
        self.assertTrue({"appcast-version-mismatch", "cask-version-mismatch", "github-release-tag"} <= findings)

    def test_legacy_byte_mutation_fails_even_with_good_active_metadata(self):
        path = self.root / "docs/appcast.xml"
        path.write_text(path.read_text() + "\n")
        self.assertIn("legacy-appcast-freeze", self.checks()[0])

    def test_malformed_freeze_and_wrong_version_or_feed_fail(self):
        path = self.root / "config/release/legacy-appcast-freeze.json"
        original = path.read_text()
        for field, value in [("frozen_version", "1.1.74"), ("frozen_version", 75), ("new_feed_url", "https://invalid.example/feed")]:
            record = json.loads(original)
            record[field] = value
            path.write_text(json.dumps(record))
            with self.subTest(field=field):
                self.assertIn("legacy-appcast-freeze", self.checks()[0])
        path.write_text("{invalid")
        self.assertIn("legacy-appcast-freeze", self.checks()[0])

    def test_cask_and_github_digest_drift_still_fail(self):
        cask = self.root / "Casks/transcripted.rb"
        original = cask.read_text()
        cask.write_text(original.replace("a" * 64, "b" * 64))
        self.assertIn("github-release-asset-digest", self.checks()[0])
        cask.write_text(original)
        release = self.root / "release.json"
        release.write_text(release.read_text().replace("a" * 64, "b" * 64))
        self.assertIn("github-release-asset-digest", self.checks()[0])

    def test_prepublication_76_remains_a_blocking_candidate_watch(self):
        self.manifest["_active_appcast_xml"] = (self.root / "docs/appcast.xml").read_text()
        self.write_cask("1.1.75")
        with patch.object(CHECKER, "git_tag_exists", side_effect=lambda root, tag: tag == "v1.1.75"):
            findings, watch = CHECKER.check_appcast(self.root, self.manifest)
        self.assertEqual(findings, [])
        self.assertEqual(check_ids(watch), {"appcast-release-candidate"})
        self.assertTrue(CHECKER.has_blocking_release_health_watch_item(namespace(github_release_json="release.json"), watch))

    def test_frozen_root_requires_explicit_active_input_without_network(self):
        self.manifest.pop("_active_appcast_xml")
        with patch.object(CHECKER, "curl_stdout", side_effect=AssertionError("offline means no network")):
            findings = CHECKER.select_active_appcast(self.root, self.manifest, namespace(appcast=None))
        self.assertEqual(check_ids(findings), {"active-appcast-required"})

    def test_explicit_active_file_is_selected_and_malformed_input_never_falls_back(self):
        self.manifest.pop("_active_appcast_xml")
        with patch.object(CHECKER, "curl_stdout", side_effect=AssertionError("offline means no network")):
            self.assertEqual(CHECKER.select_active_appcast(self.root, self.manifest, namespace(appcast="active.xml")), [])
            self.assertEqual(self.checks(), (set(), set()))
            self.write("active.xml", "<invalid")
            findings = CHECKER.select_active_appcast(self.root, self.manifest, namespace(appcast="active.xml"))
        self.assertEqual(check_ids(findings), {"active-appcast-unavailable"})
        self.assertNotIn("_active_appcast_xml", self.manifest)

    def test_live_mode_uses_existing_installed_feed_caller(self):
        self.manifest.pop("_active_appcast_xml")
        result = subprocess.CompletedProcess([], 0, self.active, "")
        with patch.object(CHECKER, "curl_stdout", return_value=result) as fetch:
            self.assertEqual(CHECKER.select_active_appcast(self.root, self.manifest, namespace(appcast=None, live_release_surfaces=True)), [])
        self.assertEqual(fetch.call_args.args, (self.root, ["-fsSL", self.manifest["expected_info_plist"]["SUFeedURL"]]))
        self.assertEqual(self.checks(), (set(), set()))

    def test_live_fetch_failure_does_not_reuse_an_old_selected_snapshot(self):
        result = subprocess.CompletedProcess([], 22, "", "failure")
        with patch.object(CHECKER, "curl_stdout", return_value=result):
            findings = CHECKER.select_active_appcast(self.root, self.manifest, namespace(appcast=None, live_release_surfaces=True))
        self.assertEqual(check_ids(findings), {"active-appcast-unavailable"})
        self.assertNotIn("_active_appcast_xml", self.manifest)

    def test_rewriting_feed_and_record_together_still_fails_existing_history_guard(self):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        def git(*args):
            subprocess.run(["git", "-c", "core.hooksPath=" + os.devnull,
                            "-c", "commit.gpgsign=false", "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@example.invalid", *args],
                           cwd=self.root, env=env, capture_output=True, check=True)
        git("init", "--quiet")
        git("add", "docs/appcast.xml", "config/release/legacy-appcast-freeze.json")
        git("commit", "--quiet", "-m", "Initial owned freeze")
        git("update-ref", "refs/remotes/origin/main", "HEAD")
        with patch.dict(os.environ, env, clear=True):
            self.assertEqual(self.checks(), (set(), set()))
            path = self.root / "docs/appcast.xml"
            path.write_text(path.read_text() + "\n")
            record_path = self.root / "config/release/legacy-appcast-freeze.json"
            record = json.loads(record_path.read_text())
            record["legacy_appcast_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            record_path.write_text(json.dumps(record))
            git("add", "docs/appcast.xml", "config/release/legacy-appcast-freeze.json")
            git("commit", "--quiet", "-m", "Forbidden owned rewrite")
            self.assertIn("legacy-appcast-history", self.checks()[0])

    def test_deleted_local_record_still_fails_origin_freeze_guard(self):
        env = fixture_git_environment()
        with patch.dict(os.environ, env, clear=True):
            fixture_git(self.root, "init", "--quiet")
            fixture_git(self.root, "add", "docs/appcast.xml", "config/release/legacy-appcast-freeze.json")
            fixture_git(self.root, "commit", "--quiet", "-m", "Initial owned freeze")
            fixture_git(self.root, "update-ref", "refs/remotes/origin/main", "HEAD")
            (self.root / "config/release/legacy-appcast-freeze.json").unlink()
            self.assertIn("legacy-appcast-history", self.checks()[0])

    def write_pair(self, version="1.1.76", payload=None):
        raw = (payload if payload is not None else self.active).encode("utf-8")
        snapshot = f"release-health-appcast-{version}.xml"
        fixture = f"release-health-github-release-{version}.json"
        self.write(snapshot, raw)
        self.write(fixture, json.dumps({
            "tagName": "v" + version, "isDraft": False, "isPrerelease": False,
            "assets": [
                {"name": f"Transcripted-{version}.dmg", "size": 42, "digest": "sha256:" + "a" * 64,
                 "url": f"https://github.com/r3dbars/transcripted/releases/download/v{version}/Transcripted-{version}.dmg"},
                {"name": "appcast.xml", "size": len(raw), "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
                 "url": f"https://github.com/r3dbars/transcripted/releases/download/v{version}/appcast.xml"},
            ],
        }))
        return namespace(appcast=None, github_release_json=fixture), self.root / fixture, self.root / snapshot

    def test_explicit_versioned_fixture_selects_its_integrity_bound_active_companion(self):
        args, _, snapshot = self.write_pair()
        with patch.object(CHECKER, "curl_stdout", side_effect=AssertionError("offline means no network")):
            self.assertEqual(CHECKER.select_active_appcast(self.root, self.manifest, args), [])
        self.assertEqual(self.manifest["_active_appcast_source"], snapshot.name)
        self.assertEqual(self.manifest["_active_appcast_fixture"], args.github_release_json)
        self.assertEqual(self.checks(), (set(), set()))

    def test_companion_missing_or_changed_bytes_cannot_fall_back_to_legacy(self):
        for mutation in ["missing", "bytes"]:
            args, _, snapshot = self.write_pair()
            if mutation == "missing":
                snapshot.unlink()
            else:
                snapshot.write_bytes(snapshot.read_bytes() + b"\n")
            with self.subTest(mutation=mutation), patch.object(CHECKER, "curl_stdout", side_effect=AssertionError("no network")):
                findings = CHECKER.select_active_appcast(self.root, self.manifest, args)
            self.assertEqual(check_ids(findings), {"active-appcast-pair-invalid"})
            self.assertNotIn("_active_appcast_xml", self.manifest)

    def test_companion_tag_asset_identity_size_and_digest_must_all_agree(self):
        for mutation in ["tag", "url", "size", "bool-size", "digest", "duplicate"]:
            args, fixture, _ = self.write_pair()
            value = json.loads(fixture.read_text())
            asset = value["assets"][1]
            if mutation == "tag":
                value["tagName"] = "v1.1.75"
            elif mutation == "url":
                asset["url"] = asset["url"].replace("v1.1.76", "v1.1.75")
            elif mutation == "size":
                asset["size"] += 1
            elif mutation == "bool-size":
                asset["size"] = True
            elif mutation == "digest":
                asset["digest"] = "sha256:" + "b" * 64
            else:
                value["assets"].append(dict(asset))
            fixture.write_text(json.dumps(value))
            with self.subTest(mutation=mutation):
                self.assertEqual(check_ids(CHECKER.select_active_appcast(self.root, self.manifest, args)), {"active-appcast-pair-invalid"})

    def test_integrity_matching_stale_feed_top_still_fails_pair_identity(self):
        stale = (self.root / "docs/appcast.xml").read_text()
        args, _, _ = self.write_pair(payload=stale)
        self.assertEqual(check_ids(CHECKER.select_active_appcast(self.root, self.manifest, args)), {"active-appcast-pair-invalid"})

    def test_paired_published_75_keeps_prepared_76_strict_watch_and_checksums(self):
        args, fixture, _ = self.write_pair("1.1.75", (self.root / "docs/appcast.xml").read_text())
        self.write_cask("1.1.75")
        self.assertEqual(CHECKER.select_active_appcast(self.root, self.manifest, args), [])
        with patch.object(CHECKER, "git_tag_exists", side_effect=lambda root, tag: tag == "v1.1.75"):
            findings, watch = CHECKER.check_appcast(self.root, self.manifest)
        findings += CHECKER.check_cask(self.root, self.manifest)
        findings += CHECKER.check_github_release_metadata(self.root, self.manifest, False, str(fixture))
        self.assertEqual(findings, [])
        self.assertEqual(check_ids(watch), {"appcast-release-candidate"})
        self.assertTrue(CHECKER.has_blocking_release_health_watch_item(args, watch))
        value = json.loads(fixture.read_text())
        value["assets"][0]["digest"] = "sha256:" + "b" * 64
        fixture.write_text(json.dumps(value))
        self.assertEqual(check_ids(CHECKER.check_github_release_metadata(self.root, self.manifest, False, str(fixture))), {"github-release-asset-digest"})

    def test_explicit_snapshot_and_live_mode_keep_precedence_over_companion(self):
        args, fixture, _ = self.write_pair()
        fixture.write_text("{invalid")
        args.appcast = "active.xml"
        self.assertEqual(CHECKER.select_active_appcast(self.root, self.manifest, args), [])
        self.assertEqual(self.manifest["_active_appcast_source"], "active.xml")
        args.appcast = None
        args.live_release_surfaces = True
        result = subprocess.CompletedProcess([], 0, self.active, "")
        with patch.object(CHECKER, "curl_stdout", return_value=result) as fetch:
            self.assertEqual(CHECKER.select_active_appcast(self.root, self.manifest, args), [])
            fetch.assert_called_once()

    def test_paired_snapshot_uses_the_same_bytes_once_for_validation_and_selection(self):
        args, _, snapshot = self.write_pair()
        original = Path.read_bytes
        reads = []
        def read(path):
            if path == snapshot:
                reads.append(path)
                if len(reads) > 1:
                    return b"<changed-after-validation>"
            return original(path)
        with patch.object(Path, "read_bytes", autospec=True, side_effect=read):
            self.assertEqual(CHECKER.select_active_appcast(self.root, self.manifest, args), [])
        self.assertEqual(len(reads), 1)
        self.assertEqual(self.manifest["_active_appcast_xml"], self.active)


def fixture_git_environment():
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
    return env


def fixture_git(root, *args):
    subprocess.run(["git", "-c", "core.hooksPath=" + os.devnull,
                    "-c", "commit.gpgsign=false", "-c", "user.name=Fixture",
                    "-c", "user.email=fixture@example.invalid", *args],
                   cwd=root, env=fixture_git_environment(), capture_output=True, check=True)


class ExplicitRootAdmissionTests(TempRootTestCase):
    def test_nested_non_git_root_cannot_discover_parent_even_with_poisoned_git_environment(self):
        fixture_git(self.root, "init", "--quiet")
        child = self.root / "child"
        child.mkdir()
        poison = dict(fixture_git_environment(), GIT_DIR=str(self.root / ".git"),
                      GIT_WORK_TREE=str(self.root), GIT_INDEX_FILE=str(self.root / "foreign-index"),
                      GIT_CONFIG_COUNT="malformed")
        for env in [fixture_git_environment(), poison]:
            with self.subTest(poisoned="GIT_DIR" in env), patch.dict(os.environ, env, clear=True), \
                    patch.object(sys, "argv", ["nightly-security-check.py", "--root", str(child)]), \
                    patch.object(CHECKER, "load_manifest", side_effect=AssertionError("unadmitted root reached input loading")) as load, \
                    patch.object(CHECKER, "scan_tracked_files") as tracked, \
                    patch.object(CHECKER, "scan_recent_history") as history:
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    self.assertEqual(CHECKER.main(), 2)
                self.assertIn("--root must name the exact Git checkout root", stderr.getvalue())
                load.assert_not_called()
                tracked.assert_not_called()
                history.assert_not_called()

    def test_exact_owned_checkout_is_admitted_despite_foreign_git_environment(self):
        fixture_git(self.root, "init", "--quiet")
        child = self.root / "child"
        child.mkdir()
        fixture_git(child, "init", "--quiet")
        poison = dict(fixture_git_environment(), GIT_DIR=str(self.root / ".git"),
                      GIT_WORK_TREE=str(self.root), GIT_INDEX_FILE=str(self.root / "foreign-index"),
                      GIT_CONFIG_COUNT="malformed")
        with patch.dict(os.environ, poison, clear=True), \
                patch.object(sys, "argv", ["nightly-security-check.py", "--root", str(child)]), \
                patch.object(CHECKER, "load_manifest", side_effect=RuntimeError("owned checkout admitted")):
            with self.assertRaisesRegex(RuntimeError, "owned checkout admitted"):
                CHECKER.main()


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
