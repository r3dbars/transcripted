// Repo-structure / contract suite, not behavioral coverage.
// It asserts that the audio-reliability automation script exists and still
// names every expected synthetic route lane, keeping the matrix in sync.
// It exercises no runtime audio logic, so it does not cover capture behavior.

import Foundation

func testAudioAutomationCoverageContract() {
    runSuite("Audio automation coverage contract - synthetic matrix names each route lane") {
        let script = readSourceFixture("scripts/ops/daily-audio-reliability-check.sh")

        let expectedSyntheticRows = [
            "synthetic-dictation-pasteback-lifecycle",
            "synthetic-meeting-mic-system-split",
            "synthetic-mic-output-mismatch-diagnostics",
            "synthetic-webrtc-zoom-contention-proxy",
            "synthetic-bluetooth-airpods-route-settling-proxy",
            "synthetic-audio-privacy-security",
            "synthetic-webrtc-shared-mic-system-present",
            "synthetic-webrtc-quiet-mic-recovered",
            "synthetic-zoom-system-audio-missing-after-start",
            "synthetic-zoom-output-ducking-route-change-stop-timeout",
            "synthetic-webrtc-route-switch-stop-restart-recovered",
            "synthetic-webrtc-quiet-mic-unrecovered"
        ]

        for row in expectedSyntheticRows {
            assertTrue(script.contains(row), "synthetic audio matrix should include \(row)")
        }

        assertTrue(
            script.contains("Audio Route Automation Proxy Matrix")
                && script.contains("Deterministic Meeting Route Fixtures")
                && script.contains("synthetic_route_fixture=true")
                && script.contains("simulated_not_real_zoom_webrtc=true")
                && script.contains("manual_boundary_documented=true"),
            "synthetic audio reports should separate automated proxies from manual route proof"
        )

        assertTrue(
            script.contains("restart_artifacts")
                && script.contains("restart_attempted=true")
                && script.contains("restart_succeeded=true"),
            "synthetic route fixtures should include deterministic stop/restart artifacts"
        )
    }

    runSuite("Audio automation coverage contract - issue 500 manual proof stays explicit") {
        let script = readSourceFixture("scripts/ops/daily-audio-reliability-check.sh")
        let issue500 = readSourceFixture("docs/qa-issue-500-meeting-audio.md")
        let qaBench = readSourceFixture("scripts/ops/transcripted-qa-bench.sh")

        for manualProof in ["Safari Meet", "Firefox Meet", "Chrome Meet", "Zoom", "AirPods/Bluetooth"] {
            assertTrue(script.contains(manualProof), "synthetic report should name \(manualProof) as manual proof")
            assertTrue(issue500.contains(manualProof), "issue 500 QA matrix should still include \(manualProof)")
        }

        assertTrue(
            qaBench.contains("Use `docs/qa-issue-500-meeting-audio.md`")
                && qaBench.contains("human proof lanes that require GUI, TCC, hardware, meeting apps, or feel checks"),
            "QA bench should keep route proof in the generated manual scenario packet"
        )
    }

    runSuite("Audio automation coverage contract - Bluetooth route tuple stays named") {
        let script = readSourceFixture("scripts/ops/daily-audio-reliability-check.sh")
        let expectedBluetoothTokens = [
            "mocked connect/disconnect",
            "output-only Bluetooth",
            "built_in_input_to_bluetooth_output",
            "sample-rate settling",
            "route readiness",
            "preferredBuiltInForBluetoothHeadset",
            "builtInFallbackSuppressedForRecoveryAttempt",
            "routeNotSettled",
            "audio_route_not_settled",
            "hfp_suspected"
        ]

        for token in expectedBluetoothTokens {
            assertTrue(script.contains(token), "Bluetooth/AirPods synthetic lane should name \(token)")
        }
    }

    runSuite("Audio automation coverage contract - deterministic E2E smoke keeps saved-artifact source dependencies") {
        // These two sources are pulled in via scripts/entrypoints/lib/shared-smoke-sources.sh's
        // SHARED_TEST_STORAGE_SOURCES array (sourced by run-e2e-smoke.sh), not listed directly
        // in run-e2e-smoke.sh's own SWIFT_SOURCES anymore. A plain concatenated-text search
        // would pass even if the file migrated to the WRONG shared array (e.g.
        // SHARED_PASTEBACK_SUPPORT_SOURCES) or if run-e2e-smoke.sh dropped the array expansion
        // entirely while shared-smoke-sources.sh still listed the file elsewhere — so check the
        // two things independently: (a) run-e2e-smoke.sh actually expands the named array, and
        // (b) the file is a member of THAT specific array's block in shared-smoke-sources.sh.
        let e2eScript = readSourceFixture("scripts/entrypoints/run-e2e-smoke.sh")
        let sharedSourcesScript = readSourceFixture("scripts/entrypoints/lib/shared-smoke-sources.sh")

        let expectedSharedMembers: [(file: String, array: String)] = [
            ("Sources/Meeting/MeetingTranscriptStyler.swift", "SHARED_TEST_STORAGE_SOURCES"),
            ("Sources/Meeting/LocalMeetingSummarizer.swift", "SHARED_TEST_STORAGE_SOURCES")
        ]

        for member in expectedSharedMembers {
            assertTrue(
                e2eScript.contains("${\(member.array)[@]"),
                "run-e2e-smoke.sh should expand \(member.array) so \(member.file) is compiled"
            )

            let arrayBlock = extractShellArrayBlock(sharedSourcesScript, arrayName: member.array)
            assertTrue(
                !arrayBlock.isEmpty,
                "scripts/entrypoints/lib/shared-smoke-sources.sh should define \(member.array)=(...)"
            )
            assertTrue(
                arrayBlock.contains("\"\(member.file)\""),
                "\(member.array) in shared-smoke-sources.sh should list \(member.file), the local summary updater used by meeting transcript styling"
            )
        }
    }
}

/// Extracts the body of a `NAME=(\n ... \n)` bash array literal (as used by
/// scripts/entrypoints/lib/shared-smoke-sources.sh) so callers can check
/// membership in ONE specific array, not the whole file's text — a file
/// listed under a different array must not satisfy a check for this one.
private func extractShellArrayBlock(_ text: String, arrayName: String) -> String {
    guard let openRange = text.range(of: "\(arrayName)=(\n") else { return "" }
    guard let closeRange = text.range(of: "\n)", range: openRange.upperBound..<text.endIndex) else { return "" }
    return String(text[openRange.upperBound..<closeRange.lowerBound])
}
