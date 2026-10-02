// The start-funnel telemetry promises: `dictation_started` only after the
// microphone open succeeds, `dictation_start_requested` before the session
// exists, and terminal warmup outcomes kept in the attempt denominator.
// Tested through the start-path seams the controller runs.

import Foundation

@MainActor
func testDictationStartedTelemetryContract() async {
    await runSuite("dictation_started is counted only after the microphone open succeeds") {
        var events: [String] = []
        let outcome = await DictationFastStart.run(fastStartSteps(opens: false, into: { events.append($0) }))
        assertEqual(outcome, .fellBackToWait, "a failed open falls back to the recovery wait")
        assertEqual(events, ["open", "fall back"], "nothing counts a start the open didn't make")

        events = []
        let started = await DictationFastStart.run(fastStartSteps(opens: true, into: { events.append($0) }))
        assertEqual(started, .started, "a successful open starts recording")
        assertEqual(events, ["open", "started"], "the success tail runs once, after the open")
    }

    await runSuite("A late open after the user let go is stopped, not counted") {
        var events: [String] = []
        var steps = fastStartSteps(opens: true, into: { events.append($0) })
        steps.isStillWanted = { false }
        let outcome = await DictationFastStart.run(steps)
        assertEqual(outcome, .abandoned, "the session ended while the open was in flight")
        assertEqual(events, ["open", "stop late recording"], "the mic doesn't stay open and no start is counted")

        events = []
        var failed = fastStartSteps(opens: false, into: { events.append($0) })
        failed.isStillWanted = { false }
        _ = await DictationFastStart.run(failed)
        assertEqual(events, ["open"], "a late failure doesn't start a wait nobody asked for")
    }

    runSuite("Every successful start counts dictation_started and drops its start handle") {
        var events: [String] = []
        DictationRecordingStarted.finish(DictationRecordingStarted.Steps(
            clearStartHandle: { events.append("clear handle") },
            recordStarted: { events.append("dictation_started") },
            playStartCue: { events.append("cue") },
            installSessionTimeout: { events.append("timeout") }
        ))
        assertEqual(
            events,
            ["clear handle", "dictation_started", "cue", "timeout"],
            "a stale handle would make a Push to Talk release during a device recovery read as cancel-pending-start and discard kept audio"
        )
    }

    runSuite("dictation_start_requested is counted before the session id exists") {
        var events: [String] = []
        let admitted = DictationStartAdmission.decide(admissionSteps(into: { events.append($0) }))
        assertEqual(admitted, .admitted, "an ordinary press is admitted")
        assertEqual(
            events,
            ["count request", "begin session"],
            "counted first, or the attempt event borrows the previous session's id"
        )

        events = []
        var refused = admissionSteps(into: { events.append($0) })
        refused.previousTakeIsTranscribing = { true }
        _ = DictationStartAdmission.decide(refused)
        assertEqual(
            events,
            ["count request", "count refusal previous_dictation_transcribing"],
            "a refused press is counted but never gets a session of its own"
        )
    }

    runSuite("dictation_start_failed includes terminal model warmup outcomes") {
        assertEqual(
            DictationSession.ModelWarmupOutcome.failed("disk full").startFailureKind,
            "model_load_failed",
            "a failed foreground model load must remain in the dictation attempt denominator"
        )
        assertEqual(
            DictationSession.ModelWarmupOutcome.timedOut.startFailureKind,
            "model_load_timeout",
            "a timed-out foreground model load must remain in the dictation attempt denominator"
        )
        assertNil(DictationSession.ModelWarmupOutcome.ready.startFailureKind, "a ready model goes on to open the mic")
        assertNil(
            DictationSession.ModelWarmupOutcome.aborted.startFailureKind,
            "an aborted wait was ended elsewhere, which already reported it"
        )
    }

    // Still source-text, deliberately: these are the controller's own call
    // sites, and DictationSessionController can't be built in the fast
    // runner. The counting rules themselves are behavior tests above and in
    // DictationStartAdmissionTests / DictationQueuedStartPolicyTests.
    let source = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")

    runSuite("The controller wires the real start events into admission") {
        let start = sourceSlice(source, from: "func startDictation(", to: "private func recordDictationStarted")
        let countRequest = sourceSlice(start, from: "countRequest:", to: "blocksNewCapture:")
        assertTrue(countRequest.contains("trackDictationStartRequested("),
                   "admission's request count must be the real dictation_start_requested event")
        let countRefusal = sourceSlice(start, from: "countRefusal:", to: "beginSession:")
        assertTrue(countRefusal.contains("trackDictationStartRefused(") && countRefusal.contains("failureKind: refusal.rawValue"),
                   "each refusal must be reported with its own failure kind")
        let beginSession = sourceSlice(start, from: "beginSession:", to: "guard admission == .admitted")
        assertTrue(beginSession.contains("currentDictationSessionID = UUID()"),
                   "the session id is minted by admission, after the request was counted")
    }

    // "Internal restart paths are marked as retries" counted the
    // `.startDictation(` calls in DictationSessionController.swift. Those
    // Try Again actions now sit in the DictationSessionController+*.swift
    // extensions, so the count went with the split instead of being re-pinned.
}

@MainActor
private func fastStartSteps(opens: Bool, into record: @escaping @MainActor (String) -> Void) -> DictationFastStart.Steps {
    DictationFastStart.Steps(
        openMicrophone: { record("open"); return opens },
        isStillWanted: { true },
        stopLateRecording: { record("stop late recording") },
        started: { record("started") },
        fallBackToWait: { record("fall back") }
    )
}

@MainActor
private func admissionSteps(into record: @escaping @MainActor (String) -> Void) -> DictationStartAdmission.Steps {
    DictationStartAdmission.Steps(
        isDictating: { false },
        rememberPressIfFinishing: { false },
        showStartingIsland: {},
        countRequest: { record("count request") },
        blocksNewCapture: { false },
        previousTakeIsTranscribing: { false },
        unavailableReason: { nil },
        countRefusal: { record("count refusal \($0.rawValue)") },
        beginSession: { record("begin session") }
    )
}

private func sourceSlice(_ source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return ""
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}
