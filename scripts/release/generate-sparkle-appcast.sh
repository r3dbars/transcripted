#!/bin/bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: bash scripts/release/generate-sparkle-appcast.sh /path/to/updates-folder"
    exit 1
fi

UPDATES_DIR="$1"
SPARKLE_APPCAST_TOOL="${SPARKLE_APPCAST_TOOL:-deps-tools/sparkle/bin/generate_appcast}"
REPO_APPCAST_PATH="${REPO_APPCAST_PATH:-docs/appcast.xml}"
INFO_PLIST_PATH="${INFO_PLIST_PATH:-Info.plist}"
REPO_SLUG="${REPO_SLUG:-r3dbars/transcripted}"

if [ ! -x "$SPARKLE_APPCAST_TOOL" ]; then
    echo "Sparkle tooling is missing."
    echo "Run: bash build-deps.sh --force"
    exit 1
fi

if [ ! -d "$UPDATES_DIR" ]; then
    echo "Updates folder not found: $UPDATES_DIR"
    exit 1
fi

if [ ! -f "$REPO_APPCAST_PATH" ]; then
    echo "Repo appcast not found: $REPO_APPCAST_PATH"
    exit 1
fi

if [ ! -f "$INFO_PLIST_PATH" ]; then
    echo "Info.plist not found: $INFO_PLIST_PATH"
    exit 1
fi

"$SPARKLE_APPCAST_TOOL" "$UPDATES_DIR"

GENERATED_APPCAST="$UPDATES_DIR/appcast.xml"
if [ ! -f "$GENERATED_APPCAST" ]; then
    echo "Generated appcast missing: $GENERATED_APPCAST"
    exit 1
fi

python3 - "$GENERATED_APPCAST" "$REPO_APPCAST_PATH" "$INFO_PLIST_PATH" "$REPO_SLUG" <<'PY'
import plistlib
import sys
import xml.etree.ElementTree as ET

generated_path, repo_path, info_plist_path, repo_slug = sys.argv[1:5]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
atom_ns = "http://www.w3.org/2005/Atom"
namespaces = {"sparkle": sparkle_ns, "atom": atom_ns}
ET.register_namespace("sparkle", sparkle_ns)
ET.register_namespace("atom", atom_ns)


def load_tree(path: str) -> ET.ElementTree:
    try:
        return ET.parse(path)
    except ET.ParseError as exc:
        raise SystemExit(f"invalid xml at {path}: {exc}") from exc


def first_item(channel: ET.Element) -> ET.Element:
    item = channel.find("item")
    if item is None:
        raise SystemExit("generated appcast has no items")
    return item


def item_version(item: ET.Element) -> str:
    version = (
        item.findtext("sparkle:shortVersionString", namespaces=namespaces)
        or item.findtext("sparkle:version", namespaces=namespaces)
        or ""
    ).strip()
    if not version:
        raise SystemExit("generated appcast latest item is missing a Sparkle version")
    return version


def require_positive_length(enclosure: ET.Element) -> None:
    length = enclosure.attrib.get("length", "").strip()
    if not length.isdigit() or int(length) <= 0:
        raise SystemExit("generated appcast enclosure has invalid length")


with open(info_plist_path, "rb") as fh:
    info_plist = plistlib.load(fh)

minimum_system_version = str(info_plist.get("LSMinimumSystemVersion", "")).strip()
if not minimum_system_version:
    raise SystemExit("Info.plist is missing LSMinimumSystemVersion")

generated_tree = load_tree(generated_path)
generated_root = generated_tree.getroot()
generated_channel = generated_root.find("channel")
if generated_channel is None:
    raise SystemExit("generated appcast is missing a channel")

latest_item = first_item(generated_channel)
enclosure = latest_item.find("enclosure")
if enclosure is None:
    raise SystemExit("generated appcast latest item is missing an enclosure")

signature = enclosure.attrib.get(f"{{{sparkle_ns}}}edSignature", "").strip()
if not signature:
    raise SystemExit("generated appcast latest item is missing sparkle:edSignature")
require_positive_length(enclosure)

version = item_version(latest_item)
expected_tag_url = f"https://github.com/{repo_slug}/releases/tag/v{version}"
expected_asset_url = f"https://github.com/{repo_slug}/releases/download/v{version}/Transcripted-{version}.dmg"

enclosure.attrib["url"] = expected_asset_url

minimum_node = latest_item.find(f"{{{sparkle_ns}}}minimumSystemVersion")
if minimum_node is None:
    minimum_node = ET.SubElement(latest_item, f"{{{sparkle_ns}}}minimumSystemVersion")
minimum_node.text = minimum_system_version

hardware_node = latest_item.find(f"{{{sparkle_ns}}}hardwareRequirements")
if hardware_node is None:
    hardware_node = ET.SubElement(latest_item, f"{{{sparkle_ns}}}hardwareRequirements")
hardware_node.text = "arm64"

link_node = latest_item.find("link")
if link_node is None:
    link_node = ET.SubElement(latest_item, "link")
link_node.text = expected_tag_url

release_notes_node = latest_item.find(f"{{{sparkle_ns}}}releaseNotesLink")
if release_notes_node is None:
    release_notes_node = ET.SubElement(latest_item, f"{{{sparkle_ns}}}releaseNotesLink")
release_notes_node.text = expected_tag_url

repo_tree = load_tree(repo_path)
repo_root = repo_tree.getroot()
repo_channel = repo_root.find("channel")
if repo_channel is None:
    raise SystemExit("repo appcast is missing a channel")

existing_items = repo_channel.findall("item")
for existing in existing_items:
    if item_version(existing) == version:
        repo_channel.remove(existing)

repo_channel.insert(0, latest_item)

if hasattr(ET, "indent"):
    ET.indent(repo_tree, space="  ")
repo_tree.write(repo_path, encoding="utf-8", xml_declaration=True)

print(f"Merged latest Sparkle item for {version} into {repo_path}")
PY

echo ""
echo "Appcast generated inside: $UPDATES_DIR"
echo "Updated: $REPO_APPCAST_PATH"
