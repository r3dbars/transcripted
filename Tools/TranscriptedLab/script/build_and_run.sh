#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="debug"
VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
Usage: Tools/TranscriptedLab/script/build_and_run.sh [--release] [--verify]

Builds TranscriptedLab + transcripted-lab, creates a local app bundle, ad-hoc
signs it, and opens it unless --verify is supplied.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIGURATION="release"; shift ;;
    --verify) VERIFY_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

swift build --package-path "$TOOL_ROOT" -c "$CONFIGURATION" --product TranscriptedLab
swift build --package-path "$TOOL_ROOT" -c "$CONFIGURATION" --product transcripted-lab
BIN_DIR="$(swift build --package-path "$TOOL_ROOT" -c "$CONFIGURATION" --show-bin-path)"

DIST="$TOOL_ROOT/dist"
APP="$DIST/Transcripted Lab.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
cp "$BIN_DIR/TranscriptedLab" "$CONTENTS/MacOS/TranscriptedLab"
cp "$BIN_DIR/transcripted-lab" "$CONTENTS/Helpers/transcripted-lab"
chmod +x "$CONTENTS/MacOS/TranscriptedLab" "$CONTENTS/Helpers/transcripted-lab"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Transcripted Lab</string>
  <key>CFBundleExecutable</key>
  <string>TranscriptedLab</string>
  <key>CFBundleIdentifier</key>
  <string>com.r3dbars.transcripted-lab</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Transcripted Lab</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

printf 'Built %s\n' "$APP"
if [[ "$VERIFY_ONLY" -eq 0 ]]; then
  open "$APP"
fi
