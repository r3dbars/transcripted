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
# Sparkle builds a small delta update from each older release DMG that sits in
# the updates folder next to the new one, up to this many. Clients on one of
# those versions download only the changed files instead of the full DMG.
SPARKLE_MAXIMUM_DELTAS="${SPARKLE_MAXIMUM_DELTAS:-5}"

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

if ! [[ "$SPARKLE_MAXIMUM_DELTAS" =~ ^[0-9]+$ ]]; then
    echo "SPARKLE_MAXIMUM_DELTAS must be a whole number, got: $SPARKLE_MAXIMUM_DELTAS"
    exit 1
fi

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    # CI keeps the EdDSA key in an encrypted secret instead of a persistent
    # keychain. Sparkle accepts the key on stdin, which avoids writing it to
    # disk or exposing it in command output.
    printf '%s' "$SPARKLE_PRIVATE_KEY" \
        | "$SPARKLE_APPCAST_TOOL" --maximum-deltas "$SPARKLE_MAXIMUM_DELTAS" --ed-key-file - "$UPDATES_DIR"
else
    "$SPARKLE_APPCAST_TOOL" --maximum-deltas "$SPARKLE_MAXIMUM_DELTAS" "$UPDATES_DIR"
fi

GENERATED_APPCAST="$UPDATES_DIR/appcast.xml"
if [ ! -f "$GENERATED_APPCAST" ]; then
    echo "Generated appcast missing: $GENERATED_APPCAST"
    exit 1
fi

DELTA_MANIFEST="$UPDATES_DIR/sparkle-deltas.txt"

python3 - "$GENERATED_APPCAST" "$REPO_APPCAST_PATH" "$INFO_PLIST_PATH" "$REPO_SLUG" "$UPDATES_DIR" "$DELTA_MANIFEST" <<'PY'
import os
import plistlib
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

generated_path, repo_path, info_plist_path, repo_slug, updates_dir, delta_manifest_path = sys.argv[1:7]
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


def version_key(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(\.\d+)*", value):
        raise SystemExit(f"unexpected Sparkle version shape: {value!r}")
    return tuple(int(part) for part in value.split("."))


with open(info_plist_path, "rb") as fh:
    info_plist = plistlib.load(fh)

minimum_system_version = str(info_plist.get("LSMinimumSystemVersion", "")).strip()
if not minimum_system_version:
    raise SystemExit("Info.plist is missing LSMinimumSystemVersion")
expected_version = str(info_plist.get("CFBundleShortVersionString", "")).strip()

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
# Older release DMGs sit in the updates folder so Sparkle can build deltas from
# them. Sparkle sorts newest first, but make sure the item we publish is the
# build this checkout's Info.plist describes, not an older archive.
if expected_version and version != expected_version:
    raise SystemExit(
        f"newest generated appcast item is {version}, but Info.plist is {expected_version}; "
        "is the new DMG missing from the updates folder?"
    )
for other in generated_channel.findall("item"):
    if version_key(item_version(other)) > version_key(version):
        raise SystemExit(f"updates folder holds {item_version(other)}, newer than the release {version}")

release_download_prefix = f"https://github.com/{repo_slug}/releases/download/v{version}/"
expected_tag_url = f"https://github.com/{repo_slug}/releases/tag/v{version}"
expected_asset_url = f"{release_download_prefix}Transcripted-{version}.dmg"

enclosure.attrib["url"] = expected_asset_url

# Delta updates. Sparkle writes each delta URL relative to the archive, so point
# them at the same GitHub release as the DMG. Each delta must be uploaded to
# that release next to the DMG; the manifest lists exactly which files. A client
# that can't fetch or apply a delta falls back to the full DMG.
delta_files: list[str] = []
deltas_node = latest_item.find("sparkle:deltas", namespaces=namespaces)
if deltas_node is not None:
    for delta in list(deltas_node.findall("enclosure")):
        from_version = delta.attrib.get(f"{{{sparkle_ns}}}deltaFrom", "").strip()
        if not from_version or version_key(from_version) >= version_key(version):
            raise SystemExit(f"delta has an invalid sparkle:deltaFrom: {from_version!r}")
        file_name = urllib.parse.unquote(
            urllib.parse.urlparse(delta.attrib.get("url", "")).path.rsplit("/", 1)[-1]
        )
        expected_file_name = f"Transcripted{version}-{from_version}.delta"
        if file_name != expected_file_name:
            raise SystemExit(f"delta file name {file_name!r} does not match {expected_file_name!r}")
        if not os.path.isfile(os.path.join(updates_dir, file_name)):
            raise SystemExit(f"delta {file_name} is in the appcast but missing from {updates_dir}")
        if not delta.attrib.get(f"{{{sparkle_ns}}}edSignature", "").strip():
            raise SystemExit(f"delta {file_name} is missing sparkle:edSignature")
        require_positive_length(delta)
        delta.attrib["url"] = release_download_prefix + file_name
        delta_files.append(file_name)
    if not delta_files:
        latest_item.remove(deltas_node)

with open(delta_manifest_path, "w", encoding="utf-8") as fh:
    for file_name in delta_files:
        fh.write(file_name + "\n")

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

children = list(repo_channel)
insert_index = next((index for index, child in enumerate(children) if child.tag == "item"), len(children))
repo_channel.insert(insert_index, latest_item)

if hasattr(ET, "indent"):
    ET.indent(repo_tree, space="  ")
repo_tree.write(repo_path, encoding="utf-8", xml_declaration=True)

print(f"Merged latest Sparkle item for {version} into {repo_path}")
if delta_files:
    print(f"Delta updates for {version} (upload each to the v{version} GitHub release):")
    for file_name in delta_files:
        print(f"  {file_name} ({os.path.getsize(os.path.join(updates_dir, file_name))} bytes)")
else:
    print(f"No delta updates for {version}; every client downloads the full DMG.")
PY

echo ""
echo "Appcast generated inside: $UPDATES_DIR"
echo "Updated: $REPO_APPCAST_PATH"
echo "Delta files to upload are listed in: $DELTA_MANIFEST"
