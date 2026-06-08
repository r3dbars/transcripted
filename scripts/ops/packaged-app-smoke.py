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
import time
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATUS_ORDER = {"PASS": 0, "WARN": 1, "FAIL": 2}
EXIT_CODES = {"PASS": 0, "WARN": 3, "FAIL": 1}
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
SPARKLE_REQUIRED_INFO_KEYS = ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates")
SENSITIVE_PATTERNS = {
    "private-key": re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", re.IGNORECASE),
    "github-token": re.compile(r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
    "openai-key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "bearer-token": re.compile(r"\bBearer\s+[A-Za-z0-9_.-]{10,}\b", re.IGNORECASE),
    "email": re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    "absolute-path": re.compile(r"/(?:Users|Volumes|private|tmp)/[^\s`\"']+"),
    "raw-url": re.compile(r"https?://[^\s`\"']+", re.IGNORECASE),
    "sensitive-key": re.compile(
        r"\b(audio_path|meeting_title|meeting_url|raw_url|source_app_bundle_id|"
        r"speaker_name|token|transcript_path|transcript_text|url)\b",
        re.IGNORECASE,
    ),
}


@dataclass
class Check:
    check_id: str
    status: str
    title: str
    target: str
    detail: str


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_path(path: Path | str, root: Path) -> str:
    path = Path(path)
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except Exception:
        return str(path)


def resolve_path(root: Path, value: str | None) -> Path | None:
    if not value:
        return None
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = root / path
    return path


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(command, 127, "", str(exc))


def load_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def add(checks: list[Check], check_id: str, status: str, title: str, target: str, detail: str) -> None:
    checks.append(Check(check_id, status, title, target, detail))


def worst_status(checks: list[Check]) -> str:
    if not checks:
        return "PASS"
    return max((check.status for check in checks), key=lambda status: STATUS_ORDER[status])


def appcast_metadata(path: Path) -> dict[str, str]:
    namespaces = {"sparkle": SPARKLE_NS, "atom": ATOM_NS}
    latest = ET.parse(path).getroot().find("./channel/item")
    if latest is None:
        raise ValueError("appcast has no latest item")
    enclosure = latest.find("enclosure")
    channel = ET.parse(path).getroot().find("./channel")
    atom_link = channel.find("atom:link", namespaces=namespaces) if channel is not None else None
    return {
        "title": (latest.findtext("title") or "").strip(),
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
        "signature": enclosure.attrib.get(f"{{{SPARKLE_NS}}}edSignature", "") if enclosure is not None else "",
        "self_url": atom_link.attrib.get("href", "") if atom_link is not None else "",
    }


def uuid_set(path: Path, root: Path) -> tuple[set[str], str]:
    result = run(["dwarfdump", "--uuid", str(path)], cwd=root)
    if result.returncode != 0:
        return set(), (result.stderr or result.stdout).strip()
    return (
        {
            match.group(1).upper()
            for match in re.finditer(r"^UUID:\s+([A-Fa-f0-9-]+)\s", result.stdout, re.MULTILINE)
        },
        "",
    )


def parse_codesign_entitlements(app_bundle: Path) -> dict[str, Any] | None:
    try:
        result = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", str(app_bundle)],
            capture_output=True,
            text=False,
            check=False,
        )
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    payload = (result.stdout or b"") + (result.stderr or b"")
    start = payload.find(b"<?xml")
    end = payload.find(b"</plist>", start)
    if start == -1 or end == -1:
        return None
    try:
        return plistlib.loads(payload[start : end + len(b"</plist>")])
    except Exception:
        return None


def scan_privacy_files(paths: list[Path]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for path in paths:
        if not path.exists() or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for name, pattern in SENSITIVE_PATTERNS.items():
            matches = pattern.findall(text)
            if matches:
                counts[name] = counts.get(name, 0) + len(matches)
    return counts


def validate_launch_report(report: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for key in ("appLaunched", "statusItemExists", "popoverConfigured", "onboardingCompleted"):
        if not report.get(key):
            errors.append(f"{key} was false")

    primary = report.get("content", {}).get("primaryActions", {})
    utility = report.get("content", {}).get("utilityActions", {})
    required_primary = {
        "home": ("Home", "transcripted.menubar.primary.home"),
        "startDictation": ("Start Dictation", "transcripted.menubar.primary.start-dictation"),
        "startMeeting": ("Start Meeting", "transcripted.menubar.primary.start-meeting"),
        "pasteLastDictation": ("Paste Last Dictation", "transcripted.menubar.primary.paste-last-dictation"),
        "recentMeetings": ("Recent Meetings", "transcripted.menubar.primary.recent-meetings"),
    }
    required_utility = {
        "connectAgent": ("Connect Agent", "transcripted.menubar.utility.connect-agent"),
        "submitFeedback": ("Submit feedback", "transcripted.menubar.utility.submit-feedback"),
        "checkUpdates": ("Check for Updates", "transcripted.menubar.utility.check-updates"),
        "settings": ("Settings", "transcripted.menubar.utility.settings"),
        "quit": ("Quit", "transcripted.menubar.utility.quit"),
    }

    for key, expected in required_primary.items():
        title, identifier = expected
        row = primary.get(key) or {}
        if row.get("title") != title:
            errors.append(f"{key} title mismatch")
        if row.get("automationIdentifier") != identifier:
            errors.append(f"{key} automation identifier mismatch")
        if not row.get("isVisible"):
            errors.append(f"{key} row hidden")
    for key in ("home", "startDictation", "startMeeting"):
        if not (primary.get(key) or {}).get("isEnabled"):
            errors.append(f"{key} row disabled")

    for key, expected in required_utility.items():
        title, identifier = expected
        row = utility.get(key) or {}
        if row.get("title") != title:
            errors.append(f"{key} title mismatch")
        if row.get("automationIdentifier") != identifier:
            errors.append(f"{key} automation identifier mismatch")
        if not row.get("isVisible"):
            errors.append(f"{key} row hidden")
    for key in ("connectAgent", "submitFeedback", "settings", "quit"):
        if not (utility.get(key) or {}).get("isEnabled"):
            errors.append(f"{key} row disabled")

    status = report.get("content", {}).get("header", {}).get("statusText")
    if status not in ("Ready", "On demand", "Cached"):
        errors.append("unexpected header status")
    return errors


def run_launch_smoke(
    app_binary: Path,
    out_dir: Path,
    timeout: float,
    root: Path,
    checks: list[Check],
) -> list[Path]:
    smoke_home = out_dir / "launch-home"
    smoke_log = out_dir / "launch-smoke.log"
    ui_report = out_dir / "launch-ui-smoke.json"
    smoke_home.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["HOME"] = str(smoke_home)
    env["CFFIXED_USER_HOME"] = str(smoke_home)
    env["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    env["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
    env["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
    env["TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT"] = str(ui_report)

    with smoke_log.open("wb") as log_handle:
        process = subprocess.Popen(
            [str(app_binary)],
            cwd=root,
            env=env,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
        )

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ui_report.exists() and ui_report.stat().st_size > 0:
            break
        if process.poll() is not None:
            break
        time.sleep(0.1)

    generated_paths = [smoke_log]
    if ui_report.exists():
        generated_paths.append(ui_report)

    if process.poll() is not None:
        add(
            checks,
            "launch-process",
            "FAIL",
            "App stays running during launch smoke",
            normalize_path(app_binary, root),
            f"Transcripted exited with status {process.returncode}; raw log retained locally.",
        )
        return generated_paths

    if not ui_report.exists() or ui_report.stat().st_size == 0:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        add(
            checks,
            "launch-ui-report",
            "FAIL",
            "Launch smoke writes menu/status report",
            normalize_path(ui_report, root),
            "TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT was not written before timeout.",
        )
        return generated_paths

    try:
        report = load_json(ui_report)
    except Exception as exc:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        add(
            checks,
            "launch-ui-report",
            "FAIL",
            "Launch smoke report is parseable",
            normalize_path(ui_report, root),
            str(exc),
        )
        return generated_paths

    errors = validate_launch_report(report)
    if errors:
        status = "FAIL"
        detail = f"{len(errors)} menu/status assertion(s) failed; raw report retained locally."
    else:
        status = "PASS"
        detail = "App launched, status item initialized, and core menu rows were present in the isolated smoke report."
    add(checks, "launch-menu-smoke", status, "App launch and menu smoke", normalize_path(ui_report, root), detail)

    time.sleep(0.5)
    if process.poll() is None:
        add(checks, "launch-stability", "PASS", "App remains alive after launch smoke", normalize_path(app_binary, root), "Process stayed alive until the smoke terminated it.")
    else:
        add(checks, "launch-stability", "FAIL", "App remains alive after launch smoke", normalize_path(app_binary, root), f"Process exited with status {process.returncode}.")

    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)

    for extra in sorted((smoke_home / "Library/Application Support/Transcripted/logs").glob("*")):
        if extra.is_file():
            generated_paths.append(extra)
    return generated_paths


def build_checks(args: argparse.Namespace) -> tuple[list[Check], dict[str, Any]]:
    root = repo_root()
    out_dir = resolve_path(root, args.out_dir)
    assert out_dir is not None
    out_dir.mkdir(parents=True, exist_ok=True)

    checks: list[Check] = []
    manifest_path = root / "config/security/nightly-security-manifest.json"
    manifest = load_json(manifest_path)
    expected_info = manifest.get("expected_info_plist", {})
    app_bundle = resolve_path(root, args.app_bundle)
    assert app_bundle is not None

    if not app_bundle.exists():
        add(checks, "app-bundle", "FAIL", "Packaged app bundle exists", normalize_path(app_bundle, root), "Run build-beta.sh before packaged app smoke.")
        return checks, {"out_dir": str(out_dir)}
    add(checks, "app-bundle", "PASS", "Packaged app bundle exists", normalize_path(app_bundle, root), "Found app bundle.")

    info_path = app_bundle / "Contents/Info.plist"
    if not info_path.exists():
        add(checks, "app-info", "FAIL", "Packaged app has Info.plist", normalize_path(info_path, root), "Contents/Info.plist is missing.")
        return checks, {"out_dir": str(out_dir)}

    try:
        app_info = load_plist(info_path)
    except Exception as exc:
        add(checks, "app-info", "FAIL", "Packaged app Info.plist is parseable", normalize_path(info_path, root), str(exc))
        return checks, {"out_dir": str(out_dir)}
    add(checks, "app-info", "PASS", "Packaged app Info.plist is parseable", normalize_path(info_path, root), "Bundle metadata loaded.")

    version = str(app_info.get("CFBundleShortVersionString", "")).strip()
    build = str(app_info.get("CFBundleVersion", "")).strip()
    executable_name = str(app_info.get("CFBundleExecutable", "Transcripted")).strip() or "Transcripted"
    app_binary = app_bundle / "Contents/MacOS" / executable_name
    expected_version = args.expected_version
    if expected_version is None:
        expected_version = str(load_plist(root / "Info.plist").get("CFBundleShortVersionString", "")).strip()

    if version and version == expected_version:
        add(checks, "app-version", "PASS", "Packaged app version matches expected version", version, f"Expected {expected_version}.")
    else:
        add(checks, "app-version", "FAIL", "Packaged app version matches expected version", version or "missing", f"Expected {expected_version}.")

    if build:
        status = "PASS" if build == version else "WARN"
        detail = "Build string matches short version." if build == version else "Build string differs from short version; make sure Sentry dist and release notes use the intended value."
        add(checks, "app-build", status, "Packaged app build metadata is present", build, detail)
    else:
        add(checks, "app-build", "FAIL", "Packaged app build metadata is present", "CFBundleVersion", "CFBundleVersion is missing.")

    if app_binary.exists() and os.access(app_binary, os.X_OK):
        add(checks, "app-binary", "PASS", "Packaged app executable exists", normalize_path(app_binary, root), "Executable is present.")
    else:
        add(checks, "app-binary", "FAIL", "Packaged app executable exists", normalize_path(app_binary, root), "Contents/MacOS executable is missing or not executable.")

    for key, expected in expected_info.items():
        actual = app_info.get(key)
        status = "PASS" if actual == expected else "FAIL"
        add(
            checks,
            f"info-{key}",
            status,
            f"Packaged app {key} matches release manifest",
            key,
            "Value matches." if status == "PASS" else f"Expected {expected!r}, got {actual!r}.",
        )

    scheduled = app_info.get("SUScheduledCheckInterval")
    if scheduled == 14_400:
        add(checks, "sparkle-check-interval", "PASS", "Sparkle scheduled check interval is four hours", "SUScheduledCheckInterval", "Value is 14400 seconds.")
    else:
        add(checks, "sparkle-check-interval", "WARN", "Sparkle scheduled check interval is four hours", "SUScheduledCheckInterval", f"Got {scheduled!r}; updater still works, but cadence drift needs review.")

    sparkle_framework = app_bundle / "Contents/Frameworks/Sparkle.framework"
    if sparkle_framework.exists():
        add(checks, "sparkle-framework", "PASS", "Sparkle framework is bundled", normalize_path(sparkle_framework, root), "Framework exists in the packaged app.")
    else:
        add(checks, "sparkle-framework", "FAIL", "Sparkle framework is bundled", normalize_path(sparkle_framework, root), "In-app updates cannot run without Sparkle.framework.")

    appcast_path = root / "docs/appcast.xml"
    try:
        appcast = appcast_metadata(appcast_path)
        add(checks, "appcast-parse", "PASS", "Local appcast is parseable", normalize_path(appcast_path, root), "Latest item loaded.")
        feed_url = str(app_info.get("SUFeedURL", "")).strip()
        if appcast["self_url"] == feed_url:
            add(checks, "appcast-feed-url", "PASS", "Appcast self link matches packaged SUFeedURL", appcast["self_url"], "Feed URL is coherent.")
        else:
            add(checks, "appcast-feed-url", "FAIL", "Appcast self link matches packaged SUFeedURL", appcast["self_url"] or "missing", "Sparkle clients may read a different feed than the committed appcast.")

        if appcast["version"] == version:
            add(checks, "appcast-version", "PASS", "Latest appcast version matches packaged app", appcast["version"], "Existing installs can discover this version once the feed is pushed live.")
        else:
            add(checks, "appcast-version", "WARN", "Latest appcast version matches packaged app", appcast["version"] or "missing", f"Packaged app is {version}; existing installs will not discover it in-app until docs/appcast.xml is updated.")

        expected_url = f"https://github.com/{manifest['repo_slug']}/releases/download/v{appcast['version']}/Transcripted-{appcast['version']}.dmg"
        if appcast["url"] == expected_url:
            add(checks, "appcast-enclosure-url", "PASS", "Latest appcast enclosure uses GitHub release asset shape", appcast["url"], "URL shape is coherent.")
        else:
            add(checks, "appcast-enclosure-url", "FAIL", "Latest appcast enclosure uses GitHub release asset shape", appcast["url"] or "missing", "Sparkle download URL drifted from the expected GitHub release asset.")

        if appcast["minimum_system_version"] == str(app_info.get("LSMinimumSystemVersion", "")).strip():
            add(checks, "appcast-min-os", "PASS", "Appcast minimum macOS matches packaged app", appcast["minimum_system_version"], "Minimum OS is aligned.")
        else:
            add(checks, "appcast-min-os", "FAIL", "Appcast minimum macOS matches packaged app", appcast["minimum_system_version"] or "missing", "Sparkle metadata must match LSMinimumSystemVersion.")

        if appcast["hardware_requirements"] == "arm64":
            add(checks, "appcast-hardware", "PASS", "Appcast declares arm64 hardware requirement", "arm64", "Apple Silicon requirement is explicit.")
        else:
            add(checks, "appcast-hardware", "FAIL", "Appcast declares arm64 hardware requirement", appcast["hardware_requirements"] or "missing", "Release metadata should stay arm64-only.")

        if appcast["signature"] and appcast["length"].isdigit() and int(appcast["length"]) > 0:
            add(checks, "appcast-signature", "PASS", "Latest appcast item has Sparkle signature and length", normalize_path(appcast_path, root), "Signature and positive length are present.")
        else:
            add(checks, "appcast-signature", "FAIL", "Latest appcast item has Sparkle signature and length", normalize_path(appcast_path, root), "Sparkle cannot trust/download the update without these fields.")
    except Exception as exc:
        add(checks, "appcast-parse", "FAIL", "Local appcast is parseable", normalize_path(appcast_path, root), str(exc))

    sign_result = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_bundle)], cwd=root)
    if sign_result.returncode == 0:
        add(checks, "codesign-verify", "PASS", "Packaged app signature verifies", normalize_path(app_bundle, root), "codesign --verify passed.")
    else:
        add(checks, "codesign-verify", "FAIL", "Packaged app signature verifies", normalize_path(app_bundle, root), "codesign --verify failed; raw output retained in the terminal/log only.")

    sign_detail = run(["codesign", "-dv", str(app_bundle)], cwd=root)
    signature_text = (sign_detail.stderr or sign_detail.stdout or "").lower()
    if "signature=adhoc" in signature_text:
        add(checks, "codesign-identity", "WARN", "Packaged app uses a distribution signing identity", normalize_path(app_bundle, root), "App is ad-hoc signed. OK for local smoke, not for a shipped release.")
    elif sign_detail.returncode == 0:
        add(checks, "codesign-identity", "PASS", "Packaged app uses a distribution signing identity", normalize_path(app_bundle, root), "codesign metadata is readable and not ad-hoc.")
    else:
        add(checks, "codesign-identity", "WARN", "Packaged app uses a distribution signing identity", normalize_path(app_bundle, root), "Could not inspect signing identity.")

    entitlements = parse_codesign_entitlements(app_bundle)
    beta_entitlements = load_plist(root / "config/entitlements/beta.plist")
    local_entitlements = load_plist(root / "config/entitlements/local.plist")
    if entitlements == beta_entitlements:
        add(checks, "app-entitlements", "PASS", "Packaged app uses beta/distribution entitlements", normalize_path(app_bundle, root), "Entitlements match config/entitlements/beta.plist.")
    elif entitlements == local_entitlements:
        add(checks, "app-entitlements", "WARN", "Packaged app uses beta/distribution entitlements", normalize_path(app_bundle, root), "Entitlements match local.plist; run build-beta.sh for distribution proof.")
    else:
        add(checks, "app-entitlements", "FAIL", "Packaged app uses beta/distribution entitlements", normalize_path(app_bundle, root), "Entitlements do not match local.plist or beta.plist.")

    dmg_path = resolve_path(root, args.dmg)
    if dmg_path is None and version:
        dmg_path = root / "build" / f"Transcripted-{version}.dmg"
    if dmg_path and dmg_path.exists():
        size = dmg_path.stat().st_size
        if size > 0:
            add(checks, "dmg-present", "PASS", "Versioned DMG exists", normalize_path(dmg_path, root), f"Size is {size} bytes.")
        else:
            add(checks, "dmg-present", "FAIL", "Versioned DMG exists", normalize_path(dmg_path, root), "DMG file is empty.")
        if shutil.which("hdiutil"):
            imageinfo = run(["hdiutil", "imageinfo", str(dmg_path)], cwd=root)
            status = "PASS" if imageinfo.returncode == 0 else "FAIL"
            add(checks, "dmg-readable", status, "DMG metadata is readable", normalize_path(dmg_path, root), "hdiutil imageinfo passed." if status == "PASS" else "hdiutil imageinfo failed.")
        dmg_sign = run(["codesign", "--verify", "--verbose=2", str(dmg_path)], cwd=root)
        if dmg_sign.returncode == 0:
            add(checks, "dmg-signature", "PASS", "DMG signature verifies", normalize_path(dmg_path, root), "codesign --verify passed.")
        else:
            add(checks, "dmg-signature", "WARN", "DMG signature verifies", normalize_path(dmg_path, root), "DMG is unsigned or signature was unreadable. Local smoke can continue; shipped releases should be signed.")
        stapler = run(["xcrun", "stapler", "validate", str(dmg_path)], cwd=root)
        if stapler.returncode == 0:
            add(checks, "dmg-notarization", "PASS", "DMG has a stapled notarization ticket", normalize_path(dmg_path, root), "stapler validate passed.")
        else:
            add(checks, "dmg-notarization", "WARN", "DMG has a stapled notarization ticket", normalize_path(dmg_path, root), "Not stapled or notarization skipped. Expected for SKIP_NOTARIZATION=1 pre-publish smoke.")
    else:
        status = "FAIL" if args.require_dmg else "WARN"
        add(checks, "dmg-present", status, "Versioned DMG exists", normalize_path(dmg_path or "build/Transcripted-<version>.dmg", root), "Run build-beta.sh first, or pass --dmg.")

    dsym_path = resolve_path(root, args.dsym) or (root / "build/Transcripted.app.dSYM")
    if dsym_path.exists():
        if shutil.which("dwarfdump") and app_binary.exists():
            binary_uuids, binary_error = uuid_set(app_binary, root)
            dsym_uuids, dsym_error = uuid_set(dsym_path, root)
            if binary_uuids and binary_uuids == dsym_uuids:
                add(checks, "dsym-uuid", "PASS", "dSYM UUIDs match packaged app binary", normalize_path(dsym_path, root), f"UUID count: {len(dsym_uuids)}.")
            else:
                add(checks, "dsym-uuid", "FAIL", "dSYM UUIDs match packaged app binary", normalize_path(dsym_path, root), f"UUID mismatch or unreadable. binary={len(binary_uuids)} dsym={len(dsym_uuids)} errors={bool(binary_error or dsym_error)}")
        else:
            add(checks, "dsym-uuid", "WARN", "dSYM UUIDs match packaged app binary", normalize_path(dsym_path, root), "dwarfdump or app binary is unavailable, so UUID match is unknown.")
    else:
        status = "FAIL" if args.require_dsym else "WARN"
        add(checks, "dsym-present", status, "Release dSYM exists", normalize_path(dsym_path, root), "build-beta.sh generates build/Transcripted.app.dSYM by default; missing symbols make Sentry release proof yellow.")

    launch_paths: list[Path] = []
    if args.skip_launch_smoke:
        add(checks, "launch-menu-smoke", "WARN", "App launch and menu smoke", normalize_path(app_binary, root), "Skipped by flag. Launch/menu proof is unknown.")
    elif app_binary.exists() and os.access(app_binary, os.X_OK):
        launch_paths = run_launch_smoke(app_binary, out_dir, args.launch_timeout, root, checks)

    privacy_counts = scan_privacy_files(launch_paths)
    if privacy_counts:
        detail = ", ".join(f"{key}={value}" for key, value in sorted(privacy_counts.items()))
        add(checks, "launch-log-privacy", "FAIL", "Launch smoke logs stay privacy-safe", normalize_path(out_dir, root), f"Sensitive-looking pattern counts: {detail}. Raw lines were not copied.")
    elif launch_paths:
        add(checks, "launch-log-privacy", "PASS", "Launch smoke logs stay privacy-safe", normalize_path(out_dir, root), "No transcript/audio/title/token/path/device/email/raw URL patterns found in generated smoke logs.")

    return checks, {
        "out_dir": str(out_dir),
        "app_bundle": str(app_bundle),
        "app_version": version,
        "app_build": build,
        "dmg": str(dmg_path) if dmg_path else "",
        "dsym": str(dsym_path),
    }


def render_markdown(payload: dict[str, Any]) -> str:
    checks = [Check(**item) for item in payload["checks"]]
    flags = [check for check in checks if check.status != "PASS"]
    lines = [
        "# Transcripted Packaged App Smoke",
        "",
        "## Short Answer",
        "",
        f"{payload['status']}: {payload['passed_count']}/{payload['check_count']} checks passed for packaged app smoke.",
        "",
        "## Flags",
        "",
    ]
    if flags:
        lines.extend(f"- {check.status} - {check.title}: {check.detail}" for check in flags)
    else:
        lines.append("No flags.")
    lines.extend(
        [
            "",
            "## What This Proves",
            "",
            "- Packaged app bundle metadata, Sparkle config, signing, DMG, dSYM, and isolated launch/menu smoke were checked.",
            "- Launch smoke used an isolated HOME and disabled file logging/runtime diagnostics so production logs stay clean.",
            "- Raw app logs stay local; this report only includes aggregate status.",
            "",
            "## Manual Leftovers",
            "",
            "- A non-notarized or unstapled DMG is expected yellow for SKIP_NOTARIZATION=1.",
            "- Existing installs will not discover a new version in-app until docs/appcast.xml is updated and pushed live.",
            "- Real install/upgrade proof still needs mounting/copying the DMG, Sparkle check/install on an existing app, and Homebrew install/upgrade when publishing.",
            "",
            "## Checks",
            "",
            "| Status | Check | Target | Detail |",
            "| --- | --- | --- | --- |",
        ]
    )
    for check in checks:
        lines.append(
            f"| {check.status} | {check.check_id} | `{check.target}` | {check.detail.replace('|', '/')} |"
        )
    return "\n".join(lines) + "\n"


def make_payload(checks: list[Check], metadata: dict[str, Any]) -> dict[str, Any]:
    status = worst_status(checks)
    passed = sum(1 for check in checks if check.status == "PASS")
    return {
        "status": status,
        "generated_at": utc_now(),
        "check_count": len(checks),
        "passed_count": passed,
        "warning_count": sum(1 for check in checks if check.status == "WARN"),
        "failure_count": sum(1 for check in checks if check.status == "FAIL"),
        "checks": [asdict(check) for check in checks],
        **metadata,
    }


def self_test() -> int:
    fixture = {
        "checks": [
            asdict(Check("ok", "PASS", "fixture pass", "fixture", "ok")),
            asdict(Check("warn", "WARN", "fixture warn", "fixture", "warn")),
        ],
        "status": "WARN",
        "passed_count": 1,
        "check_count": 2,
    }
    markdown = render_markdown(fixture)
    privacy = scan_privacy_files([])
    if "Transcripted Packaged App Smoke" not in markdown or privacy:
        print("packaged-app-smoke self-test failed", file=sys.stderr)
        return 1
    payload = make_payload(
        [Check("ok", "PASS", "fixture pass", "fixture", "ok"), Check("bad", "FAIL", "fixture fail", "fixture", "bad")],
        {},
    )
    if payload["status"] != "FAIL" or EXIT_CODES[payload["status"]] != 1:
        print("packaged-app-smoke self-test failed", file=sys.stderr)
        return 1
    print("packaged-app-smoke self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Smoke a built/packaged Transcripted.app before release publishing.")
    parser.add_argument("--app-bundle", default="build/Transcripted.app", help="Path to Transcripted.app. Default: build/Transcripted.app")
    parser.add_argument("--dmg", help="Path to the DMG. Default: build/Transcripted-<app-version>.dmg")
    parser.add_argument("--dsym", default="build/Transcripted.app.dSYM", help="Path to the app dSYM. Default: build/Transcripted.app.dSYM")
    parser.add_argument("--expected-version", help="Expected CFBundleShortVersionString. Default: repo Info.plist version.")
    parser.add_argument("--require-dmg", action="store_true", help="Fail instead of warn when the versioned DMG is missing.")
    parser.add_argument("--require-dsym", action="store_true", help="Fail instead of warn when the dSYM is missing.")
    parser.add_argument("--skip-launch-smoke", action="store_true", help="Skip isolated app launch/menu smoke and mark it yellow.")
    parser.add_argument("--launch-timeout", type=float, default=10.0, help="Seconds to wait for launch smoke report. Default: 10.")
    parser.add_argument("--out-dir", default=f"/tmp/transcripted-packaged-app-smoke/smoke-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}", help="Directory for local smoke evidence.")
    parser.add_argument("--write-report", help="Write JSON report. Default: <out-dir>/packaged-app-smoke.json")
    parser.add_argument("--markdown-out", help="Write Markdown report. Default: <out-dir>/packaged-app-smoke.md")
    parser.add_argument("--self-test", action="store_true", help="Run a small renderer/status self-test.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()

    checks, metadata = build_checks(args)
    payload = make_payload(checks, metadata)
    out_dir = Path(payload["out_dir"])
    report_path = resolve_path(repo_root(), args.write_report) if args.write_report else out_dir / "packaged-app-smoke.json"
    markdown_path = resolve_path(repo_root(), args.markdown_out) if args.markdown_out else out_dir / "packaged-app-smoke.md"
    assert report_path is not None
    assert markdown_path is not None
    report_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(payload), encoding="utf-8")

    print(f"Packaged app smoke: {payload['status']}")
    print(f"Report: {report_path}")
    print(f"Markdown: {markdown_path}")
    if payload["status"] != "PASS":
        for check in checks:
            if check.status != "PASS":
                print(f"- {check.status} {check.check_id}: {check.detail}")
    return EXIT_CODES[payload["status"]]


if __name__ == "__main__":
    sys.exit(main())
