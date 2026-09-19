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

    runSuite("dictation_start_requested is emitted before anything can refuse the start") {
        let start = sourceSlice(source, from: "func startDictation(", to: "private func recordDictationStarted")

        let requested = start.range(of: "trackDictationStartRequested(")
        let admission = start.range(of: "DictationTerminationAdmissionPolicy.blocksNewCapture(")
        let newSession = start.range(of: "currentDictationSessionID = UUID()")

        assertTrue(requested != nil, "the attempt denominator must be emitted from startDictation")
        assertTrue(admission != nil && newSession != nil, "startDictation should still gate and mint a session")
        if let requested, let admission, let newSession {
            assertTrue(
                requested.lowerBound < admission.lowerBound,
                "a start refused by the admission guards is still a start the user asked for"
            )
            assertTrue(
                requested.lowerBound < newSession.lowerBound,
                "the attempt event must fire before the session UUID is minted, or it borrows the previous session's id"
            )
        }

        assertEqual(
            source.components(separatedBy: "trackDictationStartRequested(").count - 1,
            2,
            "one definition and exactly one call site — a second emission would double-count attempts"
        )
    }

    runSuite("guard-refused start requests report their own failure kind") {
        let start = sourceSlice(source, from: "func startDictation(", to: "private func recordDictationStarted")

        assertEqual(
            start.components(separatedBy: "trackDictationStartRefused(").count - 1,
            3,
            "each of the three admission guards should report the request it refused"
        )
        for failureKind in [
            "unsaved_capture_recovery_pending",
            "previous_dictation_transcribing",
            "dictation_unavailable",
        ] {
            assertTrue(
                start.contains("failureKind: \"\(failureKind)\""),
                "\(failureKind) should be a named refusal rather than a silent return"
            )
        }
    }

    runSuite("internal restart paths are marked as retries") {
        let internalCalls = Array(source.components(separatedBy: ".startDictation(").dropFirst())

        assertEqual(
            internalCalls.count,
            8,
            "the error-alert restart affordances in this file; update this count deliberately, not to make the suite pass"
        )
        for call in internalCalls {
            let arguments = call.components(separatedBy: ")").first ?? ""
            assertTrue(
                arguments.contains("isRetry: true"),
                "a restart from a Try Again action must be marked, or four taps read as five independent attempts"
            )
        }
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
