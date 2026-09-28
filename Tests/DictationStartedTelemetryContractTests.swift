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

    // Counting a press before any guard can refuse it, not counting a press
    // while already dictating or queued behind a finishing take, and each guard
    // reporting its own reason are behavior tests now in
    // DictationStartAdmissionTests.swift. What stays here is the controller's
    // wiring: admission runs before the session id is minted.
    runSuite("dictation_start_requested is emitted before the session id exists") {
        let start = sourceSlice(source, from: "func startDictation(", to: "private func recordDictationStarted")

        let admission = start.range(of: "DictationStartAdmission.decide(")
        let newSession = start.range(of: "currentDictationSessionID = UUID()")

        assertTrue(admission != nil && newSession != nil, "startDictation should decide admission and mint a session")
        if let admission, let newSession {
            assertTrue(
                admission.lowerBound < newSession.lowerBound,
                "the attempt event must fire before the session UUID is minted, or it borrows the previous session's id"
            )
        }

        // One definition, the startDictation call, and the one in
        // dropQueuedDictationStart. A press remembered while the last take
        // finishes returns before the startDictation call, so it is counted
        // either when it starts (through startDictation) or when it is dropped,
        // never both.
        assertEqual(
            source.components(separatedBy: "trackDictationStartRequested(").count - 1,
            3,
            "one definition and exactly two call sites — another emission would double-count attempts"
        )
        let drop = sourceSlice(source, from: "private func dropQueuedDictationStart(", to: "private func clearQueuedStartNotice")
        assertTrue(
            drop.contains("trackDictationStartRequested(") && drop.contains("failureKind: \"previous_dictation_transcribing\""),
            "a remembered press that never starts is still a refused request, as it was before it was remembered"
        )
    }

    // "guard-refused start requests report their own failure kind" is a
    // behavior test now: "Each guard that refuses reports its own reason" in
    // DictationStartAdmissionTests.swift.

    runSuite("internal restart paths are marked as retries") {
        let internalCalls = Array(source.components(separatedBy: ".startDictation(").dropFirst())

        // Nine: the eight error-alert restart affordances, plus the start of a
        // press remembered while the last take finished. That one is the
        // user's own press, so it passes the press's own flag through.
        assertEqual(
            internalCalls.count,
            9,
            "the error-alert restart affordances in this file plus the remembered press; update this count deliberately, not to make the suite pass"
        )
        for call in internalCalls {
            let arguments = call.components(separatedBy: ")").first ?? ""
            if arguments.contains("isRetry: request.isRetry") { continue }
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
