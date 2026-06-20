#!/usr/bin/env python3
"""Read-only post-DMG release surface audit for Transcripted."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO = "r3dbars/transcripted"
HTTP_HEADERS = {"User-Agent": "TranscriptedPostDmgReleaseAudit/1.0"}
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
STATUSES = ("OK", "PENDING", "UNKNOWN", "FAIL")


@dataclass
class Check:
    name: str
    status: str
    detail: str

    def to_dict(self) -> dict[str, str]:
        return {"name": self.name, "status": self.status, "detail": self.detail}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def expected_asset_url(version: str) -> str:
    return f"https://github.com/{REPO}/releases/download/v{version}/Transcripted-{version}.dmg"


def sparkle_text(item: ET.Element, name: str) -> str:
    return item.findtext(f"{{{SPARKLE_NS}}}{name}") or ""


def appcast_latest_metadata(root: ET.Element) -> dict[str, str]:
    item = root.find("./channel/item")
    if item is None:
        raise ValueError("appcast has no channel/item")
    enclosure = item.find("enclosure")
    return {
        "title": item.findtext("title") or "",
        "version": sparkle_text(item, "version") or sparkle_text(item, "shortVersionString"),
        "short_version": sparkle_text(item, "shortVersionString"),
        "minimum_system_version": sparkle_text(item, "minimumSystemVersion"),
        "hardware_requirements": sparkle_text(item, "hardwareRequirements"),
        "url": enclosure.attrib.get("url", "") if enclosure is not None else "",
        "length": enclosure.attrib.get("length", "") if enclosure is not None else "",
        "signature": enclosure.attrib.get(f"{{{SPARKLE_NS}}}edSignature", "") if enclosure is not None else "",
    }


def latest_appcast(path: Path) -> dict[str, str]:
    return appcast_latest_metadata(ET.parse(path).getroot())


def cask_metadata(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    return {
        "version": find_regex(text, r'version "([^"]+)"'),
        "sha256": find_regex(text, r'sha256 "([^"]+)"'),
        "url_template": find_regex(text, r'url "([^"]+)"'),
        "livecheck": "strategy :github_latest" if "strategy :github_latest" in text else "",
    }


def find_regex(text: str, pattern: str) -> str:
    match = re.search(pattern, text)
    return match.group(1) if match else ""


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def asset_sha256(asset: dict[str, Any]) -> str:
    digest = str(asset.get("digest") or "").strip().lower()
    match = re.fullmatch(r"sha256:([0-9a-f]{64})", digest)
    return match.group(1) if match else ""


def http_head(url: str) -> tuple[int | None, str | None, int | None, str | None]:
    request = urllib.request.Request(url, headers=HTTP_HEADERS, method="HEAD")
    opener = urllib.request.build_opener(NoRedirectHandler)
    try:
        with opener.open(request, timeout=15) as response:
            length = response.headers.get("Content-Length")
            return response.status, response.geturl(), int(length) if length and length.isdigit() else None, None
    except urllib.error.HTTPError as exc:
        length = exc.headers.get("Content-Length")
        return exc.code, exc.headers.get("Location"), int(length) if length and length.isdigit() else None, None
    except (urllib.error.URLError, TimeoutError) as exc:
        return None, None, None, str(exc)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


def fetch_text(url: str) -> tuple[str, str | None]:
    request = urllib.request.Request(url, headers=HTTP_HEADERS)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.read().decode("utf-8", errors="replace"), None
    except urllib.error.HTTPError as exc:
        location = exc.headers.get("Location")
        if exc.code in {301, 302, 303, 307, 308} and location:
            return fetch_text(urllib.parse.urljoin(url, location))
        return "", str(exc)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
        return "", str(exc)


def github_release(version: str, root: Path, fixture: Path | None) -> tuple[dict[str, Any] | None, str]:
    if fixture:
        return load_json(fixture), str(fixture)
    if not shutil.which("gh"):
        return None, "gh CLI missing"
    result = run(
        [
            "gh",
            "release",
            "view",
            f"v{version}",
            "--repo",
            REPO,
            "--json",
            "tagName,isDraft,isPrerelease,url,assets",
        ],
        cwd=root,
    )
    if result.returncode != 0:
        return None, result.stderr.strip() or result.stdout.strip() or "gh release view failed"
    return json.loads(result.stdout), "gh release view"


def add(condition: bool, checks: list[Check], name: str, ok: str, bad: str, bad_status: str = "FAIL") -> None:
    checks.append(Check(name, "OK" if condition else bad_status, ok if condition else bad))


def audit(args: argparse.Namespace, root: Path) -> tuple[list[Check], list[str]]:
    manifest = load_json(root / "config/security/nightly-security-manifest.json")
    info = read_plist(root / "Info.plist")
    version = args.version or str(info.get("CFBundleShortVersionString") or "").strip()
    if not version:
        raise SystemExit("Could not determine release version from --version or Info.plist")

    checks: list[Check] = []
    commands = [
        f"gh release create v{version} <artifact> --repo {REPO}",
        f"SENTRY_REQUIRE_DEBUG_FILES=1 bash scripts/release/register-sentry-release.sh {version}",
        "bash scripts/release/generate-sparkle-appcast.sh /path/to/updates-folder",
        f"bash scripts/release/verify-sparkle-release.sh {version}",
        f"bash scripts/release/update-cask.sh {version}",
        "python3 scripts/ops/nightly-security-check.py --strict --live-release-surfaces",
        "python3 scripts/ops/nightly-security-check.py --strict --require-sentry-release-health",
    ]

    expected_url = expected_asset_url(version)
    expected_cask_template = f"https://github.com/{REPO}/releases/download/v#{{version}}/Transcripted-#{{version}}.dmg"
    expected_minimum = str(info.get("LSMinimumSystemVersion") or "").strip()

    add(
        bool(re.fullmatch(r"\d+\.\d+\.\d+", version)),
        checks,
        "version",
        f"Release version is {version}.",
        f"Release version {version!r} is not x.y.z.",
    )

    artifact_path = Path(args.artifact) if args.artifact else None
    artifact_exists = bool(artifact_path and artifact_path.is_file())
    artifact_size: int | None = None
    artifact_sha256 = ""
    if artifact_exists:
        assert artifact_path is not None
        artifact_size = artifact_path.stat().st_size
        artifact_sha256 = file_sha256(artifact_path)
        checks.append(Check("local DMG", "OK", f"{artifact_path} exists ({artifact_size} bytes, sha256 {artifact_sha256})."))
        add(
            artifact_path.name == f"Transcripted-{version}.dmg",
            checks,
            "DMG filename",
            "DMG filename matches the GitHub/Sparkle/Homebrew convention.",
            f"Expected Transcripted-{version}.dmg, got {artifact_path.name}.",
        )
    elif args.artifact:
        checks.append(Check("local DMG", "UNKNOWN", f"No local DMG found at {artifact_path}; build/package proof is not available."))

    appcast = latest_appcast(root / "docs/appcast.xml")
    add(appcast["version"] == version, checks, "appcast version", "Committed appcast latest item matches this version.", f"Committed appcast latest version is {appcast['version'] or 'missing'}, not {version}.", "PENDING")
    add(appcast["url"] == expected_url, checks, "appcast URL", "Committed appcast points at the expected GitHub release asset.", f"Committed appcast URL must become {expected_url}.", "PENDING")
    add(bool(appcast["signature"]), checks, "Sparkle signature", "Committed appcast latest item has a Sparkle signature.", "Committed appcast latest item is missing a Sparkle signature.", "PENDING")
    add(appcast["minimum_system_version"] == expected_minimum, checks, "Sparkle macOS floor", "Appcast minimum macOS version matches Info.plist.", f"Expected minimumSystemVersion {expected_minimum}, got {appcast['minimum_system_version'] or 'missing'}.")
    add(appcast["hardware_requirements"] == "arm64", checks, "Sparkle hardware", "Appcast hardware requirement is arm64.", f"Expected arm64, got {appcast['hardware_requirements'] or 'missing'}.")
    if artifact_size is not None and appcast["length"].isdigit():
        add(
            artifact_size == int(appcast["length"]),
            checks,
            "local DMG/appcast length",
            "Local DMG size matches committed appcast length.",
            f"Local DMG size {artifact_size} != committed appcast length {appcast['length']}; this artifact is not the published appcast asset yet.",
            "PENDING",
        )

    cask = cask_metadata(root / "Casks/transcripted.rb")
    add(cask["version"] == version, checks, "Homebrew cask version", "Committed cask version matches this release.", f"Committed cask version is {cask['version'] or 'missing'}, not {version}.", "PENDING")
    add(bool(re.fullmatch(r"[0-9a-f]{64}", cask["sha256"])), checks, "Homebrew cask sha256", "Committed cask has a valid sha256 shape.", "Committed cask sha256 is missing or invalid.", "PENDING")
    add(cask["url_template"] == expected_cask_template, checks, "Homebrew cask URL", "Committed cask URL uses the versioned GitHub release asset template.", f"Committed cask URL template drifted from {expected_cask_template}.")
    add(bool(cask["livecheck"]), checks, "Homebrew livecheck", "Committed cask livecheck tracks GitHub latest.", "Committed cask livecheck is not using GitHub latest.")
    if artifact_sha256 and re.fullmatch(r"[0-9a-f]{64}", cask["sha256"]):
        add(
            artifact_sha256 == cask["sha256"],
            checks,
            "local DMG/cask sha256",
            "Local DMG sha256 matches committed Homebrew cask.",
            "Local DMG sha256 differs from the committed cask; run update-cask only after publishing the final artifact.",
            "PENDING",
        )

    release, source = github_release(version, root, Path(args.github_release_json) if args.github_release_json else None)
    if release is None:
        checks.append(Check("GitHub release", "PENDING", f"v{version} is not verifiable yet ({source})."))
    else:
        checks.append(Check("GitHub release", "OK" if release.get("tagName") == f"v{version}" else "FAIL", f"{source}: tag={release.get('tagName')} url={release.get('url') or 'missing'}."))
        add(not release.get("isDraft"), checks, "GitHub draft flag", "GitHub release is not a draft.", "GitHub release is still a draft.", "PENDING")
        add(not release.get("isPrerelease"), checks, "GitHub prerelease flag", "GitHub release is not marked prerelease.", "GitHub release is marked prerelease.", "PENDING")
        assets = release.get("assets") or []
        asset = next((item for item in assets if item.get("name") == f"Transcripted-{version}.dmg"), None)
        if asset is None:
            checks.append(Check("GitHub DMG asset", "PENDING", f"Release is missing Transcripted-{version}.dmg."))
        else:
            checks.append(Check("GitHub DMG asset", "OK", f"Release asset is present ({asset.get('size') or 'unknown'} bytes)."))
            published_sha256 = asset_sha256(asset)
            if appcast["length"].isdigit() and asset.get("size"):
                add(int(appcast["length"]) == int(asset["size"]), checks, "asset size parity", "GitHub asset size matches appcast length.", f"GitHub asset size {asset['size']} != appcast length {appcast['length']}.", "PENDING")
            if published_sha256 and re.fullmatch(r"[0-9a-f]{64}", cask["sha256"]):
                add(
                    published_sha256 == cask["sha256"],
                    checks,
                    "GitHub asset/cask sha256",
                    "GitHub asset digest matches committed Homebrew cask.",
                    "GitHub asset digest differs from the committed cask sha256; brew install/upgrade would fetch a mismatched artifact.",
                    "PENDING",
                )
            elif not published_sha256:
                checks.append(Check("GitHub asset digest", "UNKNOWN", "GitHub release asset digest was not available from gh release view."))
            if artifact_size is not None and asset.get("size"):
                add(
                    artifact_size == int(asset["size"]),
                    checks,
                    "local DMG/GitHub asset size",
                    "Local DMG size matches the GitHub release asset.",
                    f"Local DMG size {artifact_size} != GitHub asset size {asset['size']}; do not assume this local artifact is published.",
                    "PENDING",
                )

    if not args.skip_live:
        for route in manifest["live_release_surfaces"]["direct_download_routes"]:
            status, location, _, error = http_head(route)
            if error:
                checks.append(Check(f"live route {route}", "UNKNOWN", error))
            else:
                add(
                    location == expected_url,
                    checks,
                    f"live route {route}",
                    f"Redirects to {location}.",
                    f"HTTP {status}; redirects to {location or 'no Location'}, not {expected_url}.",
                    "PENDING",
                )
        live_appcast, error = fetch_text(manifest["live_release_surfaces"]["appcast"])
        if error:
            checks.append(Check("live appcast", "UNKNOWN", error))
        else:
            try:
                live_latest = appcast_latest_metadata(ET.fromstring(live_appcast))
            except ET.ParseError as exc:
                checks.append(Check("live appcast", "UNKNOWN", f"Live appcast XML could not be parsed: {exc}."))
            except ValueError as exc:
                checks.append(Check("live appcast", "UNKNOWN", str(exc)))
            else:
                add(
                    live_latest["version"] == version and live_latest["url"] == expected_url,
                    checks,
                    "live appcast",
                    "Live appcast latest item points at this release.",
                    f"Live appcast latest item is version {live_latest['version'] or 'missing'} with URL {live_latest['url'] or 'missing'}, not {expected_url}.",
                    "PENDING",
                )
        page, error = fetch_text(manifest["live_release_surfaces"]["download_page"])
        if error:
            checks.append(Check("download page", "UNKNOWN", error))
        else:
            add(version in page or expected_url in page, checks, "download page", "Download page mentions the release version or asset URL.", "Download page does not mention this release version or asset URL.", "PENDING")
        crawler, error = fetch_text(manifest["live_release_surfaces"]["crawler_text"])
        if error:
            checks.append(Check("crawler text", "UNKNOWN", error))
        else:
            add(version in crawler, checks, "crawler text", "Crawler-facing release text mentions this version.", "Crawler-facing release text does not mention this version.", "PENDING")
    else:
        checks.append(Check("live surfaces", "UNKNOWN", "Skipped by --skip-live."))

    if not args.skip_asset_head:
        status, location, length, error = http_head(expected_url)
        if error:
            checks.append(Check("GitHub asset HEAD", "UNKNOWN", error))
        else:
            checks.append(Check("GitHub asset HEAD", "OK" if status and 200 <= status < 400 else "PENDING", f"HTTP {status}; location={location or expected_url}; length={length or 'unknown'}."))

    return checks, commands


def worst_status(checks: list[Check]) -> str:
    order = {"OK": 0, "PENDING": 1, "UNKNOWN": 2, "FAIL": 3}
    return max(checks, key=lambda check: order[check.status]).status if checks else "UNKNOWN"


def print_report(version: str, checks: list[Check], commands: list[str], as_json: bool) -> None:
    if as_json:
        print(json.dumps({"version": version, "status": worst_status(checks), "checks": [check.to_dict() for check in checks], "next_commands": commands}, indent=2, sort_keys=True))
        return
    print(f"Transcripted {version} post-DMG release audit")
    print(f"Overall: {worst_status(checks)}")
    print("")
    for status in STATUSES:
        matching = [check for check in checks if check.status == status]
        if not matching:
            continue
        print(status)
        for check in matching:
            print(f"- {check.name}: {check.detail}")
        print("")
    print("Manual publish/update gates this audit guards")
    for command in commands:
        print(f"- {command}")


def self_test() -> int:
    sample = Check("fixture", "PENDING", "manual release surface not published yet")
    assert sample.to_dict()["status"] == "PENDING"
    assert expected_asset_url("1.2.3").endswith("/v1.2.3/Transcripted-1.2.3.dmg")
    assert asset_sha256({"digest": "sha256:" + ("a" * 64)}) == "a" * 64
    assert asset_sha256({"digest": "md5:" + ("a" * 32)}) == ""
    assert worst_status([Check("a", "OK", ""), Check("b", "UNKNOWN", "")]) == "UNKNOWN"
    print("post-dmg-release-audit self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Release version. Defaults to Info.plist CFBundleShortVersionString.")
    parser.add_argument("--artifact", help="Path to the local Transcripted-<version>.dmg.")
    parser.add_argument("--github-release-json", help="Fixture from `gh release view --json tagName,isDraft,isPrerelease,url,assets`.")
    parser.add_argument("--skip-live", action="store_true", help="Skip transcripted.app live appcast/download/crawler checks.")
    parser.add_argument("--skip-asset-head", action="store_true", help="Skip HEAD request for the expected GitHub release asset.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument("--self-test", action="store_true", help="Run deterministic self-test and exit.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    root = repo_root()
    info = read_plist(root / "Info.plist")
    version = args.version or str(info.get("CFBundleShortVersionString") or "").strip()
    checks, commands = audit(args, root)
    print_report(version, checks, commands, args.json)
    return 1 if any(check.status == "FAIL" for check in checks) else 0


if __name__ == "__main__":
    sys.exit(main())
