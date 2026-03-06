#!/bin/bash
# run-tests.sh — Compile and run Draft's test suite
# Only compiles the source files needed by tests (no SwiftUI, Combine, FluidAudio, etc.)

set -e

echo "Compiling tests..."

swiftc \
    Tests/TestHelpers.swift \
    Tests/TestRunner.swift \
    Tests/CapturedContextTests.swift \
    Tests/PlatformFormatterTests.swift \
    Tests/RefusalDetectionTests.swift \
    Tests/MessageFilterTests.swift \
    Tests/StyleUtilsTests.swift \
    Tests/InsightCardTests.swift \
    Tests/IsRetryableTests.swift \
    Sources/Capture/CapturedContext.swift \
    Sources/Draft/PlatformFormatter.swift \
    Sources/Draft/DraftUtils.swift \
    Sources/Messages/MessageFilter.swift \
    Sources/Style/StyleUtils.swift \
    Sources/Analysis/InsightCard.swift \
    Sources/API/AnthropicAPITypes.swift \
    -framework AppKit \
    -parse-as-library \
    -o build/tests \
    2>&1

echo "Running tests..."
echo ""
./build/tests
