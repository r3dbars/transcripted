#!/usr/bin/env python3
"""Mark one Sparkle appcast item as an important update for older versions.

Why this exists: every Transcripted build through 1.1.62 answers Sparkle's
`standardUserDriverShouldHandleShowingScheduledUpdate` with
`update.isCriticalUpdate` and ships without automatic downloads. So when a
background check finds a normal update, Sparkle shows nothing, and the app's
own "Install Update" action is the only way in. Those installs can't be
changed after the fact. The appcast can: an item carrying
`<sparkle:criticalUpdate sparkle:version="X"/>` is critical for every app whose
CFBundleVersion is below X, and Sparkle then shows its own update window on the
next scheduled check (no Skip or Remind Me Later buttons, but it can be closed).

This only edits the local `docs/appcast.xml`. Committing it to the branch that
backs the live feed is publishing, and needs the owner's explicit go.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
NAMESPACES = {"sparkle": SPARKLE_NS, "atom": ATOM_NS}
CRITICAL_TAG = f"{{{SPARKLE_NS}}}criticalUpdate"
VERSION_ATTR = f"{{{SPARKLE_NS}}}version"
VERSION_PATTERN = re.compile(r"^\d+(\.\d+)*$")

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("atom", ATOM_NS)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def parse_version(version: str) -> tuple[int, ...]:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"Version must look like 1.2.3, got {version!r}")
    return tuple(int(part) for part in version.split("."))


def item_version(item: ET.Element) -> str:
    # Sparkle compares against the host's CFBundleVersion, which is what
    # sparkle:version carries in this feed.
    version = (
        item.findtext("sparkle:version", namespaces=NAMESPACES)
        or item.findtext("sparkle:shortVersionString", namespaces=NAMESPACES)
        or ""
    ).strip()
    if not version:
        raise ValueError("appcast item is missing sparkle:version")
    return version


def find_item(channel: ET.Element, version: str | None) -> ET.Element:
    items = channel.findall("item")
    if not items:
        raise ValueError("appcast has no items")
    if version is None:
        return items[0]
    for item in items:
        if item_version(item) == version:
            return item
    raise ValueError(f"appcast has no item for version {version}")


def apply(tree: ET.ElementTree, version: str | None, below: str | None, remove: bool) -> str:
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("appcast is missing a channel")
    item = find_item(channel, version)
    target = item_version(item)

    for existing in item.findall(CRITICAL_TAG):
        item.remove(existing)

    if remove:
        return f"{target}: no longer marked critical"

    floor = below or target
    if parse_version(floor) > parse_version(target):
        raise ValueError(
            f"--below {floor} is newer than the item ({target}); "
            f"people already on {target} would be told to install it again"
        )

    marker = ET.SubElement(item, CRITICAL_TAG)
    marker.set(VERSION_ATTR, floor)
    return f"{target}: critical for apps below {floor}"


def write(tree: ET.ElementTree, path: Path) -> None:
    # Same writer settings as generate-sparkle-appcast.sh, so the rest of the
    # file stays byte-identical.
    if hasattr(ET, "indent"):
        ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def run(path: Path, version: str | None, below: str | None, remove: bool, dry_run: bool) -> str:
    tree = ET.parse(path)
    message = apply(tree, version, below, remove)
    if not dry_run:
        write(tree, path)
    return message


SAMPLE_APPCAST = """<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Transcripted Updates</title>
    <item>
      <title>1.1.63</title>
      <sparkle:version>1.1.63</sparkle:version>
      <sparkle:shortVersionString>1.1.63</sparkle:shortVersionString>
      <enclosure url="https://example.invalid/1.1.63.dmg" length="1" type="application/octet-stream" sparkle:edSignature="sig" />
    </item>
    <item>
      <title>1.1.62</title>
      <sparkle:version>1.1.62</sparkle:version>
      <sparkle:shortVersionString>1.1.62</sparkle:shortVersionString>
      <enclosure url="https://example.invalid/1.1.62.dmg" length="1" type="application/octet-stream" sparkle:edSignature="sig" />
    </item>
  </channel>
</rss>
"""


def self_test() -> int:
    failures: list[str] = []

    def check(condition: bool, label: str) -> None:
        if not condition:
            failures.append(label)

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "appcast.xml"

        # The writer must not reformat an already-normalized feed.
        path.write_text(SAMPLE_APPCAST)
        write(ET.parse(path), path)
        normalized = path.read_text()
        run(path, None, None, remove=True, dry_run=False)
        check(path.read_text() == normalized, "removing from an unmarked feed leaves it byte-identical")

        # Default: newest item, critical for everything older than it.
        message = run(path, None, None, remove=False, dry_run=False)
        check(message == "1.1.63: critical for apps below 1.1.63", f"default message: {message}")
        text = path.read_text()
        check(text.count("<sparkle:criticalUpdate") == 1, "exactly one marker")
        check('<sparkle:criticalUpdate sparkle:version="1.1.63" />' in text, "marker carries sparkle:version")
        newest, older = ET.parse(path).getroot().find("channel").findall("item")
        check(newest.find(CRITICAL_TAG) is not None, "newest item is marked")
        check(older.find(CRITICAL_TAG) is None, "older item is untouched")

        # Re-running replaces instead of stacking, and --below narrows it.
        run(path, None, "1.1.60", remove=False, dry_run=False)
        text = path.read_text()
        check(text.count("<sparkle:criticalUpdate") == 1, "re-run replaces the marker")
        check('sparkle:version="1.1.60"' in text, "--below is honored")

        # A specific older item can be marked.
        run(path, "1.1.62", None, remove=False, dry_run=False)
        older = ET.parse(path).getroot().find("channel").findall("item")[1]
        check(older.find(CRITICAL_TAG).get(VERSION_ATTR) == "1.1.62", "--version picks that item")

        # Dry run changes nothing.
        before = path.read_text()
        run(path, None, "1.1.50", remove=False, dry_run=True)
        check(path.read_text() == before, "dry run leaves the file alone")

        # --remove clears it, and the feed goes back to the normalized text.
        run(path, None, None, remove=True, dry_run=False)
        run(path, "1.1.62", None, remove=True, dry_run=False)
        check(path.read_text() == normalized, "remove restores the original feed")

        # Guard rails.
        for label, args in (
            ("floor newer than the item", (None, "1.1.64")),
            ("unknown item", ("9.9.9", None)),
            ("malformed floor", (None, "1.1.x")),
        ):
            try:
                run(path, args[0], args[1], remove=False, dry_run=True)
                failures.append(f"{label} should fail")
            except ValueError:
                pass

        check(parse_version("1.1.10") > parse_version("1.1.9"), "versions compare numerically")

    # The live feed must round-trip through this writer unchanged, or marking
    # it would rewrite unrelated items.
    live = repo_root() / "docs" / "appcast.xml"
    if live.exists():
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "appcast.xml"
            copy.write_bytes(live.read_bytes())
            write(ET.parse(copy), copy)
            check(copy.read_bytes() == live.read_bytes(), "docs/appcast.xml round-trips byte-identical")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("mark-appcast-critical self-test passed")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--appcast", type=Path, default=repo_root() / "docs" / "appcast.xml")
    parser.add_argument("--version", help="item to mark (default: the newest item)")
    parser.add_argument("--below", help="apps below this CFBundleVersion treat it as critical (default: the item's own version)")
    parser.add_argument("--remove", action="store_true", help="remove the marker instead")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    try:
        message = run(args.appcast, args.version, args.below, args.remove, args.dry_run)
    except (ValueError, ET.ParseError, FileNotFoundError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(("dry run, not written: " if args.dry_run else "") + message)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
