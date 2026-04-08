#!/bin/bash
# run-tests.sh — Compile and run Draft's test suite
# Only compiles the source files needed by tests (no SwiftUI, Combine, FluidAudio, etc.)

set -e

echo "Compiling tests..."
mkdir -p build

swiftc \
    Tests/TestHelpers.swift \
    Tests/TestRunner.swift \
    Tests/CapturedContextTests.swift \
    Tests/RefusalDetectionTests.swift \
    Tests/StyleUtilsTests.swift \
    Tests/DiffSummaryTests.swift \
    Tests/MeetingTranscriptStylerTests.swift \
    Tests/DictationTranscriptWriterTests.swift \
    Tests/DictationSoundsTests.swift \
    Sources/Capture/CapturedContext.swift \
    Sources/Draft/DraftUtils.swift \
    Sources/Style/StyleUtils.swift \
    Sources/DraftPaths.swift \
    Sources/Dictation/DictationStoragePaths.swift \
    Sources/Dictation/DictationTranscriptWriter.swift \
    Sources/DraftConstants.swift \
    Sources/Draft/DiffSummary.swift \
    Sources/Meeting/MeetingTranscriptStyler.swift \
    Sources/UI/AppSoundPlayer.swift \
    -framework AppKit \
    -parse-as-library \
    -o build/tests \
    2>&1

echo "Running tests..."
echo ""
./build/tests
