import AppKit
import Foundation

@MainActor
func testMeetingSessionUIPolicy() async {
    runSuite("Meeting route warning publisher sequence — a reset permits the same outcome in the next recording") {
        // This is the optional publisher sequence used by the controller:
        // removeDuplicates runs before compactMap so nil resets the latch.
        let outcomeSequence: [String?] = [
            String?(nil),
            "switched_to_built_in",
            String?(nil),
            "switched_to_built_in",
            "switched_to_built_in",
        ]
        var deduplicated: [String?] = []
        var hasPreviousOutcome = false
        var previousOutcome: String?
        for outcome in outcomeSequence {
            if !hasPreviousOutcome || previousOutcome != outcome {
                deduplicated.append(outcome)
            }
            previousOutcome = outcome
            hasPreviousOutcome = true
        }
        let deliveredOutcomes = deduplicated.compactMap { $0 }

        assertEqual(
            deliveredOutcomes,
            ["switched_to_built_in", "switched_to_built_in"],
            "the nil reset must separate identical warning outcomes across recordings"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldShowTranscribing — ignores speaker review without real pipeline work") {
        assertFalse(
            MeetingSessionUIPolicy.shouldShowTranscribing(
                activeTranscriptions: 0,
                queuedTranscriptions: 0
            ),
            "speaker review alone should not keep the meeting overlay in the saving state"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldShowTranscribing — stays active while a transcription is running") {
        assertTrue(
            MeetingSessionUIPolicy.shouldShowTranscribing(
                activeTranscriptions: 1,
                queuedTranscriptions: 0
            ),
            "an active transcription should keep the saving state visible"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldShowTranscribing — stays active while work is queued") {
        assertTrue(
            MeetingSessionUIPolicy.shouldShowTranscribing(
                activeTranscriptions: 0,
                queuedTranscriptions: 1
            ),
            "queued meeting work should keep the saving state visible until it starts"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — speaker review does not block next meeting") {
        assertTrue(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isPreparingQueuedTranscriptionStart: false
            ),
            "speaker review should stay open while the next queued meeting starts"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — starts when no pipeline is active") {
        assertTrue(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isPreparingQueuedTranscriptionStart: false
            ),
            "a queued meeting should start as soon as prior transcription work clears"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — blocks duplicate starts") {
        assertFalse(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 1,
                isPreparingQueuedTranscriptionStart: false
            ),
            "active transcription work should remain single-flight"
        )
        assertFalse(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isPreparingQueuedTranscriptionStart: true
            ),
            "a queued start already being prepared should not be started twice"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork — waits for terminal status") {
        assertFalse(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
                hasTerminalOutcome: false
            ),
            "the trigger should survive if active work clears before the saved/failed status arrives"
        )
        assertTrue(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
                hasTerminalOutcome: true
            ),
            "the trigger can clear once terminal telemetry has a status to report"
        )
        assertFalse(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
                hasTerminalOutcome: true,
                hasSpeakerReviewWork: true
            ),
            "saved meeting trigger attribution should survive until speaker review finalization reports its own outcome"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — nil titles stay nil") {
        assertNil(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: nil,
                calendarTitle: nil
            ),
            "untitled manual starts should stay untitled instead of inventing metadata"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — explicit prompt title wins over calendar fallback") {
        assertEqual(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: "Prompt Title",
                calendarTitle: "Calendar Title"
            ),
            "Prompt Title",
            "explicit prompt context should not be overwritten by a later calendar lookup"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — manual starts can use the calendar title") {
        assertEqual(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: nil,
                calendarTitle: "Transcripted Calendar Smoke Live"
            ),
            "Transcripted Calendar Smoke Live",
            "manual, menu, and hotkey starts should still get the active calendar event title"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — blank titles are ignored") {
        assertEqual(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: " \n ",
                calendarTitle: "Calendar Title"
            ),
            "Calendar Title",
            "blank prompt titles should not block the calendar fallback"
        )
        assertNil(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: nil,
                calendarTitle: " \r\n "
            ),
            "blank calendar titles should not become transcript titles"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — multiline titles normalize before save") {
        assertEqual(
            MeetingRecordingTitlePolicy.normalized("  Product sync\r\nFollow-up  "),
            "Product sync  Follow-up",
            "transcript titles should be single-line and trimmed before persistence"
        )
    }

    runSuite("Meeting capture hears sleep and wake on the workspace center") {
        assertTrue(
            MeetingSleepWakeNotificationSource.center === NSWorkspace.shared.notificationCenter,
            "macOS posts sleep/wake on the workspace center, so capture must listen there"
        )
        assertFalse(
            MeetingSleepWakeNotificationSource.center === NotificationCenter.default,
            "the default center never sees workspace sleep/wake"
        )
        assertEqual(
            MeetingSleepWakeNotificationSource.willSleepName,
            NSWorkspace.willSleepNotification,
            "capture pauses on the real will-sleep notification"
        )
        assertEqual(
            MeetingSleepWakeNotificationSource.didWakeName,
            NSWorkspace.didWakeNotification,
            "capture resumes on the real did-wake notification"
        )
    }

    await runSuite("An unexpected capture stop leaves recording before any await") {
        let capture = StopSequenceCaptureFake()
        var state = MeetingSessionState.recording
        // What a Stop or Cancel arriving during the first suspension would see.
        var stateSeenAtFirstAwait: MeetingSessionState?
        capture.onFlush = { stateSeenAtFirstAwait = state }

        let handled = await MeetingStopSequence.unexpectedStop(
            state: state,
            transition: { to, reason in
                state = to
                capture.events.append("transition:\(reason)")
            },
            quietLiveWarnings: { capture.events.append("quiet") },
            capture: capture,
            clearRelay: { capture.events.append("clear_relay") },
            resumeDictation: { capture.events.append("resume_dictation") }
        )

        assertTrue(handled, "a capture that ends on its own while recording is an unexpected stop")
        assertEqual(state, .stoppingRecording)
        assertEqual(
            stateSeenAtFirstAwait,
            .stoppingRecording,
            "stop/cancel need .recording, so leaving it before the first await keeps them from interleaving"
        )
        assertEqual(
            capture.events,
            ["transition:unexpected_capture_stop", "quiet", "flush", "clear_relay", "resume_dictation"],
            "leave recording, drain the shared relay, then hand the mic back to dictation"
        )
    }

    await runSuite("A capture stop the app already asked for is not an unexpected stop") {
        let notRecording: [MeetingSessionState] = [.stoppingRecording, .startingRecording, .transcribing, .ready, .idle, .error("synthetic")]
        for current in notRecording {
            let capture = StopSequenceCaptureFake()
            let handled = await MeetingStopSequence.unexpectedStop(
                state: current,
                transition: { _, _ in capture.events.append("transition") },
                quietLiveWarnings: { capture.events.append("quiet") },
                capture: capture,
                clearRelay: { capture.events.append("clear_relay") },
                resumeDictation: { capture.events.append("resume_dictation") }
            )
            assertFalse(handled, "\(current) means stop/cancel/termination already owns teardown")
            assertEqual(capture.events, [], "\(current) must not transition or touch the relay")
        }
    }

    runSuite("Capture health evidence comes from this capture, not a cached permission") {
        let capture = StopSequenceCaptureFake()
        assertEqual(
            MeetingCaptureHealthEvidence.make(capture: capture),
            MeetingCaptureHealthEvidence(
                systemAudioSignalVerified: false,
                systemAudioFinalizationFailed: false,
                systemAudioPermissionRecoveryNeeded: false
            ),
            "no PCM yet means unverified, and no typed denial means no grant button"
        )

        capture.hasObservedSystemAudioSignal = true
        capture.systemAudioFinalizationFailed = true
        let healthy = MeetingCaptureHealthEvidence.make(capture: capture)
        assertTrue(healthy.systemAudioSignalVerified, "the warning resolves once this capture hears system audio")
        assertTrue(healthy.systemAudioFinalizationFailed, "saved health keeps a failure found while draining the tail")
        assertFalse(healthy.systemAudioPermissionRecoveryNeeded)

        capture.hasObservedSystemAudioSignal = false
        capture.systemAudioStartPermissionExplicitlyDenied = true
        let denied = MeetingCaptureHealthEvidence.make(capture: capture)
        assertTrue(denied.systemAudioPermissionRecoveryNeeded, "a typed macOS denial offers the grant action")
        assertFalse(denied.systemAudioSignalVerified, "a denial never counts as heard audio")
    }

    runSuite("A Record request is turned away while a capture is starting, recording, or stopping") {
        let active: [MeetingSessionState] = [.startingRecording, .recording, .stoppingRecording]
        for state in active {
            let admission = MeetingSessionStateMachine.startAdmission(startCallInFlight: false, state: state)
            assertEqual(admission, .ignoredActiveCapture, "\(state) already owns the capture")
            assertFalse(admission.acceptsRecord, "an active capture must not count as an accepted Record (\(state))")
        }

        let free: [MeetingSessionState] = [.idle, .loadingModels, .ready, .transcribing, .error("synthetic")]
        for state in free {
            let admission = MeetingSessionStateMachine.startAdmission(startCallInFlight: false, state: state)
            assertEqual(admission, .accepted, "\(state) leaves room for a new recording")
            assertTrue(admission.acceptsRecord)
        }

        let competing = MeetingSessionStateMachine.startAdmission(startCallInFlight: true, state: .ready)
        assertEqual(competing, .ignoredStartInFlight, "a second start while one is in flight is turned away")
        assertFalse(competing.acceptsRecord, "a competing start must not count as an accepted Record")
    }

    runSuite("MeetingOverlayController Discard menu requires session.recording") {
        let source = readSourceFixture(
            "Sources/UI/Overlay/MeetingOverlayController.swift",
            description: "MeetingOverlayController.swift"
        )
        guard let start = source.range(of: "private func makeStripMenu()"),
              let end = source.range(
                of: "@objc private func handleMenuDiscard()",
                range: start.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "meeting right-click menu should remain present")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        guard let sessionRecording = body.range(of: "if case .recording = meetingSession?.state"),
              let discard = body.range(of: "Discard Recording…") else {
            assertTrue(false, "Discard must be gated on the session being .recording, not overlay state")
            return
        }
        assertTrue(
            sessionRecording.lowerBound < discard.lowerBound,
            "Discard must sit inside the session.recording check so it hides while stopping"
        )
    }

    runSuite("MeetingOverlayController Discard confirm re-checks session.recording") {
        let source = readSourceFixture(
            "Sources/UI/Overlay/MeetingOverlayController.swift",
            description: "MeetingOverlayController.swift"
        )
        guard let start = source.range(of: "private func handleDiscardRequested()"),
              let end = source.range(
                of: "private func scheduleAutoHide(",
                range: start.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "discard confirm handler should remain present")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        guard let confirm = body.range(of: "alert.runModal()") else {
            assertTrue(false, "discard confirm must present a modal alert")
            return
        }
        let afterConfirm = body[confirm.upperBound...]
        assertTrue(
            afterConfirm.contains("guard case .recording = session.state else { return }"),
            "a Discard confirm that outlived Stop must not cancel a preserve already in flight"
        )
    }

    runSuite("The menu meeting button means Stop for the whole capture, not just steady recording") {
        assertEqual(MenuBarMeetingMenuAction.resolve(.recording), .stop)
        assertEqual(
            MenuBarMeetingMenuAction.resolve(.stoppingRecording),
            .stop,
            "a click while saving must not start a second meeting"
        )
        assertEqual(
            MenuBarMeetingMenuAction.resolve(.startingRecording),
            .stopJoiningPendingStart,
            "a Stop while the mic is engaging joins the pending start"
        )
        let free: [MeetingSessionState] = [.idle, .loadingModels, .ready, .transcribing, .error("synthetic")]
        for state in free {
            assertEqual(MenuBarMeetingMenuAction.resolve(state), .start, "\(state) starts a meeting")
        }
        assertEqual(MenuBarMeetingMenuAction.start.analyticsActionID, "start_meeting")
        assertEqual(MenuBarMeetingMenuAction.stop.analyticsActionID, "stop_meeting")
        assertEqual(MenuBarMeetingMenuAction.stopJoiningPendingStart.analyticsActionID, "stop_meeting")
    }
}

/// Stands in for `MeetingCaptureBridge` behind `MeetingCaptureControlling`.
@MainActor
private final class StopSequenceCaptureFake: MeetingCaptureControlling {
    var events: [String] = []
    var onFlush: (() -> Void)?
    var hasObservedSystemAudioSignal = false
    var systemAudioFinalizationFailed = false
    var systemAudioStartPermissionExplicitlyDenied = false

    func flushSharedDictationMicHandler() async {
        onFlush?()
        events.append("flush")
        await Task.yield()
    }
}
