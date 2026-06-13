import Foundation

func testCIWorkflowContract() {
    let swiftCI = (try? String(contentsOf: repoFixtureURL(".github/workflows/swift-ci.yml"), encoding: .utf8)) ?? ""

    runSuite("CI workflow contract - swift-ci stays a blocking gate") {
        assertFalse(swiftCI.isEmpty, ".github/workflows/swift-ci.yml should be readable from the repo root")
        assertFalse(
            swiftCI.contains("continue-on-error: true"),
            "swift-ci must not be continue-on-error — it is a required, blocking gate"
        )
    }

    runSuite("CI workflow contract - swift-ci verifies merged main") {
        assertTrue(
            swiftCI.contains("push:") && swiftCI.contains("branches: [main]"),
            "swift-ci should run on pushes to main so merged code is verified"
        )
        assertTrue(swiftCI.contains("pull_request:"), "swift-ci should keep the pull_request trigger")
        assertTrue(swiftCI.contains("workflow_dispatch:"), "swift-ci should keep the manual dispatch trigger")
    }

    runSuite("CI workflow contract - swift-ci runs the full suite") {
        assertTrue(swiftCI.contains("bash run-tests.sh"), "swift-ci should keep running the fast tests")
        assertTrue(swiftCI.contains("swift test\n"), "swift-ci should keep running the Core package tests")
        assertTrue(swiftCI.contains("run-integration-smoke.sh"), "swift-ci should run the integration smoke")
        assertTrue(swiftCI.contains("run-e2e-smoke.sh"), "swift-ci should run the E2E smoke")
        for package in [
            "Tools/TranscriptedCaptureKit",
            "Tools/TranscriptedCLI",
            "Tools/TranscriptedMCP",
            "Tools/TranscriptedQA"
        ] {
            assertTrue(
                swiftCI.contains("swift test --package-path \(package)"),
                "swift-ci should run the Tools package tests for \(package)"
            )
        }
    }

    runSuite("CI workflow contract - launch smoke is no longer skipped") {
        // The launch smoke runs on hosted runners now, so the skip env must be
        // gone. The only allowed skip env is the wall-clock timing one (the
        // clipboard timing proofs are locked down by the marker count below).
        assertFalse(
            swiftCI.contains("TRANSCRIPTED_SKIP_LAUNCH_SMOKE"),
            "swift-ci should run build.sh's launch smoke, not skip it"
        )

        let skipEnvVars = Set(
            swiftCI
                .components(separatedBy: CharacterSet(charactersIn: " \t\n:=\"'"))
                .filter { $0.hasPrefix("TRANSCRIPTED_SKIP_") }
        )
        assertEqual(
            skipEnvVars,
            ["TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS"],
            "the only skip env var in swift-ci should be TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS so new silent skips cannot creep in"
        )
    }

    runSuite("CI workflow contract - clipboard timing skip set stays locked") {
        let clipboardTests = (try? String(
            contentsOf: repoFixtureURL("Tests/ClipboardRestoringTextPasterTests.swift"),
            encoding: .utf8
        )) ?? ""
        assertFalse(clipboardTests.isEmpty, "ClipboardRestoringTextPasterTests.swift should be readable")

        // Each timing-sensitive proof guards an early SKIPPED return on the
        // TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS env. Lock the count so the
        // env-skipped set cannot quietly grow.
        let guardCount = occurrences(
            of: "if ProcessInfo.processInfo.environment[\"TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS\"] == \"1\" {",
            in: clipboardTests
        )
        let skipMarkerCount = occurrences(of: "    SKIPPED: wall-clock timing proof", in: clipboardTests)

        assertEqual(guardCount, 3, "exactly three clipboard timing proofs should guard on the timing-skip env")
        assertEqual(skipMarkerCount, 3, "exactly three clipboard timing proofs should print a SKIPPED marker")
    }
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = found.upperBound..<haystack.endIndex
    }
    return count
}
