#!/usr/bin/env bash
# Guards scripts/release/generate-sparkle-appcast.sh's delta-update handling
# with a stub generate_appcast. No Sparkle tools, signing keys, DMGs, or network
# are involved, and the real docs/appcast.xml is only read, never written.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/release/generate-sparkle-appcast.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-sparkle-deltas.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

stub="$test_root/generate_appcast"
cat > "$stub" <<'STUB'
#!/usr/bin/env python3
# Stand-in for Sparkle's generate_appcast. It records its arguments and writes
# an appcast shaped like Sparkle 2.9.1's output (FeedXML.swift): relative
# enclosure URLs and a sparkle:deltas block after the main enclosure.
import os
import sys

args = sys.argv[1:]
updates_dir = args[-1]
with open(os.path.join(updates_dir, "stub-args.txt"), "w") as fh:
    fh.write("\n".join(args[:-1]) + "\n")
if "--ed-key-file" in args and args[args.index("--ed-key-file") + 1] == "-":
    with open(os.path.join(updates_dir, "stub-stdin.txt"), "w") as fh:
        fh.write(sys.stdin.read())

mode = os.environ.get("STUB_MODE", "deltas")
deltas = [] if mode == "none" else ["9.9.8", "9.9.7"]
delta_xml = ""
if deltas:
    entries = []
    if mode == "future-from":
        deltas = ["9.9.9"]
    for old in deltas:
        name = f"Transcripted9.9.9-{old}.delta"
        if mode == "misnamed" and old == "9.9.7":
            name = "Transcripted-other.delta"
        if not (mode == "missing-file" and old == "9.9.7"):
            with open(os.path.join(updates_dir, name), "wb") as fh:
                fh.write(b"delta")
        signature = "" if mode == "unsigned" and old == "9.9.7" else ' sparkle:edSignature="c2lnLWRlbHRh"'
        # Real generate_appcast resolves the delta URL against the app's
        # SUFeedURL and adds the old Sparkle executable size and locales.
        url = name if old == "9.9.7" else "https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/" + name
        entries.append(
            f'<enclosure url="{url}" sparkle:deltaFrom="{old}" length="1234" '
            f'type="application/octet-stream" sparkle:deltaFromSparkleExecutableSize="861504" '
            f'sparkle:deltaFromSparkleLocales="de,en,fr"{signature}/>'
        )
    delta_xml = "<sparkle:deltas>" + "".join(entries) + "</sparkle:deltas>"

newer_item = ""
if mode == "newer-item":
    newer_item = """<item>
      <title>9.9.10</title>
      <sparkle:version>9.9.10</sparkle:version>
      <sparkle:shortVersionString>9.9.10</sparkle:shortVersionString>
      <enclosure url="Transcripted-9.9.10.dmg" length="510000000" type="application/octet-stream" sparkle:edSignature="c2lnLW5ldw=="/>
    </item>"""

with open(os.path.join(updates_dir, "appcast.xml"), "w") as fh:
    fh.write(f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Transcripted</title>
    <item>
      <title>9.9.9</title>
      <sparkle:version>9.9.9</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <enclosure url="Transcripted-9.9.9.dmg" length="510000000" type="application/octet-stream" sparkle:edSignature="c2lnLWRtZw=="/>
      {delta_xml}
    </item>
    {newer_item}
    <item>
      <title>9.9.8</title>
      <sparkle:version>9.9.8</sparkle:version>
      <sparkle:shortVersionString>9.9.8</sparkle:shortVersionString>
      <enclosure url="Transcripted-9.9.8.dmg" length="509000000" type="application/octet-stream" sparkle:edSignature="c2lnLW9sZA=="/>
    </item>
  </channel>
</rss>
""")
STUB
chmod +x "$stub"

write_plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>$2</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST
}

# Runs the real script against a fresh copy of the committed appcast.
# Usage: run_case <name> <plist-version> [env assignments...]
run_case() {
    local name="$1" plist_version="$2"
    shift 2
    case_dir="$test_root/$name"
    mkdir -p "$case_dir/updates"
    cp "$ROOT_DIR/docs/appcast.xml" "$case_dir/appcast.xml"
    write_plist "$case_dir/Info.plist" "$plist_version"
    env -u SPARKLE_PRIVATE_KEY -u SPARKLE_MAXIMUM_DELTAS \
        SPARKLE_APPCAST_TOOL="$stub" \
        REPO_APPCAST_PATH="$case_dir/appcast.xml" \
        INFO_PLIST_PATH="$case_dir/Info.plist" \
        "$@" \
        bash "$SCRIPT" "$case_dir/updates" > "$case_dir/out.txt" 2>&1
}

expect_failure() {
    local name="$1" plist_version="$2" message="$3"
    shift 3
    if run_case "$name" "$plist_version" "$@"; then
        fail "$name: script accepted a bad release"
    fi
    grep -q -- "$message" "$case_dir/out.txt" || { cat "$case_dir/out.txt" >&2; fail "$name: missing error '$message'"; }
    cmp -s "$ROOT_DIR/docs/appcast.xml" "$case_dir/appcast.xml" || fail "$name: appcast was written despite the failure"
}

# 1. Deltas: URLs point at the release, manifest lists them, history is kept.
run_case deltas 9.9.9 || { cat "$test_root/deltas/out.txt" >&2; fail "deltas: script failed"; }
grep -qx -- "--maximum-deltas" "$case_dir/updates/stub-args.txt" || fail "deltas: --maximum-deltas not passed"
grep -qx "5" "$case_dir/updates/stub-args.txt" || fail "deltas: default of 5 deltas not passed"
python3 - "$ROOT_DIR/docs/appcast.xml" "$case_dir/appcast.xml" "$case_dir/updates/sparkle-deltas.txt" <<'PY'
import sys
import xml.etree.ElementTree as ET

original_path, merged_path, manifest_path = sys.argv[1:4]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
sig = "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
prefix = "https://github.com/r3dbars/transcripted/releases/download/v9.9.9/"

original = ET.parse(original_path).getroot().findall("./channel/item")
items = ET.parse(merged_path).getroot().findall("./channel/item")
assert len(items) == len(original) + 1, "older feed history must be kept"
latest = items[0]
assert latest.findtext("sparkle:shortVersionString", namespaces=ns) == "9.9.9"
enclosure = latest.find("enclosure")
assert enclosure.attrib["url"] == prefix + "Transcripted-9.9.9.dmg", enclosure.attrib["url"]
assert enclosure.attrib[sig]
deltas = latest.findall("sparkle:deltas/enclosure", namespaces=ns)
urls = [delta.attrib["url"] for delta in deltas]
assert urls == [prefix + "Transcripted9.9.9-9.9.8.delta", prefix + "Transcripted9.9.9-9.9.7.delta"], urls
assert all(delta.attrib[sig] for delta in deltas)
size_key = "{http://www.andymatuschak.org/xml-namespaces/sparkle}deltaFromSparkleExecutableSize"
assert all(delta.attrib[size_key] == "861504" for delta in deltas), "Sparkle's extra delta attributes must survive"
assert latest.findtext("sparkle:minimumSystemVersion", namespaces=ns) == "26.0"
assert latest.findtext("sparkle:hardwareRequirements", namespaces=ns) == "arm64"

manifest = open(manifest_path).read().split()
assert manifest == ["Transcripted9.9.9-9.9.8.delta", "Transcripted9.9.9-9.9.7.delta"], manifest

# Text-level readers (ReleaseMetadataContractTests) take the first <enclosure
# in the latest item, which must stay the full DMG, not a delta.
text = open(merged_path).read()
first_item = text[text.index("<item>"):]
first_enclosure = first_item[first_item.index("<enclosure"):]
assert first_enclosure.split(">", 1)[0].count("Transcripted-9.9.9.dmg") == 1
PY

# 2. No deltas: the item has no sparkle:deltas and the manifest is empty.
run_case none 9.9.9 STUB_MODE=none || { cat "$test_root/none/out.txt" >&2; fail "none: script failed"; }
grep -q "sparkle:deltas" "$case_dir/appcast.xml" && fail "none: unexpected sparkle:deltas"
[ ! -s "$case_dir/updates/sparkle-deltas.txt" ] || fail "none: manifest should be empty"
grep -q "No delta updates for 9.9.9" "$case_dir/out.txt" || fail "none: missing no-delta note"

# 3. The EdDSA key goes to the tool on stdin, never on the command line.
run_case key 9.9.9 SPARKLE_PRIVATE_KEY=test-private-key SPARKLE_MAXIMUM_DELTAS=3 \
    || { cat "$test_root/key/out.txt" >&2; fail "key: script failed"; }
grep -q "test-private-key" "$case_dir/updates/stub-args.txt" && fail "key: private key leaked into arguments"
[ "$(cat "$case_dir/updates/stub-stdin.txt")" = "test-private-key" ] || fail "key: private key not sent on stdin"
grep -qx "3" "$case_dir/updates/stub-args.txt" || fail "key: SPARKLE_MAXIMUM_DELTAS not passed through"

# 4. Bad releases stop before docs/appcast.xml is touched.
expect_failure missing-file 9.9.9 "missing from" STUB_MODE=missing-file
expect_failure unsigned 9.9.9 "missing sparkle:edSignature" STUB_MODE=unsigned
expect_failure misnamed 9.9.9 "does not match" STUB_MODE=misnamed
expect_failure future-from 9.9.9 "invalid sparkle:deltaFrom" STUB_MODE=future-from
expect_failure newer-item 9.9.9 "newer than the release" STUB_MODE=newer-item
expect_failure stale-plist 9.9.10 "Info.plist is 9.9.10"
expect_failure bad-count 9.9.9 "SPARKLE_MAXIMUM_DELTAS must be a whole number" SPARKLE_MAXIMUM_DELTAS=five

echo "Sparkle appcast delta tests passed"
