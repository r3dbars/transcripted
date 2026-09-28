import Foundation

@MainActor
func testMeetingCallAudioAsk() async {
    await runSuite("The island asks about call audio after a first-time macOS Don't Allow") {
        // The island answers the first question with Turn It On, macOS shows
        // its box, the person picks Don't Allow: the meeting records the mic
        // and the island must ask while it records.
        let outcome = await MeetingSystemAudioAccessFlow.resolve(
            isUndetermined: true,
            remembersMicOnly: false,
            ask: { _ in .turnOn },
            requestAccess: { false },
            openSettings: {}
        )
        var ask = MeetingCallAudioAsk()
        ask.startAttemptBegan()
        ask.accessResolved(outcome)
        ask.meetingStateChanged(isStartingOrRecording: true)
        ask.startAttemptEnded(recording: true)
        assertTrue(ask.isAsking, "mic only after Don't Allow: the island asks during this meeting")
    }

    runSuite("The island asks when it skipped the question to start on the mic") {
        var ask = MeetingCallAudioAsk()
        ask.startAttemptBegan()
        ask.accessResolved(.recordMicOnlyAskingWhileRecording)
        ask.startAttemptEnded(recording: true)
        assertTrue(ask.isAsking)
    }

    runSuite("Other start outcomes never raise the ask") {
        let outcomes: [MeetingSystemAudioAccessFlow.Outcome] = [
            .recordBothSides, .recordMicOnly, .recordMicOnlyBeforeMacOSAnswer,
            .turnOnWithoutMacOSAnswer, .recordMicOnlyRemembered, .openedSettings,
        ]
        for outcome in outcomes {
            var ask = MeetingCallAudioAsk()
            ask.startAttemptBegan()
            ask.accessResolved(outcome)
            ask.startAttemptEnded(recording: true)
            assertFalse(ask.isAsking, "\(outcome.rawValue) does not ask")
        }
    }

    runSuite("A start that fails before recording drops its ask, so the next meeting has none") {
        var ask = MeetingCallAudioAsk()
        ask.startAttemptBegan()
        ask.accessResolved(.recordMicOnlyAskingWhileRecording)
        // Capture failed before the island ever showed the meeting preparing.
        ask.meetingStateChanged(isStartingOrRecording: false)
        ask.startAttemptEnded(recording: false)
        assertFalse(ask.isAsking, "no recording, nothing to ask about")

        // The next meeting has call audio allowed.
        ask.startAttemptBegan()
        ask.accessResolved(.recordBothSides)
        ask.meetingStateChanged(isStartingOrRecording: true)
        ask.startAttemptEnded(recording: true)
        assertFalse(ask.isAsking, "an allowed meeting never shows a stale ask")
    }

    runSuite("A new start clears an ask left from before") {
        var ask = MeetingCallAudioAsk()
        ask.startAttemptBegan()
        ask.accessResolved(.recordMicOnlyAskingWhileRecording)
        ask.startAttemptEnded(recording: true)
        assertTrue(ask.isAsking)
        ask.startAttemptBegan()
        assertFalse(ask.isAsking, "the ask belongs to the start that raised it")
    }

    runSuite("The ask lasts through the start and the recording, and ends with the meeting") {
        var ask = MeetingCallAudioAsk()
        ask.startAttemptBegan()
        // Models finishing during the permission preamble move the state
        // without ending the start.
        ask.meetingStateChanged(isStartingOrRecording: false)
        ask.accessResolved(.recordMicOnlyAskingWhileRecording)
        ask.meetingStateChanged(isStartingOrRecording: true)
        ask.startAttemptEnded(recording: true)
        ask.meetingStateChanged(isStartingOrRecording: true)
        assertTrue(ask.isAsking, "still asking while it records")
        ask.meetingStateChanged(isStartingOrRecording: false)
        assertFalse(ask.isAsking, "stopping ends it")
    }

    runSuite("Answering on the island ends the ask") {
        var ask = MeetingCallAudioAsk()
        ask.startAttemptBegan()
        ask.accessResolved(.recordMicOnlyAskingWhileRecording)
        ask.startAttemptEnded(recording: true)
        ask.dismissed()
        assertFalse(ask.isAsking)
    }
}
