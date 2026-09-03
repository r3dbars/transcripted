// DictationSessionController cannot be instantiated in the fast-test runner,
// so pin the source-level placement of the successful-start telemetry here.

import Foundation

func testDictationStartedTelemetryContract() {
    let source = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")

    runSuite("dictation_started is emitted only after microphone capture succeeds") {
        let call = "recordDictationStarted(appState: appState, trigger:"
        let callCount = source.components(separatedBy: call).count - 1

        assertEqual(
            callCount,
            2,
            "the success event should be emitted once from the fast path and once from the recovery path"
        )

        let permissionGate = sourceSlice(
            source,
            from: "switch TranscriptedPermissionAccess.microphoneAuthorizationStatus()",
            to: "private func recordDictationStarted"
        )
        assertFalse(
            permissionGate.contains("recordDictationStarted"),
            "microphone permission alone must not count as a successful dictation start"
        )

        let fastPath = sourceSlice(
            source,
            from: "if started {",
            to: "} else {"
        )
        assertTrue(
            fastPath.contains("recordDictationStarted"),
            "the ready-engine path should emit success after the audio engine reports that recording started"
        )

        let recoveryPath = sourceSlice(
            source,
            from: "case .started:",
            to: "case .timedOut"
        )
        assertTrue(
            recoveryPath.contains("recordDictationStarted"),
            "the recovery path should emit success only after a start attempt returns started"
        )
    }

    runSuite("dictation_start_failed includes terminal model warmup outcomes") {
        let failedWarmup = sourceSlice(
            source,
            from: "case .failed(let message):",
            to: "case .timedOut:"
        )
        assertTrue(
            failedWarmup.contains("trackDictationStartFailed(\"model_load_failed\")"),
            "a failed foreground model load must remain in the dictation attempt denominator"
        )

        let timedOutWarmup = sourceSlice(
            source,
            from: "case .timedOut:",
            to: "case .aborted:"
        )
        assertTrue(
            timedOutWarmup.contains("trackDictationStartFailed(\"model_load_timeout\")"),
            "a timed-out foreground model load must remain in the dictation attempt denominator"
        )
    }
}

private func sourceSlice(_ source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return ""
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}
