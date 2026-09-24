#!/usr/bin/env python3
"""Mark the newest Sparkle appcast item as an important update for older versions.

Why this exists: builds 1.1.22 through 1.1.62 answer Sparkle's
`standardUserDriverShouldHandleShowingScheduledUpdate` with
`update.isCriticalUpdate` and ship without automatic downloads, and their own
Install action does nothing while Sparkle's held reminder is open. So a
background check that finds a normal update shows nothing useful. Those
installs can't be changed after the fact. The appcast can: an item carrying
`<sparkle:criticalUpdate sparkle:version="X"/>` is critical for every app whose
CFBundleVersion is below X, and Sparkle then shows its own update window.

Sparkle only looks at the newest item, so this always marks the newest one and
leaves older items alone (a marker there is inert). The default floor stops at 1.1.63, the
first build that downloads updates on its own and whose Install action works,
so marking later releases doesn't nag people who are already fine.

This only edits the local `docs/appcast.xml`. Committing it to the branch that
backs the live feed is publishing, and needs the owner's explicit go.
"""

from __future__ import annotations

import argparse
import io
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
NAMESPACES = {"sparkle": SPARKLE_NS, "atom": ATOM_NS}
CRITICAL_TAG = f"{{{SPARKLE_NS}}}criticalUpdate"
TAGS_TAG = f"{{{SPARKLE_NS}}}tags"
VERSION_ATTR = f"{{{SPARKLE_NS}}}version"
VERSION_PATTERN = re.compile(r"^\d+(\.\d+)*$")
# First build with automatic downloads on and a working Install action (#1797).
# Anything at or above this handles routine updates without the marker.
FIRST_SELF_UPDATING_VERSION = "1.1.63"

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


def items_of(tree: ET.ElementTree) -> list[ET.Element]:
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("appcast is missing a channel")
    items = channel.findall("item")
    if not items:
        raise ValueError("appcast has no items")
    return items


def newest_item(items: list[ET.Element]) -> ET.Element:
    # Sparkle offers the highest version it can install, not the first item.
    return max(items, key=lambda item: parse_version(item_version(item)))


def legacy_tag_markers(item: ET.Element) -> list[tuple[ET.Element, ET.Element]]:
    # Older Sparkle feeds said <sparkle:tags><sparkle:criticalUpdate/></sparkle:tags>,
    # which Sparkle still reads as critical for everyone.
    return [(tags, marker) for tags in item.findall(TAGS_TAG) for marker in tags.findall(CRITICAL_TAG)]


def default_floor(target: str) -> str:
    return min(target, FIRST_SELF_UPDATING_VERSION, key=parse_version)


def apply(tree: ET.ElementTree, below: str | None, remove: bool) -> str:
    items = items_of(tree)
    item = newest_item(items)
    target = item_version(item)

    # Only the newest item counts. Markers on older items (the feed still has
    # bare ones on 1.1.22 and 1.1.23 from April) are inert, and leaving them
    # keeps the published diff to the one item that matters.
    for existing in item.findall(CRITICAL_TAG):
        item.remove(existing)
    for tags, existing in legacy_tag_markers(item):
        tags.remove(existing)
        if len(tags) == 0:
            item.remove(tags)

    if remove:
        return f"{target}: not marked critical"

    floor = default_floor(target) if below is None else below
    if parse_version(floor) > parse_version(target):
        raise ValueError(
            f"--below {floor} is above the newest item ({target}); only apps older "
            f"than {target} are offered it, so use {target} or lower"
        )

    marker = ET.SubElement(item, CRITICAL_TAG)
    marker.set(VERSION_ATTR, floor)
    return f"{target}: critical for apps below {floor}"


def check(tree: ET.ElementTree) -> str:
    """Report the marker state; raise if the previous release is marked and the newest isn't.

    That is the "forgot to carry it forward" case: generate-sparkle-appcast.sh
    puts a new unmarked item on top and Sparkle stops showing the window.
    """
    items = sorted(items_of(tree), key=lambda item: parse_version(item_version(item)), reverse=True)
    newest = items[0]
    target = item_version(newest)
    marker = newest.find(CRITICAL_TAG)
    if marker is None and legacy_tag_markers(newest):
        return f"{target}: critical for every older app (legacy sparkle:tags form)"
    if marker is None:
        if len(items) > 1 and items[1].find(CRITICAL_TAG) is not None:
            previous = item_version(items[1])
            raise ValueError(
                f"{previous} is marked critical but the newest item ({target}) is not, so Sparkle "
                "stops showing the window. Re-run this script, or leave it off on purpose"
            )
        return f"{target}: not marked critical"
    floor = marker.get(VERSION_ATTR)
    return f"{target}: critical for apps below {floor}" if floor else f"{target}: critical for every older app"


def serialize(tree: ET.ElementTree) -> bytes:
    # Same writer settings as generate-sparkle-appcast.sh, so the rest of the
    # file stays byte-identical.
    if hasattr(ET, "indent"):
        ET.indent(tree, space="  ")
    buffer = io.BytesIO()
    tree.write(buffer, encoding="utf-8", xml_declaration=True)
    return buffer.getvalue()


def write(tree: ET.ElementTree, path: Path) -> None:
    path.write_bytes(serialize(tree))


def run(path: Path, below: str | None, remove: bool, dry_run: bool) -> str:
    original = path.read_bytes()
    # ElementTree drops comments and CDATA and can reflow text. Refuse to touch
    # a feed that wouldn't survive a no-op rewrite, so the only change we ever
    # publish is the marker line.
    if serialize(ET.ElementTree(ET.fromstring(original))) != original:
        raise ValueError(
            f"{path} isn't in the form generate-sparkle-appcast.sh writes (a comment, CDATA or "
            "spacing would change). Add the <sparkle:criticalUpdate> line by hand instead"
        )
    tree = ET.ElementTree(ET.fromstring(original))
    message = apply(tree, below, remove)
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

    def check_(condition: bool, label: str) -> None:
        if not condition:
            failures.append(label)

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "appcast.xml"

        # The writer must not reformat an already-normalized feed.
        path.write_text(SAMPLE_APPCAST)
        write(ET.parse(path), path)
        normalized = path.read_text()
        run(path, None, remove=True, dry_run=False)
        check_(path.read_text() == normalized, "removing from an unmarked feed leaves it byte-identical")
        check_(check(ET.parse(path)) == "1.1.63: not marked critical", "check on an unmarked feed")

        # Default: newest item, critical for everything older than it.
        message = run(path, None, remove=False, dry_run=False)
        check_(message == "1.1.63: critical for apps below 1.1.63", f"default message: {message}")
        text = path.read_text()
        check_(text.count("<sparkle:criticalUpdate") == 1, "exactly one marker")
        check_('<sparkle:criticalUpdate sparkle:version="1.1.63" />' in text, "marker carries sparkle:version")
        newest, older = ET.parse(path).getroot().find("channel").findall("item")
        check_(newest.find(CRITICAL_TAG) is not None, "newest item is marked")
        check_(older.find(CRITICAL_TAG) is None, "older item is untouched")
        check_(check(ET.parse(path)) == "1.1.63: critical for apps below 1.1.63", "check reads the marker")

        # Re-running replaces instead of stacking, and --below narrows it.
        run(path, "1.1.60", remove=False, dry_run=False)
        text = path.read_text()
        check_(text.count("<sparkle:criticalUpdate") == 1, "re-run replaces the marker")
        check_('sparkle:version="1.1.60"' in text, "--below is honored")

        # Dry run changes nothing.
        before = path.read_text()
        run(path, "1.1.50", remove=False, dry_run=True)
        check_(path.read_text() == before, "dry run leaves the file alone")

        # --remove restores the normalized feed.
        run(path, None, remove=True, dry_run=False)
        check_(path.read_text() == normalized, "remove restores the original feed")

        # A later release: the default floor stops at the first self-updating
        # build, and a marker left on the old item is cleared.
        tree = ET.parse(path)
        apply(tree, None, remove=False)
        channel = tree.getroot().find("channel")
        later = ET.fromstring(
            f'<item xmlns:sparkle="{SPARKLE_NS}"><title>1.1.64</title>'
            "<sparkle:version>1.1.64</sparkle:version></item>"
        )
        channel.insert(list(channel).index(channel.find("item")), later)
        try:
            check(tree)
            failures.append("check should flag a marker left only on an older item")
        except ValueError:
            pass
        message = apply(tree, None, remove=False)
        check_(message == "1.1.64: critical for apps below 1.1.63", f"later default floor: {message}")
        check_(later.find(CRITICAL_TAG) is not None, "the new newest item is marked")
        check_(check(tree) == "1.1.64: critical for apps below 1.1.63", "check passes once carried forward")
        run_remove = apply(tree, None, remove=True)
        check_(run_remove == "1.1.64: not marked critical", f"remove message: {run_remove}")
        try:
            check(tree)
            failures.append("check should flag the previous release marked, newest not")
        except ValueError:
            pass

        # Newest means highest version, not first in the file.
        channel.remove(later)
        channel.append(later)
        check_(item_version(newest_item(channel.findall("item"))) == "1.1.64", "newest is by version")

        # Guard rails.
        for label, below in (
            ("floor above the item", "1.1.64"),
            ("malformed floor", "1.1.x"),
            ("empty floor", ""),
        ):
            try:
                run(path, below, remove=False, dry_run=True)
                failures.append(f"{label} should fail")
            except ValueError:
                pass

        # The legacy <sparkle:tags> form on the newest item is read and cleared.
        legacy = ET.parse(path)
        newest_legacy = newest_item(items_of(legacy))
        tags = ET.SubElement(newest_legacy, TAGS_TAG)
        ET.SubElement(tags, CRITICAL_TAG)
        check_("legacy" in check(legacy), "check reads the legacy tags form")
        apply(legacy, None, remove=True)
        check_(newest_legacy.find(TAGS_TAG) is None, "remove clears the legacy tags form")
        check_(check(legacy).endswith("not marked critical"), "nothing left after remove")

        # A feed that wouldn't survive a no-op rewrite is refused untouched.
        odd = Path(tmp) / "odd.xml"
        odd.write_text(SAMPLE_APPCAST.replace("<channel>", "<channel>\n    <!-- keep me -->", 1))
        odd_before = odd.read_bytes()
        try:
            run(odd, None, remove=False, dry_run=False)
            failures.append("a feed with a comment should be refused")
        except ValueError:
            pass
        check_(odd.read_bytes() == odd_before, "a refused feed is left untouched")

        check_(parse_version("1.1.10") > parse_version("1.1.9"), "versions compare numerically")
        check_(default_floor("1.1.62") == "1.1.62", "floor is the item itself before 1.1.63")

    # The live feed must round-trip through this writer unchanged, or marking
    # it would rewrite unrelated items.
    live = repo_root() / "docs" / "appcast.xml"
    if live.exists():
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "appcast.xml"
            copy.write_bytes(live.read_bytes())
            write(ET.parse(copy), copy)
            check_(
                copy.read_bytes() == live.read_bytes(),
                "docs/appcast.xml no longer round-trips byte-identical; rewrite it with "
                "generate-sparkle-appcast.sh's writer (ElementTree, indent 2) so the marker stays a one-line change",
            )

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("mark-appcast-critical self-test passed")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--appcast", type=Path, default=repo_root() / "docs" / "appcast.xml")
    parser.add_argument(
        "--below",
        help=f"apps below this CFBundleVersion get the window (default: the newest item's version, capped at {FIRST_SELF_UPDATING_VERSION})",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--remove", action="store_true", help="clear the marker from the newest item")
    mode.add_argument("--check", action="store_true", help="print the marker state; fail if the previous release is marked and the newest is not")
    mode.add_argument("--self-test", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    if (args.check or args.remove) and args.below is not None:
        parser.error("--below only applies when marking")

    try:
        if args.below and VERSION_PATTERN.fullmatch(args.below) and parse_version(args.below) > parse_version(FIRST_SELF_UPDATING_VERSION):
            print(
                f"warning: --below {args.below} also reaches {FIRST_SELF_UPDATING_VERSION}+ builds, which update on their own; "
                "they'll get the no-Skip window too",
                file=sys.stderr,
            )
        if args.check:
            print(check(ET.parse(args.appcast)))
            return 0
        message = run(args.appcast, args.below, args.remove, args.dry_run)
    except (ValueError, ET.ParseError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(("dry run, not written: " if args.dry_run else "") + message)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
