import Foundation

@MainActor
func testDictationRecordingStartAttempt() async {
    await runSuite("Healthy microphone bypasses activation and its failure window") {
        var events: [String] = []
        let started = await DictationRecordingStartAttempt.run(
            start: { events.append("native_start"); return true },
            onFailure: { events.append("activation"); events.append("500ms_wait") }
        )
        assertTrue(started, "healthy capture succeeds without requiring app activation")
        assertEqual(events, ["native_start"], "no new activation or wait can precede a successful ordinary start")
    }

    await runSuite("A failed microphone start gets recovery before the next attempt") {
        var events: [String] = []
        var nativeResults = [false, true]
        let start: () async -> Bool = {
            let result = nativeResults.removeFirst()
            events.append(result ? "native_success" : "native_failure")
            return result
        }
        let recover: () async -> Void = { events.append("recover") }
        let first = await DictationRecordingStartAttempt.run(start: start, onFailure: recover)
        let retry = await DictationRecordingStartAttempt.run(start: start, onFailure: recover)
        assertFalse(first, "preparing recovery must not manufacture recording success")
        assertTrue(retry, "only actual native success admits recording")
        assertEqual(events, ["native_failure", "recover", "native_success"], "native failure is required before activation recovery")
    }

    await runSuite("Unsuccessful recovery does not become a false successful recording") {
        var recoveries = 0
        let started = await DictationRecordingStartAttempt.run(
            start: { false }, onFailure: { recoveries += 1 }
        )
        assertFalse(started, "caller retains ownership of bounded retry/timeout policy")
        assertEqual(recoveries, 1, "one failure notification per completed failed attempt")
    }

    await runSuite("Release while native start is pending cannot activate on late failure") {
        var recovered = false
        let task = Task { @MainActor in
            await DictationRecordingStartAttempt.run(
                start: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false // native work may finish after cancellation
                },
                onFailure: { recovered = true }
            )
        }
        let started = await task.value
        assertFalse(started, "cancelled failure stays failed")
        assertFalse(recovered, "late native failure cannot activate after release")
    }

    await runSuite("Late native success is returned so the cancelled caller can stop it") {
        var recovered = false
        let task = Task { @MainActor in
            await DictationRecordingStartAttempt.run(
                start: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                onFailure: { recovered = true }
            )
        }
        let started = await task.value
        assertTrue(started, "do not hide a real recording that cancellation cleanup must stop")
        assertFalse(recovered, "a success must never invoke focus recovery")
    }

    await runSuite("Cancelled queued attempt neither opens mic nor changes focus") {
        var events: [String] = []
        let task = Task { @MainActor in
            await DictationRecordingStartAttempt.run(
                start: { events.append("mic"); return true },
                onFailure: { events.append("activate") }
            )
        }
        task.cancel()
        let started = await task.value
        assertFalse(started, "cancelled queued work stays cancelled")
        assertTrue(events.isEmpty, "neither native work nor activation is admitted")
    }

    await runSuite("Existing callers without focus recovery preserve native failure") {
        let started = await DictationRecordingStartAttempt.run(start: { false })
        assertFalse(started, "optional recovery cannot change existing start-result semantics")
    }

    await runSuite("A native start reports the open, then the route wait when it fails") {
        var events: [String] = []
        let started = await DictationNativeMicrophoneStart.run(
            isRecoveryAttempt: false,
            isCurrentSession: { true },
            onStartStageChanged: { events.append($0.rawValue) },
            onStartFailed: { events.append("recover") },
            startRecording: { events.append("ordinary_start"); return false },
            startRecordingRecoveryAttempt: { events.append("recovery_start"); return true }
        )
        assertFalse(started, "a failed open is reported as failed")
        assertEqual(
            events,
            ["opening_microphone", "ordinary_start", "waiting_for_audio_route", "recover"],
            "the stage names the open, a failure moves it to the route wait, and only then is focus recovery offered"
        )
    }

    await runSuite("The recovery loop's forced attempt uses the recovery start") {
        var events: [String] = []
        let started = await DictationNativeMicrophoneStart.run(
            isRecoveryAttempt: true,
            isCurrentSession: { true },
            onStartStageChanged: { events.append($0.rawValue) },
            onStartFailed: { events.append("recover") },
            startRecording: { events.append("ordinary_start"); return false },
            startRecordingRecoveryAttempt: { events.append("recovery_start"); return true }
        )
        assertTrue(started, "the forced recovery start's own result is returned")
        assertEqual(events, ["opening_microphone", "recovery_start"], "a successful open never offers focus recovery")
    }

    await runSuite("A start the session no longer owns reports no stages") {
        var stages: [String] = []
        var recovered = false
        let started = await DictationNativeMicrophoneStart.run(
            isRecoveryAttempt: false,
            isCurrentSession: { false },
            onStartStageChanged: { stages.append($0.rawValue) },
            onStartFailed: { recovered = true },
            startRecording: { false },
            startRecordingRecoveryAttempt: { true }
        )
        assertFalse(started, "the open's result still comes back")
        assertEqual(stages, [], "a stale start can't move the stage of the session now running")
        assertTrue(recovered, "the recovery decision itself is the gate's, keyed on the session id")
    }

    runSuite("Focus recovery is offered at most once per session") {
        var gate = DictationStartActivationRecoveryGate()
        let session = UUID()
        assertTrue(admit(&gate, session: session), "the first failed background hotkey start may try the handshake")
        assertFalse(admit(&gate, session: session), "a second failure in the same session doesn't activate again")
        assertFalse(admit(&gate, session: session), "nor a third")
    }

    runSuite("Each new session gets its own recovery chance") {
        var gate = DictationStartActivationRecoveryGate()
        let first = UUID()
        let second = UUID()
        assertTrue(admit(&gate, session: first), "first session recovers once")
        assertTrue(admit(&gate, session: second), "the next session isn't blocked by the last one's attempt")
        assertFalse(admit(&gate, session: second), "and it gets only one too")
    }

    runSuite("Focus recovery is refused outside a failed background hotkey start") {
        let session = UUID()
        var gate = DictationStartActivationRecoveryGate()
        assertFalse(admit(&gate, session: session, current: UUID()), "a late failure from a superseded session")
        assertFalse(admit(&gate, session: session, isDictating: false), "the session already ended")
        assertFalse(admit(&gate, session: session, isCancelled: true), "the start was cancelled (key released)")
        assertFalse(admit(&gate, session: session, appIsActive: true), "Transcripted is already frontmost")
        assertFalse(admit(&gate, session: session, allowsEscalation: false), "a menu or overlay start never steals focus")
        assertFalse(admit(&gate, session: session, usesMeetingMic: true), "dictation borrowing the meeting mic has nothing to activate")
        assertTrue(admit(&gate, session: session), "none of those refusals used up the session's one chance")
    }
}

private func admit(
    _ gate: inout DictationStartActivationRecoveryGate,
    session: UUID,
    current: UUID? = nil,
    isDictating: Bool = true,
    isCancelled: Bool = false,
    appIsActive: Bool = false,
    allowsEscalation: Bool = true,
    usesMeetingMic: Bool = false
) -> Bool {
    gate.admit(
        sessionID: session,
        currentSessionID: current ?? session,
        isDictating: isDictating,
        isCancelled: isCancelled,
        appIsActive: appIsActive,
        allowsEscalation: allowsEscalation,
        usesMeetingMic: { usesMeetingMic }
    )
}
