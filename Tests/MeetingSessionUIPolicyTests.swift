import Foundation

func testMeetingSessionUIPolicy() {
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

    runSuite("MeetingSessionController wires Audio sleep/wake to the workspace center") {
        let source = readSourceFixture(
            "Sources/Meeting/MeetingSessionController.swift",
            description: "MeetingSessionController.swift"
        )
        guard let audioInit = source.range(of: "MeetingCaptureBridge("),
              let audioInitEnd = source.range(
                of: "self.sttAdapter = MeetingSTTAdapter",
                range: audioInit.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "production Audio construction should stay next to STT adapter setup")
            return
        }
        let body = String(source[audioInit.lowerBound..<audioInitEnd.lowerBound])
        assertTrue(
            body.contains("sleepWakeNotifications: AudioSleepWakeNotifications("),
            "production must inject sleep/wake notifications instead of Audio(paths:) defaults"
        )
        assertTrue(
            body.contains("center: NSWorkspace.shared.notificationCenter"),
            "sleep/wake must listen on the workspace center, not NotificationCenter.default"
        )
        assertTrue(
            body.contains("NSWorkspaceWillSleepNotification") && body.contains("NSWorkspaceDidWakeNotification"),
            "workspace sleep/wake notification names must stay wired"
        )
    }

    runSuite("MeetingSessionController unexpected stop leaves recording before any await") {
        let source = readSourceFixture(
            "Sources/Meeting/MeetingSessionController.swift",
            description: "MeetingSessionController.swift"
        )
        guard let start = source.range(of: "private func handleUnexpectedCaptureStop"),
              let end = source.range(
                of: "// preserveQueuedTranscriptionJobsForShutdown",
                range: start.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "unexpected capture-stop handler should remain present")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        guard let recordingGuard = body.range(of: "guard case .recording = state"),
              let leaveRecording = body.range(of: "transition(to: .stoppingRecording, reason: \"unexpected_capture_stop\")"),
              let firstAwait = body.range(of: "await capture.flushSharedDictationMicHandler()") else {
            assertTrue(false, "unexpected stop must guard .recording, leave it, then await flush work")
            return
        }
        assertTrue(
            recordingGuard.lowerBound < leaveRecording.lowerBound,
            "unexpected stop must confirm .recording before leaving it"
        )
        assertTrue(
            leaveRecording.lowerBound < firstAwait.lowerBound,
            "unexpected stop must enter .stoppingRecording before any await so stop/cancel cannot interleave"
        )
    }

    runSuite("MeetingSessionController startRecording returns false for active capture") {
        let source = readSourceFixture(
            "Sources/Meeting/MeetingSessionController.swift",
            description: "MeetingSessionController.swift"
        )
        guard let ignored = source.range(of: "Meeting start ignored because another meeting flow is active"),
              let nextCase = source.range(
                of: "case .idle, .loadingModels, .ready, .transcribing, .error:",
                range: ignored.upperBound..<source.endIndex
              ),
              let ignoredReturn = source.range(
                of: "return false",
                range: ignored.upperBound..<nextCase.lowerBound
              ) else {
            assertTrue(false, "active-capture start ignore must return false before the free-state cases")
            return
        }
        assertTrue(
            ignoredReturn.lowerBound < nextCase.lowerBound,
            "startRecording must not treat an already-active capture as an accepted Record"
        )
        assertFalse(
            String(source[ignored.upperBound..<nextCase.lowerBound]).contains("return true"),
            "active-capture start ignore must not return true"
        )
    }

    runSuite("MeetingOverlayController Discard menu requires session.recording") {
        let source = readSourceFixture(
            "Sources/UI/Overlay/MeetingOverlayController.swift",
            description: "MeetingOverlayController.swift"
        )
        guard let start = source.range(of: "private func makeStripMenu()"),
              let end = source.range(
                of: "@objc private func handleMenuTogglePin()",
                range: start.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "pill strip menu should remain present")
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

    runSuite("MenuBar start/stop uses capture-active instead of steady-state isRecording") {
        let source = readSourceFixture(
            "Sources/UI/MenuBar/MenuBarPanelController.swift",
            description: "MenuBarPanelController.swift"
        )
        guard let start = source.range(of: "private func startMeetingFromMenu()"),
              let end = source.range(
                of: "private func pasteLastDictationFromMenu()",
                range: start.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "menu meeting action should remain present")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        assertTrue(
            body.contains("isCaptureSessionActive"),
            "menu must treat starting/recording/stopping as Stop, not Start"
        )
        assertTrue(
            body.contains("stopRecordingJoiningPendingStart"),
            "a Stop during .startingRecording must join the pending start"
        )
        assertFalse(
            body.contains("meetingSession.isRecording"),
            "steady-state isRecording would double-start during starting/stopping"
        )
    }
}
