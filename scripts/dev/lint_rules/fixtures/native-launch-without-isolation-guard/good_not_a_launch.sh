# lint-fixture-path: scripts/release/check-binary.sh
#!/bin/bash
# /usr/bin/open build/Transcripted.app   <- a comment, not a launch
APP_BINARY="build/Transcripted.app/Contents/MacOS/Transcripted"
LAB_APP="build/TranscriptedLab.app"
codesign --verify "$APP_BINARY"
dsymutil "$APP_BINARY" -o out.dSYM
pgrep -f "Transcripted.app/Contents/MacOS/Transcripted" >/dev/null || true
open "$LAB_APP"
echo "launch with: open build/Transcripted.app"
