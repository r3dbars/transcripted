#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone
from fnmatch import fnmatch
from pathlib import Path


SECRET_PATTERNS = [
    {
        "id": "private-key-material",
        "severity": "high",
        "pattern": re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", re.IGNORECASE),
        "summary": "Private key material looks committed.",
    },
    {
        "id": "github-token",
        "severity": "high",
        "pattern": re.compile(r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
        "summary": "GitHub token-like value looks committed.",
    },
    {
        "id": "openai-key",
        "severity": "high",
        "pattern": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
        "summary": "OpenAI-style API key looks committed.",
    },
    {
        "id": "aws-key",
        "severity": "high",
        "pattern": re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
        "summary": "AWS access key ID looks committed.",
    },
    {
        "id": "slack-token",
        "severity": "high",
        "pattern": re.compile(r"\bxox(?:b|p|a|r|s|x)-[A-Za-z0-9-]{10,}\b"),
        "summary": "Slack token-like value looks committed.",
    },
]

SHELL_GUARD_PATTERNS = [
    {
        "id": "curl-pipe-shell",
        "severity": "medium",
        "pattern": re.compile(r"curl\b[^\\\n|]*\|\s*(?:bash|sh)\b"),
        "summary": "Shell script pipes curl directly into a shell.",
    },
    {
        "id": "chmod-777",
        "severity": "medium",
        "pattern": re.compile(r"\bchmod\s+777\b"),
        "summary": "Shell script uses chmod 777.",
    },
    {
        "id": "set-x",
        "severity": "low",
        "pattern": re.compile(r"^\s*set\s+-[^\n]*x", re.MULTILINE),
        "summary": "Shell script enables command echoing, which can leak secrets.",
    },
]

SEVERITY_ORDER = {"none": 0, "low": 1, "medium": 2, "high": 3}
REQUIRED_SENTRY_RELEASE_CHECK_IDS = {
    "sentry-auth-missing",
    "sentry-cli-missing",
    "sentry-release-missing",
}
REQUIRED_RELEASE_DEBUG_CHECK_IDS = {
    "release-binary-missing",
    "release-dsym-missing",
    "dwarfdump-missing",
    "release-dsym-uuid-mismatch",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Deterministic nightly security checks for Transcripted.")
    parser.add_argument(
        "--manifest",
        default="config/security/nightly-security-manifest.json",
        help="Repo-relative path to the nightly security manifest.",
    )
    parser.add_argument(
        "--write-report",
        help="Optional path for a JSON report.",
    )
    parser.add_argument(
        "--app-bundle",
        help="Optional built app bundle path to validate, e.g. build/Transcripted.app.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero when deterministic findings are present.",
    )
    parser.add_argument(
        "--live-release-surfaces",
        action="store_true",
        help="Check transcripted.app live appcast and download routes against the committed appcast.",
    )
    parser.add_argument(
        "--sentry-release-health",
        action="store_true",
        help="Use configured Sentry auth to verify the release matching Info.plist exists.",
    )
    parser.add_argument(
        "--require-sentry-release-health",
        action="store_true",
        help="Fail if Sentry auth, sentry-cli, or the release matching Info.plist is missing.",
    )
    parser.add_argument(
        "--require-release-debug-files",
        action="store_true",
        help="Fail unless the configured release app binary and dSYM exist and have matching UUIDs.",
    )
    parser.add_argument(
        "--automation-toml",
        help="Optional explicit automation.toml path. Defaults to the local Codex automation file when present.",
    )
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def normalize_path(path: str | Path) -> str:
    return str(path).replace("\\", "/")


def should_skip(path: str, patterns: list[str]) -> bool:
    normalized = normalize_path(path)
    return any(fnmatch(normalized, pattern) for pattern in patterns)


def load_manifest(root: Path, relative_path: str) -> dict:
    manifest_path = root / relative_path
    with manifest_path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    manifest["_path"] = normalize_path(relative_path)
    return manifest


def make_finding(
    category: str,
    severity: str,
    check_id: str,
    summary: str,
    detail: str,
    path: str | None = None,
) -> dict:
    finding = {
        "category": category,
        "severity": severity,
        "check_id": check_id,
        "summary": summary,
        "detail": detail,
    }
    if path:
        finding["path"] = normalize_path(path)
    return finding


def make_watch_item(check_id: str, summary: str, detail: str, path: str | None = None) -> dict:
    item = {
        "check_id": check_id,
        "summary": summary,
        "detail": detail,
    }
    if path:
        item["path"] = normalize_path(path)
    return item


def parse_release_version(value: str) -> tuple[int, int, int] | None:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", value.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def is_next_patch_version(candidate: str, published: str) -> bool:
    candidate_version = parse_release_version(candidate)
    published_version = parse_release_version(published)
    if candidate_version is None or published_version is None:
        return False
    return candidate_version[:2] == published_version[:2] and candidate_version[2] == published_version[2] + 1


def git_tag_exists(root: Path, tag_name: str) -> bool:
    result = run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag_name}"], cwd=root)
    return result.returncode == 0


def scan_tracked_files(root: Path, manifest: dict) -> list[dict]:
    allowlist = manifest["secret_scan"]["tracked_file_allowlist_globs"]
    result = run(["git", "ls-files", "-z"], cwd=root)
    if result.returncode != 0:
        return [
            make_finding(
                "secret_scan",
                "medium",
                "git-ls-files-failed",
                "Could not enumerate tracked files for secret scanning.",
                result.stderr.strip() or result.stdout.strip() or "git ls-files failed",
            )
        ]

    findings: list[dict] = []
    for raw_path in result.stdout.split("\0"):
        if not raw_path:
            continue
        if should_skip(raw_path, allowlist):
            continue

        file_path = root / raw_path
        if not file_path.is_file():
            continue

        try:
            text = file_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue

        for pattern in SECRET_PATTERNS:
            match = pattern["pattern"].search(text)
            if not match:
                continue

            line_number = text[: match.start()].count("\n") + 1
            findings.append(
                make_finding(
                    "secret_scan",
                    pattern["severity"],
                    f"tracked-{pattern['id']}",
                    pattern["summary"],
                    f"Matched line {line_number} in {raw_path}.",
                    raw_path,
                )
            )
    return findings


def scan_recent_history(root: Path, manifest: dict) -> list[dict]:
    allowlist = manifest["secret_scan"]["history_file_allowlist_globs"]
    commit_window = str(manifest["secret_scan"]["history_commit_window"])
    result = run(["git", "log", f"--max-count={commit_window}", "--format=%H", "-p", "--unified=0", "--"], cwd=root)
    if result.returncode != 0:
        return [
            make_finding(
                "secret_scan",
                "medium",
                "git-log-failed",
                "Could not scan recent commit history for secret-like additions.",
                result.stderr.strip() or result.stdout.strip() or "git log failed",
            )
        ]

    findings: list[dict] = []
    current_path = ""
    for line in result.stdout.splitlines():
        if line.startswith("+++ b/"):
            current_path = line[6:]
            continue
        if line.startswith("+++ /dev/null"):
            current_path = ""
            continue
        if not current_path or should_skip(current_path, allowlist):
            continue
        if not line.startswith("+") or line.startswith("+++"):
            continue

        added_line = line[1:]
        for pattern in SECRET_PATTERNS:
            if pattern["pattern"].search(added_line):
                findings.append(
                    make_finding(
                        "secret_scan",
                        pattern["severity"],
                        f"history-{pattern['id']}",
                        f"Recent commit history added content matching {pattern['summary'].lower()}",
                        f"Added line in {current_path}: {added_line[:160]}",
                        current_path,
                    )
                )
    return findings


def scan_shell_scripts(root: Path) -> list[dict]:
    findings: list[dict] = []
    for script_path in sorted((root / "scripts").rglob("*.sh")):
        text = read_text(script_path)
        relative = normalize_path(script_path.relative_to(root))
        for pattern in SHELL_GUARD_PATTERNS:
            if pattern["pattern"].search(text):
                findings.append(
                    make_finding(
                        "automation_guardrails",
                        pattern["severity"],
                        f"shell-{pattern['id']}",
                        pattern["summary"],
                        f"Matched in {relative}.",
                        relative,
                    )
                )
    return findings


def check_info_plist(root: Path, manifest: dict) -> list[dict]:
    info_path = root / manifest["paths"]["info_plist"]
    with info_path.open("rb") as handle:
        plist = plistlib.load(handle)

    findings: list[dict] = []
    for key, expected in manifest["expected_info_plist"].items():
        actual = plist.get(key)
        if actual != expected:
            findings.append(
                make_finding(
                    "release_integrity",
                    "high",
                    f"info-{key}",
                    f"Info.plist {key} drifted from the nightly manifest.",
                    f"Expected {expected!r}, got {actual!r}.",
                    manifest["paths"]["info_plist"],
                )
            )

    dsn = str(plist.get("TranscriptedSentryDSN", "")).strip()
    if not dsn.startswith("https://"):
        findings.append(
            make_finding(
                "observability_privacy",
                "high",
                "info-sentry-dsn",
                "TranscriptedSentryDSN must stay on HTTPS.",
                f"Got {dsn!r}.",
                manifest["paths"]["info_plist"],
            )
        )

    return findings


def check_appcast(root: Path, manifest: dict) -> tuple[list[dict], list[dict]]:
    appcast_path = root / manifest["paths"]["appcast"]
    info_path = root / manifest["paths"]["info_plist"]
    with info_path.open("rb") as handle:
        plist = plistlib.load(handle)

    namespaces = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    tree = ET.parse(appcast_path)
    channel = tree.getroot().find("channel")
    findings: list[dict] = []
    watch_items: list[dict] = []
    if channel is None:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "appcast-missing-channel",
                "Appcast is missing its RSS channel.",
                "docs/appcast.xml should have a channel with at least one item.",
                manifest["paths"]["appcast"],
            )
        )
        return findings, watch_items

    latest = channel.find("item")
    if latest is None:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "appcast-missing-item",
                "Appcast is missing its latest item.",
                "docs/appcast.xml should have at least one release item.",
                manifest["paths"]["appcast"],
            )
        )
        return findings, watch_items

    version = (
        latest.findtext("sparkle:shortVersionString", namespaces=namespaces)
        or latest.findtext("sparkle:version", namespaces=namespaces)
        or ""
    ).strip()
    info_version = str(plist.get("CFBundleShortVersionString", "")).strip()
    if version != info_version:
        unreleased_candidate = (
            is_next_patch_version(info_version, version)
            and git_tag_exists(root, f"v{version}")
            and not git_tag_exists(root, f"v{info_version}")
        )
        if unreleased_candidate:
            watch_items.append(
                make_watch_item(
                    "appcast-release-candidate",
                    "Info.plist is one unreleased patch version ahead of the appcast.",
                    f"Appcast remains on published version {version!r}; Info.plist is prepared for {info_version!r}.",
                    manifest["paths"]["appcast"],
                )
            )
        else:
            findings.append(
                make_finding(
                    "release_integrity",
                    "medium",
                    "appcast-version-mismatch",
                    "Latest appcast version drifted from Info.plist.",
                    f"Appcast has {version!r}, Info.plist has {info_version!r}.",
                    manifest["paths"]["appcast"],
                )
            )

    minimum_version = (latest.findtext("sparkle:minimumSystemVersion", namespaces=namespaces) or "").strip()
    if minimum_version != str(plist.get("LSMinimumSystemVersion", "")).strip():
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "appcast-minimum-system-version",
                "Latest appcast minimum macOS version drifted from Info.plist.",
                f"Appcast has {minimum_version!r}, Info.plist has {plist.get('LSMinimumSystemVersion')!r}.",
                manifest["paths"]["appcast"],
            )
        )

    hardware = (latest.findtext("sparkle:hardwareRequirements", namespaces=namespaces) or "").strip()
    if hardware != "arm64":
        findings.append(
            make_finding(
                "release_integrity",
                "medium",
                "appcast-hardware-requirements",
                "Latest appcast hardware requirement should stay arm64.",
                f"Got {hardware!r}.",
                manifest["paths"]["appcast"],
            )
        )

    enclosure = latest.find("enclosure")
    if enclosure is None:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "appcast-missing-enclosure",
                "Latest appcast item is missing its enclosure.",
                "Sparkle cannot download an update without an enclosure.",
                manifest["paths"]["appcast"],
            )
        )
        return findings, watch_items

    expected_url = f"https://github.com/{manifest['repo_slug']}/releases/download/v{version}/Transcripted-{version}.dmg"
    actual_url = enclosure.attrib.get("url", "")
    if actual_url != expected_url:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "appcast-enclosure-url",
                "Latest appcast enclosure URL drifted from the GitHub release asset shape.",
                f"Expected {expected_url!r}, got {actual_url!r}.",
                manifest["paths"]["appcast"],
            )
        )

    signature = enclosure.attrib.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", "")
    if not signature:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "appcast-signature",
                "Latest appcast item is missing a Sparkle signature.",
                "sparkle:edSignature should be present on the enclosure.",
                manifest["paths"]["appcast"],
            )
        )

    length = enclosure.attrib.get("length", "")
    if not length.isdigit() or int(length) <= 0:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "appcast-length",
                "Latest appcast item has an invalid enclosure length.",
                f"Got {length!r}.",
                manifest["paths"]["appcast"],
            )
        )

    return findings, watch_items


def latest_appcast_metadata(root: Path, manifest: dict) -> dict[str, str] | None:
    appcast_path = root / manifest["paths"]["appcast"]
    namespaces = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    latest = ET.parse(appcast_path).getroot().find("./channel/item")
    if latest is None:
        return None

    enclosure = latest.find("enclosure")
    return {
        "version": (
            latest.findtext("sparkle:shortVersionString", namespaces=namespaces)
            or latest.findtext("sparkle:version", namespaces=namespaces)
            or ""
        ).strip(),
        "build": (latest.findtext("sparkle:version", namespaces=namespaces) or "").strip(),
        "minimum_system_version": (
            latest.findtext("sparkle:minimumSystemVersion", namespaces=namespaces) or ""
        ).strip(),
        "hardware_requirements": (
            latest.findtext("sparkle:hardwareRequirements", namespaces=namespaces) or ""
        ).strip(),
        "url": enclosure.attrib.get("url", "") if enclosure is not None else "",
        "length": enclosure.attrib.get("length", "") if enclosure is not None else "",
        "signature": (
            enclosure.attrib.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", "")
            if enclosure is not None
            else ""
        ),
    }


def check_cask(root: Path, manifest: dict) -> list[dict]:
    cask_path = root / manifest["paths"]["homebrew_cask"]
    text = read_text(cask_path)
    latest = latest_appcast_metadata(root, manifest)
    findings: list[dict] = []

    version_match = re.search(r'(?m)^\s*version\s+"([^"]+)"', text)
    sha_match = re.search(r'(?m)^\s*sha256\s+"([^"]+)"', text)
    if not version_match:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "cask-version-missing",
                "Homebrew cask is missing a version line.",
                "Casks/transcripted.rb should pin the published Transcripted version.",
                manifest["paths"]["homebrew_cask"],
            )
        )
    elif latest and version_match.group(1) != latest["version"]:
        findings.append(
            make_finding(
                "release_integrity",
                "medium",
                "cask-version-mismatch",
                "Homebrew cask version drifted from the latest appcast release.",
                f"Cask has {version_match.group(1)!r}, appcast has {latest['version']!r}.",
                manifest["paths"]["homebrew_cask"],
            )
        )

    if not sha_match or not re.fullmatch(r"[0-9a-f]{64}", sha_match.group(1)):
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "cask-sha256-invalid",
                "Homebrew cask sha256 is missing or invalid.",
                "Casks/transcripted.rb should carry the 64-character sha256 of the published DMG.",
                manifest["paths"]["homebrew_cask"],
            )
        )

    expected_template = (
        f'https://github.com/{manifest["repo_slug"]}/releases/download/'
        'v#{version}/Transcripted-#{version}.dmg'
    )
    if expected_template not in text:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "cask-url-template",
                "Homebrew cask URL drifted from the GitHub release asset template.",
                f"Expected template {expected_template!r}.",
                manifest["paths"]["homebrew_cask"],
            )
        )

    if "strategy :github_latest" not in text:
        findings.append(
            make_finding(
                "release_integrity",
                "medium",
                "cask-livecheck",
                "Homebrew cask livecheck should track the latest GitHub release.",
                "Expected livecheck strategy :github_latest.",
                manifest["paths"]["homebrew_cask"],
            )
        )

    return findings


def quoted_strings(text: str) -> set[str]:
    return set(re.findall(r'"([A-Za-z0-9_]+)"', text))


def check_observability_payload_keys(root: Path, manifest: dict) -> list[dict]:
    findings: list[dict] = []
    disallowed = set(manifest["disallowed_observability_payload_keys"])
    for relative_path in manifest["paths"]["observability_policy_sources"]:
        text = read_text(root / relative_path)
        bad_keys = sorted(quoted_strings(text).intersection(disallowed))
        if bad_keys:
            findings.append(
                make_finding(
                    "observability_privacy",
                    "high",
                    "raw-observability-payload-key",
                    "Observability policy allowlists include raw/private payload keys.",
                    f"Disallowed key(s): {', '.join(bad_keys)}.",
                    relative_path,
                )
            )
    return findings


def source_analytics_policy_events(root: Path, manifest: dict) -> set[str]:
    text = read_text(root / manifest["paths"]["analytics_event_policy"])
    return set(re.findall(r'(?m)^\s*"([a-z0-9_]+)":\s*\.init\(', text))


def shell_event_variable(text: str, variable_name: str) -> set[str]:
    match = re.search(rf'{re.escape(variable_name)}="([^"]+)"', text)
    if not match:
        return set()
    return set(re.findall(r"'([^']+)'", match.group(1)))


def python_tuple_events(text: str, variable_name: str) -> set[str]:
    match = re.search(rf'{re.escape(variable_name)}\s*=\s*\((.*?)\)', text, re.DOTALL)
    if not match:
        return set()
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def check_posthog_health_schema(root: Path, manifest: dict) -> list[dict]:
    findings: list[dict] = []
    policy_events = source_analytics_policy_events(root, manifest)
    health_text = read_text(root / manifest["paths"]["health_probe"])
    digest_text = read_text(root / manifest["paths"]["nightly_digest"])

    health_events: set[str] = set()
    for variable_name in manifest["posthog_health_probe_event_variables"]:
        parsed = shell_event_variable(health_text, variable_name)
        if not parsed:
            findings.append(
                make_finding(
                    "automation_guardrails",
                    "medium",
                    f"posthog-health-schema-{variable_name}",
                    "PostHog health probe event schema could not be parsed.",
                    f"Expected shell variable {variable_name}.",
                    manifest["paths"]["health_probe"],
                )
            )
        health_events.update(parsed)

    digest_events = python_tuple_events(digest_text, "POSTHOG_ACTIVE_EVENTS").union(
        python_tuple_events(digest_text, "POSTHOG_FIRST_VALUE_EVENTS")
    )
    unknown = sorted((health_events | digest_events) - policy_events)
    if unknown:
        findings.append(
            make_finding(
                "observability_privacy",
                "medium",
                "posthog-schema-unknown-events",
                "Operational PostHog probes reference events outside AnalyticsEventPolicy.",
                f"Unknown event(s): {', '.join(unknown)}.",
                manifest["paths"]["health_probe"],
            )
        )

    first_value = shell_event_variable(health_text, "first_value_events").union(
        python_tuple_events(digest_text, "POSTHOG_FIRST_VALUE_EVENTS")
    )
    required_first_value = set(manifest["required_posthog_first_value_events"])
    missing_first_value = sorted(required_first_value - first_value)
    if missing_first_value:
        findings.append(
            make_finding(
                "observability_privacy",
                "medium",
                "posthog-first-value-schema",
                "PostHog release-health probes are missing first-value activation events.",
                f"Missing event(s): {', '.join(missing_first_value)}.",
                manifest["paths"]["health_probe"],
            )
        )

    return findings


def curl_stdout(root: Path, command: list[str]) -> subprocess.CompletedProcess[str]:
    return run(["curl", "--max-time", "15", "--retry", "2", *command], cwd=root)


def first_header_value(headers: str, name: str) -> str:
    pattern = re.compile(rf"^{re.escape(name)}:\s*(.+)$", re.IGNORECASE | re.MULTILINE)
    match = pattern.search(headers)
    return match.group(1).strip() if match else ""


def check_live_release_surfaces(root: Path, manifest: dict, enabled: bool) -> list[dict]:
    if not enabled:
        return []

    latest = latest_appcast_metadata(root, manifest)
    if not latest:
        return [
            make_finding(
                "release_integrity",
                "high",
                "live-release-no-local-appcast",
                "Cannot check live release surfaces without a parseable local appcast.",
                "docs/appcast.xml needs a latest item first.",
                manifest["paths"]["appcast"],
            )
        ]

    findings: list[dict] = []
    live_appcast_url = manifest["live_release_surfaces"]["appcast"]
    result = curl_stdout(root, ["-fsSL", live_appcast_url])
    if result.returncode != 0:
        findings.append(
            make_finding(
                "release_integrity",
                "medium",
                "live-appcast-unreachable",
                "Live appcast could not be fetched.",
                f"curl failed for {live_appcast_url}.",
            )
        )
    else:
        try:
            live_root = ET.fromstring(result.stdout)
            live_item = live_root.find("./channel/item")
            live_enclosure = live_item.find("enclosure") if live_item is not None else None
            namespaces = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
            live_version = (
                live_item.findtext("sparkle:shortVersionString", namespaces=namespaces)
                if live_item is not None
                else ""
            ) or ""
            live_url = live_enclosure.attrib.get("url", "") if live_enclosure is not None else ""
            if live_version.strip() != latest["version"] or live_url != latest["url"]:
                findings.append(
                    make_finding(
                        "release_integrity",
                        "high",
                        "live-appcast-drift",
                        "Live appcast drifted from the committed latest appcast item.",
                        f"Live version/url {live_version!r}/{live_url!r}; local {latest['version']!r}/{latest['url']!r}.",
                    )
                )
        except ET.ParseError as exc:
            findings.append(
                make_finding(
                    "release_integrity",
                    "high",
                    "live-appcast-invalid",
                    "Live appcast is not parseable XML.",
                    str(exc),
                )
            )

    for route in manifest["live_release_surfaces"]["direct_download_routes"]:
        result = curl_stdout(root, ["-sSI", route])
        location = first_header_value(result.stdout, "location")
        if result.returncode != 0 or location != latest["url"]:
            findings.append(
                make_finding(
                    "release_integrity",
                    "high",
                    "live-download-route-drift",
                    "Live direct-download route does not redirect to the committed latest DMG.",
                    f"{route} location={location!r}; expected {latest['url']!r}.",
                )
            )

    page_result = curl_stdout(root, ["-fsSL", manifest["live_release_surfaces"]["download_page"]])
    if page_result.returncode != 0 or "Transcripted" not in page_result.stdout:
        findings.append(
            make_finding(
                "release_integrity",
                "medium",
                "live-download-page-unhealthy",
                "Live /download page did not return the expected install page.",
                f"curl failed or page marker was missing for {manifest['live_release_surfaces']['download_page']}.",
            )
        )

    crawler_result = curl_stdout(root, ["-fsSL", manifest["live_release_surfaces"]["crawler_text"]])
    if crawler_result.returncode != 0 or latest["version"] not in crawler_result.stdout:
        findings.append(
            make_finding(
                "release_integrity",
                "medium",
                "live-crawler-release-drift",
                "Crawler-facing release text does not mention the committed latest version.",
                f"Expected to find {latest['version']!r} in {manifest['live_release_surfaces']['crawler_text']}.",
            )
        )

    return findings


def sentry_release_name(root: Path, manifest: dict) -> str:
    with (root / manifest["paths"]["info_plist"]).open("rb") as handle:
        plist = plistlib.load(handle)
    prefix = str(plist.get("TranscriptedSentryReleasePrefix", "transcripted")).strip()
    version = str(plist.get("CFBundleShortVersionString", "")).strip()
    return f"{prefix}@{version}"


def check_sentry_release_health(
    root: Path,
    manifest: dict,
    enabled: bool,
    required: bool,
) -> tuple[list[dict], list[dict]]:
    if not enabled and not required:
        return [], []

    release = sentry_release_name(root, manifest)
    watch_items: list[dict] = []
    findings: list[dict] = []
    if not os.environ.get("SENTRY_AUTH_TOKEN"):
        if required:
            findings.append(
                make_finding(
                    "release_integrity",
                    "high",
                    "sentry-auth-missing",
                    "Cannot verify Sentry release existence because SENTRY_AUTH_TOKEN is not configured.",
                    f"Required release existence check for {release}.",
                )
            )
            return findings, watch_items
        watch_items.append(
            make_watch_item(
                "sentry-release-health-skipped",
                "Sentry release health was requested but SENTRY_AUTH_TOKEN is not configured.",
                f"Skipped release existence check for {release}.",
            )
        )
        return findings, watch_items

    if not command_exists("sentry-cli"):
        findings.append(
            make_finding(
                "release_integrity",
                "medium",
                "sentry-cli-missing",
                "Cannot verify Sentry release existence because sentry-cli is missing.",
                "Install sentry-cli on the release-health runner.",
            )
        )
        return findings, watch_items

    sentry = manifest["sentry"]
    result = run(
        [
            "sentry-cli",
            "releases",
            "info",
            "--org",
            sentry["org"],
            "--project",
            sentry["project"],
            release,
        ],
        cwd=root,
    )
    if result.returncode != 0:
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "sentry-release-missing",
                "Sentry release matching Info.plist was not found.",
                f"sentry-cli releases info failed for {release!r} in {sentry['org']}/{sentry['project']}.",
            )
        )

    return findings, watch_items


def uuid_set_for_path(root: Path, path: Path) -> tuple[set[str], str]:
    result = run(["dwarfdump", "--uuid", str(path)], cwd=root)
    if result.returncode != 0:
        return set(), result.stderr.strip() or result.stdout.strip()
    uuids = {
        match.group(1)
        for match in re.finditer(r"^UUID:\s+([A-Fa-f0-9-]+)\s", result.stdout, re.MULTILINE)
    }
    return uuids, ""


def check_release_debug_files(root: Path, manifest: dict, required: bool) -> list[dict]:
    if not required:
        return []

    findings: list[dict] = []
    binary_path = root / manifest["paths"]["release_app_binary"]
    debug_path = root / manifest["paths"]["release_debug_files"]
    if not binary_path.exists():
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "release-binary-missing",
                "Release app binary is missing for dSYM verification.",
                f"Expected {manifest['paths']['release_app_binary']}.",
                manifest["paths"]["release_app_binary"],
            )
        )
    if not debug_path.exists():
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "release-dsym-missing",
                "Release dSYM is missing.",
                f"Expected {manifest['paths']['release_debug_files']}.",
                manifest["paths"]["release_debug_files"],
            )
        )
    if findings:
        return findings

    if not command_exists("dwarfdump"):
        return [
            make_finding(
                "release_integrity",
                "medium",
                "dwarfdump-missing",
                "Cannot verify release dSYM UUIDs because dwarfdump is missing.",
                "Install Xcode command line tools on the release-health runner.",
            )
        ]

    binary_uuids, binary_error = uuid_set_for_path(root, binary_path)
    debug_uuids, debug_error = uuid_set_for_path(root, debug_path)
    if not binary_uuids or not debug_uuids or binary_uuids != debug_uuids:
        detail = (
            f"binary UUIDs={sorted(binary_uuids)!r}; dSYM UUIDs={sorted(debug_uuids)!r}; "
            f"errors={binary_error or debug_error or 'none'}"
        )
        findings.append(
            make_finding(
                "release_integrity",
                "high",
                "release-dsym-uuid-mismatch",
                "Release dSYM UUIDs do not match the app binary.",
                detail,
                manifest["paths"]["release_debug_files"],
            )
        )

    return findings


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def check_entitlements(root: Path, manifest: dict) -> list[dict]:
    findings: list[dict] = []
    path_map = {
        "local": manifest["paths"]["local_entitlements"],
        "beta": manifest["paths"]["beta_entitlements"],
    }

    for label, relative_path in path_map.items():
        actual = load_plist(root / relative_path)
        expected = manifest["expected_entitlements"][label]
        if actual != expected:
            findings.append(
                make_finding(
                    "entitlements_and_signing",
                    "high",
                    f"{label}-entitlements-drift",
                    f"{label.capitalize()} entitlements drifted from the nightly manifest.",
                    f"Expected {expected!r}, got {actual!r}.",
                    relative_path,
                )
            )
    return findings


def check_build_script_contract(root: Path, manifest: dict) -> list[dict]:
    findings: list[dict] = []
    for relative_path, required_fragments in manifest["required_build_script_substrings"].items():
        text = read_text(root / relative_path)
        for fragment in required_fragments:
            if fragment not in text:
                findings.append(
                    make_finding(
                        "entitlements_and_signing",
                        "medium",
                        "build-script-contract",
                        "Build script drifted from a required entitlement/signing guardrail.",
                        f"Missing fragment {fragment!r} in {relative_path}.",
                        relative_path,
                    )
                )
    return findings


def parse_codesign_entitlements(app_bundle: Path) -> dict | None:
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(app_bundle)],
        capture_output=True,
        text=False,
        check=False,
    )
    if result.returncode != 0:
        return None

    payload = (result.stdout or b"") + (result.stderr or b"")
    start = payload.find(b"<?xml")
    if start == -1:
        return None
    end = payload.find(b"</plist>", start)
    if end == -1:
        return None
    payload = payload[start : end + len(b"</plist>")]
    try:
        return plistlib.loads(payload)
    except Exception:
        return None


def check_built_app(root: Path, manifest: dict, app_bundle_argument: str | None) -> list[dict]:
    if not app_bundle_argument:
        return []

    app_bundle = (root / app_bundle_argument).resolve()
    findings: list[dict] = []
    if not app_bundle.exists():
        return [
            make_finding(
                "entitlements_and_signing",
                "medium",
                "built-app-missing",
                "Requested built app bundle does not exist.",
                f"Expected {app_bundle_argument}.",
                app_bundle_argument,
            )
        ]

    built_info_path = app_bundle / "Contents/Info.plist"
    if not built_info_path.exists():
        findings.append(
            make_finding(
                "entitlements_and_signing",
                "high",
                "built-info-missing",
                "Built app bundle is missing Contents/Info.plist.",
                f"Expected {built_info_path}.",
                app_bundle_argument,
            )
        )
        return findings

    built_info = load_plist(built_info_path)
    for key, expected in manifest["expected_info_plist"].items():
        actual = built_info.get(key)
        if actual != expected:
            findings.append(
                make_finding(
                    "entitlements_and_signing",
                    "high",
                    f"built-info-{key}",
                    f"Built app Info.plist drifted for {key}.",
                    f"Expected {expected!r}, got {actual!r}.",
                    app_bundle_argument,
                )
            )

    entitlements = parse_codesign_entitlements(app_bundle)
    if entitlements is None:
        findings.append(
            make_finding(
                "entitlements_and_signing",
                "medium",
                "built-entitlements-unreadable",
                "Could not read built app entitlements from codesign output.",
                "Run bash build.sh before trusting the built app contract.",
                app_bundle_argument,
            )
        )
        return findings

    expected_local = manifest["expected_entitlements"]["local"]
    if entitlements != expected_local:
        findings.append(
            make_finding(
                "entitlements_and_signing",
                "high",
                "built-entitlements-drift",
                "Built app entitlements drifted from the expected local contract.",
                f"Expected {expected_local!r}, got {entitlements!r}.",
                app_bundle_argument,
            )
        )

    return findings


def default_automation_path() -> Path:
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    return codex_home / "automations" / "transcripted-nightly-security" / "automation.toml"


def parse_simple_toml(path: Path) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if value.startswith('"') and value.endswith('"'):
            parsed[key] = value[1:-1]
        else:
            parsed[key] = value
    return parsed


def check_automation_prompt(manifest: dict, automation_path: Path) -> list[dict]:
    findings: list[dict] = []
    if not automation_path.exists():
        findings.append(
            make_finding(
                "automation_guardrails",
                "low",
                "automation-missing",
                "Nightly security automation.toml was not found locally.",
                f"Expected {automation_path}.",
                normalize_path(automation_path),
            )
        )
        return findings

    automation = parse_simple_toml(automation_path)

    prompt = str(automation.get("prompt", ""))
    required_fragments = [
        "nightly-security-check.py",
        "build/nightly-security-report.json",
        "deterministic",
        "[nightly-security]",
    ]
    for fragment in required_fragments:
        if fragment not in prompt:
            findings.append(
                make_finding(
                    "automation_guardrails",
                    "medium",
                    "automation-prompt-fragment",
                    "Nightly security automation prompt is missing a required deterministic guardrail fragment.",
                    f"Missing {fragment!r} in {automation_path}.",
                    normalize_path(automation_path),
                )
            )

    if automation.get("status") != "ACTIVE":
        findings.append(
            make_finding(
                "automation_guardrails",
                "medium",
                "automation-inactive",
                "Nightly security automation is not active.",
                f"Status is {automation.get('status')!r}.",
                normalize_path(automation_path),
            )
        )

    return findings


def check_sanitizer_corpus(root: Path, manifest: dict) -> list[dict]:
    corpus_path = root / manifest["paths"]["sanitizer_corpus"]
    findings: list[dict] = []

    try:
        with corpus_path.open("r", encoding="utf-8") as handle:
            corpus = json.load(handle)
    except Exception as exc:
        return [
            make_finding(
                "automation_guardrails",
                "high",
                "sanitizer-corpus-invalid",
                "Shared sanitizer corpus is missing or invalid.",
                str(exc),
                manifest["paths"]["sanitizer_corpus"],
            )
        ]

    cases = corpus.get("cases", [])
    if len(cases) < 5:
        findings.append(
            make_finding(
                "automation_guardrails",
                "medium",
                "sanitizer-corpus-too-small",
                "Shared sanitizer corpus should cover at least five high-signal privacy cases.",
                f"Found {len(cases)} cases.",
                manifest["paths"]["sanitizer_corpus"],
            )
        )

    seen_ids: set[str] = set()
    for case in cases:
        case_id = case.get("id", "")
        if not case_id or case_id in seen_ids:
            findings.append(
                make_finding(
                    "automation_guardrails",
                    "medium",
                    "sanitizer-corpus-duplicate-id",
                    "Shared sanitizer corpus needs unique non-empty case ids.",
                    f"Bad case id {case_id!r}.",
                    manifest["paths"]["sanitizer_corpus"],
                )
            )
        seen_ids.add(case_id)

        if not case.get("must_not_contain") or not case.get("must_contain"):
            findings.append(
                make_finding(
                    "automation_guardrails",
                    "medium",
                    "sanitizer-corpus-incomplete-case",
                    "Each sanitizer corpus case should define both forbidden and required markers.",
                    f"Case {case_id!r} is incomplete.",
                    manifest["paths"]["sanitizer_corpus"],
                )
            )

    for test_path_key in ("sentry_sanitizer_tests", "analytics_sanitizer_tests"):
        relative_path = manifest["paths"][test_path_key]
        text = read_text(root / relative_path)
        if "ObservabilitySanitizerCorpus.json" not in text:
            findings.append(
                make_finding(
                    "automation_guardrails",
                    "medium",
                    "sanitizer-tests-not-shared",
                    "Sanitizer tests should both load the shared regression corpus.",
                    f"{relative_path} does not reference ObservabilitySanitizerCorpus.json.",
                    relative_path,
                )
            )

    return findings


def score_report(findings: list[dict], manifest: dict) -> tuple[int, dict]:
    weights = manifest["scoring"]["weights"]
    multipliers = manifest["scoring"]["severity_multipliers"]
    by_category: dict[str, list[dict]] = defaultdict(list)
    for finding in findings:
        by_category[finding["category"]].append(finding)

    category_results: dict[str, dict] = {}
    total_score = 0
    for category, weight in weights.items():
        category_findings = by_category.get(category, [])
        if not category_findings:
            max_severity = "none"
        else:
            max_severity = max(category_findings, key=lambda item: SEVERITY_ORDER[item["severity"]])["severity"]
        multiplier = float(multipliers[max_severity])
        category_score = int(round(weight * multiplier))
        total_score += category_score
        category_results[category] = {
            "weight": weight,
            "score": category_score,
            "max_severity": max_severity,
            "finding_count": len(category_findings),
        }

    return total_score, category_results


def build_report(
    root: Path,
    manifest: dict,
    findings: list[dict],
    watch_items: list[dict],
    app_bundle: str | None,
    automation_path: Path,
) -> dict:
    score, category_results = score_report(findings, manifest)
    status = "pass" if not findings else "attention"
    return {
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo_root": normalize_path(root),
        "manifest_path": manifest["_path"],
        "automation_toml": normalize_path(automation_path),
        "app_bundle_checked": app_bundle,
        "status": status,
        "score": score,
        "category_results": category_results,
        "findings": findings,
        "watch_items": watch_items,
    }


def print_report(report: dict) -> None:
    print(f"Nightly security score: {report['score']}/100")
    for category, result in report["category_results"].items():
        print(
            f"- {category}: {result['score']}/{result['weight']} "
            f"(max severity: {result['max_severity']}, findings: {result['finding_count']})"
        )

    if not report["findings"]:
        print("No deterministic findings.")
    else:
        print("")
        print("Findings:")
        for finding in report["findings"]:
            location = f" [{finding['path']}]" if "path" in finding else ""
            print(f"- {finding['severity'].upper()} {finding['check_id']}{location}: {finding['summary']}")
            print(f"  {finding['detail']}")

    if report.get("watch_items"):
        print("")
        print("Watch items:")
        for item in report["watch_items"]:
            location = f" [{item['path']}]" if "path" in item else ""
            print(f"- {item['check_id']}{location}: {item['summary']}")
            print(f"  {item['detail']}")


def has_required_release_health_failure(args: argparse.Namespace, findings: list[dict]) -> bool:
    required_check_ids: set[str] = set()
    if args.require_sentry_release_health:
        required_check_ids.update(REQUIRED_SENTRY_RELEASE_CHECK_IDS)
    if args.require_release_debug_files:
        required_check_ids.update(REQUIRED_RELEASE_DEBUG_CHECK_IDS)

    return any(finding.get("check_id") in required_check_ids for finding in findings)


def main() -> int:
    args = parse_args()
    root = repo_root()
    manifest = load_manifest(root, args.manifest)
    automation_path = Path(args.automation_toml) if args.automation_toml else default_automation_path()

    findings: list[dict] = []
    findings.extend(scan_tracked_files(root, manifest))
    findings.extend(scan_recent_history(root, manifest))
    findings.extend(scan_shell_scripts(root))
    findings.extend(check_info_plist(root, manifest))
    appcast_findings, watch_items = check_appcast(root, manifest)
    findings.extend(appcast_findings)
    findings.extend(check_cask(root, manifest))
    findings.extend(check_observability_payload_keys(root, manifest))
    findings.extend(check_posthog_health_schema(root, manifest))
    findings.extend(check_live_release_surfaces(root, manifest, args.live_release_surfaces))
    sentry_findings, sentry_watch_items = check_sentry_release_health(
        root,
        manifest,
        args.sentry_release_health,
        args.require_sentry_release_health,
    )
    findings.extend(sentry_findings)
    watch_items.extend(sentry_watch_items)
    findings.extend(check_release_debug_files(root, manifest, args.require_release_debug_files))
    findings.extend(check_entitlements(root, manifest))
    findings.extend(check_build_script_contract(root, manifest))
    findings.extend(check_built_app(root, manifest, args.app_bundle))
    findings.extend(check_automation_prompt(manifest, automation_path))
    findings.extend(check_sanitizer_corpus(root, manifest))

    report = build_report(root, manifest, findings, watch_items, args.app_bundle, automation_path)
    print_report(report)

    if args.write_report:
        report_path = Path(args.write_report)
        if not report_path.is_absolute():
            report_path = root / report_path
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if (args.strict and findings) or has_required_release_health_failure(args, findings):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
