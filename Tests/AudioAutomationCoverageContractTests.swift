import Foundation

func testAudioAutomationCoverageContract() {
    runSuite("Audio automation coverage contract - synthetic matrix names each route lane") {
        let script = readAudioAutomationContractFile("scripts/ops/daily-audio-reliability-check.sh")

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
    }

    runSuite("Audio automation coverage contract - issue 500 manual proof stays explicit") {
        let script = readAudioAutomationContractFile("scripts/ops/daily-audio-reliability-check.sh")
        let issue500 = readAudioAutomationContractFile("docs/qa-issue-500-meeting-audio.md")
        let qaBench = readAudioAutomationContractFile("scripts/ops/transcripted-qa-bench.sh")

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

    runSuite("Audio automation coverage contract - deterministic E2E smoke keeps saved-artifact source dependencies") {
        let e2e = readAudioAutomationContractFile("scripts/entrypoints/run-e2e-smoke.sh")

        assertTrue(
            e2e.contains("Sources/Meeting/MeetingTranscriptStyler.swift")
                && e2e.contains("Sources/Meeting/LocalMeetingSummarizer.swift"),
            "E2E smoke should compile the local summary updater used by meeting transcript styling"
        )
    }
}

private func readAudioAutomationContractFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
