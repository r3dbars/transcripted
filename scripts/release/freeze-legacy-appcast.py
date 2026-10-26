#!/usr/bin/env python3
"""Freeze the legacy Sparkle feed (docs/appcast.xml) with one final entry.

Builds up to the one before the feed moved read their updates from
https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml.
New builds read the appcast.xml asset of the latest GitHub release instead. Old
installs still need one last hop: this script copies the first new-feed
release's item into the legacy file as its final entry, so they update to a
build that reads the new feed. After that nothing may edit docs/appcast.xml
again. The script records the file's sha256 in
config/release/legacy-appcast-freeze.json, and `scripts/dev/check-known-traps.py`
fails on any later change.

Run it ONCE, for the first release whose Info.plist carries the new SUFeedURL,
after that release's appcast.xml was generated and signed:

    python3 scripts/release/freeze-legacy-appcast.py \\
        --new-appcast /path/to/release/appcast.xml \\
        --info-plist Info.plist [--mark-critical] [--dry-run]

It refuses to run if the freeze file exists, if the item is not the version in
the given Info.plist, if that Info.plist's SUFeedURL is not the new feed, or if
the item is unsigned. Committing and pushing the result is publishing and needs
the owner's explicit go (the legacy feed is served from main).

    python3 scripts/release/freeze-legacy-appcast.py --self-test
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import plistlib
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE_NS}
NEW_FEED_URL = "https://github.com/r3dbars/transcripted/releases/latest/download/appcast.xml"
FREEZE_RELATIVE = Path("config/release/legacy-appcast-freeze.json")
LEGACY_RELATIVE = Path("docs/appcast.xml")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_marker_module():
    path = Path(__file__).with_name("mark-appcast-critical.py")
    spec = importlib.util.spec_from_file_location("mark_appcast_critical", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MARK = load_marker_module()


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def newest(tree: ET.ElementTree) -> ET.Element:
    return MARK.newest_item(MARK.items_of(tree))


def freeze(root: Path, new_appcast: Path, info_plist: Path, mark_critical: bool, dry_run: bool) -> str:
    freeze_path = root / FREEZE_RELATIVE
    legacy_path = root / LEGACY_RELATIVE
    if freeze_path.exists():
        raise ValueError(f"{FREEZE_RELATIVE} exists: the legacy feed is already frozen. This runs once.")
    if not legacy_path.is_file():
        raise ValueError(f"{LEGACY_RELATIVE} not found")

    with info_plist.open("rb") as handle:
        plist = plistlib.load(handle)
    if plist.get("SUFeedURL") != NEW_FEED_URL:
        raise ValueError(
            f"{info_plist} SUFeedURL is {plist.get('SUFeedURL')!r}, not {NEW_FEED_URL}. "
            "Freeze only for the first build that reads the new feed."
        )
    version = str(plist.get("CFBundleShortVersionString", "")).strip()

    new_tree = ET.parse(new_appcast)
    item = newest(new_tree)
    item_short = (item.findtext("sparkle:shortVersionString", namespaces=NS) or "").strip()
    if item_short != version or MARK.item_version(item) != str(plist.get("CFBundleVersion", "")).strip():
        raise ValueError(
            f"newest item in {new_appcast} is {item_short or 'unversioned'}, but {info_plist} is {version}"
        )
    enclosure = item.find("enclosure")
    if enclosure is None or not enclosure.attrib.get(f"{{{SPARKLE_NS}}}edSignature", "").strip():
        raise ValueError("the new release's item is missing its enclosure or sparkle:edSignature")
    expected_url = f"https://github.com/r3dbars/transcripted/releases/download/v{version}/Transcripted-{version}.dmg"
    if enclosure.attrib.get("url") != expected_url:
        raise ValueError(f"enclosure URL is {enclosure.attrib.get('url')!r}, expected {expected_url}")

    original = legacy_path.read_bytes()
    legacy_tree = ET.ElementTree(ET.fromstring(original))
    if MARK.serialize(ET.ElementTree(ET.fromstring(original))) != original:
        raise ValueError(
            f"{LEGACY_RELATIVE} is not in the form generate-sparkle-appcast.sh writes; "
            "refusing to rewrite it"
        )
    legacy_items = MARK.items_of(legacy_tree)
    if MARK.parse_version(MARK.item_version(newest(legacy_tree))) >= MARK.parse_version(MARK.item_version(item)):
        raise ValueError(
            f"{LEGACY_RELATIVE} already has {MARK.item_version(newest(legacy_tree))}, which is not older than {version}"
        )

    channel = legacy_tree.getroot().find("channel")
    children = list(channel)
    channel.insert(children.index(legacy_items[0]), copy.deepcopy(item))

    if dry_run:
        return f"dry run, nothing written: would add {version} as the final legacy entry"

    legacy_path.write_bytes(MARK.serialize(legacy_tree))
    if mark_critical:
        MARK.run(legacy_path, None, False, False)
    freeze_path.parent.mkdir(parents=True, exist_ok=True)
    freeze_path.write_text(
        json.dumps(
            {
                "frozen_version": version,
                "legacy_appcast": LEGACY_RELATIVE.as_posix(),
                "legacy_appcast_sha256": sha256_of(legacy_path),
                "new_feed_url": NEW_FEED_URL,
                "frozen_by": "scripts/release/freeze-legacy-appcast.py",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return f"froze {LEGACY_RELATIVE} with {version} as its final entry; commit it and {FREEZE_RELATIVE} together"


SAMPLE_LEGACY = """<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Transcripted Updates</title>
    <atom:link href="https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml" rel="self" type="application/rss+xml" />
    <item>
      <title>1.1.72</title>
      <sparkle:version>1.1.72</sparkle:version>
      <sparkle:shortVersionString>1.1.72</sparkle:shortVersionString>
      <enclosure url="https://github.com/r3dbars/transcripted/releases/download/v1.1.72/Transcripted-1.1.72.dmg" length="5" type="application/octet-stream" sparkle:edSignature="old" />
    </item>
  </channel>
</rss>
"""

SAMPLE_NEW = """<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Transcripted Updates</title>
    <atom:link href="https://github.com/r3dbars/transcripted/releases/latest/download/appcast.xml" rel="self" type="application/rss+xml" />
    <item>
      <title>1.1.80</title>
      <sparkle:version>1.1.80</sparkle:version>
      <sparkle:shortVersionString>1.1.80</sparkle:shortVersionString>
      <enclosure url="https://github.com/r3dbars/transcripted/releases/download/v1.1.80/Transcripted-1.1.80.dmg" length="9" type="application/octet-stream" sparkle:edSignature="new" />
    </item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: stub
length: 1
-->
"""


def self_test() -> int:
    failures: list[str] = []

    def expect(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    def expect_error(fragment: str, **kwargs) -> None:
        try:
            freeze(**kwargs)
        except ValueError as error:
            expect(fragment in str(error), f"wrong error for {fragment!r}: {error}")
        else:
            failures.append(f"no error for {fragment!r}")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "docs").mkdir()
        (root / "docs/appcast.xml").write_bytes(MARK.serialize(ET.ElementTree(ET.fromstring(SAMPLE_LEGACY))))
        new_appcast = root / "appcast.xml"
        new_appcast.write_text(SAMPLE_NEW, encoding="utf-8")
        plist = root / "Info.plist"

        def write_plist(version: str, feed: str) -> None:
            plist.write_bytes(
                plistlib.dumps({"CFBundleShortVersionString": version, "CFBundleVersion": version, "SUFeedURL": feed})
            )

        base = dict(root=root, new_appcast=new_appcast, info_plist=plist, mark_critical=False, dry_run=False)

        write_plist("1.1.80", "https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml")
        expect_error("not https://github.com", **base)
        write_plist("1.1.81", NEW_FEED_URL)
        expect_error("but", **base)
        write_plist("1.1.80", NEW_FEED_URL)

        before = (root / "docs/appcast.xml").read_bytes()
        message = freeze(**{**base, "dry_run": True})
        expect("dry run" in message, "dry run should say so")
        expect((root / "docs/appcast.xml").read_bytes() == before, "dry run must not write")
        expect(not (root / FREEZE_RELATIVE).exists(), "dry run must not write the freeze file")

        freeze(**{**base, "mark_critical": True})
        legacy = ET.parse(root / "docs/appcast.xml")
        versions = [MARK.item_version(item) for item in MARK.items_of(legacy)]
        expect(versions == ["1.1.80", "1.1.72"], f"final entry should sit on top of the history: {versions}")
        expect(
            legacy.getroot().find("channel/atom:link", {"atom": "http://www.w3.org/2005/Atom"}).get("href")
            == "https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml",
            "the legacy feed keeps its own self link",
        )
        expect(
            MARK.items_of(legacy)[0].find(MARK.CRITICAL_TAG) is not None, "--mark-critical should mark the final entry"
        )
        record = json.loads((root / FREEZE_RELATIVE).read_text(encoding="utf-8"))
        expect(record["frozen_version"] == "1.1.80", "freeze file should name the version")
        expect(record["legacy_appcast_sha256"] == sha256_of(root / "docs/appcast.xml"), "freeze file hash should match")
        expect_error("already frozen", **base)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("freeze-legacy-appcast self-test passed")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--new-appcast", type=Path, help="the signed appcast.xml built for the first new-feed release")
    parser.add_argument("--info-plist", type=Path, help="that release's Info.plist")
    parser.add_argument(
        "--mark-critical",
        action="store_true",
        help="also run mark-appcast-critical.py on the legacy file, so builds 1.1.22-1.1.62 show the update window (owner decision)",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.new_appcast or not args.info_plist:
        parser.error("--new-appcast and --info-plist are required")
    try:
        print(freeze(repo_root(), args.new_appcast, args.info_plist, args.mark_critical, args.dry_run))
    except (ValueError, ET.ParseError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
