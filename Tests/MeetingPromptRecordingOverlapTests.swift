import Foundation

@MainActor
func testMeetingPromptRecordingOverlap() {
    let startedAt = Date(timeIntervalSince1970: 1_797_000_000)
    let recordingStartedAt = startedAt.addingTimeInterval(1)
    let endedAt = startedAt.addingTimeInterval(MissedCallNudgePolicy.minimumCallDuration + 60)

    runSuite("Detected call ending observes a meeting recording started after its last sample") {
        var recording = false
        let detector = makeRecordingOverlapDetector(recording: { recording })
        var wasRecorded: Bool?
        var nudges = 0
        detector.onDetectedCallEnded = { wasRecorded = $0.wasRecorded }
        detector.onUnrecordedCallEnded = { _ in nudges += 1 }

        detector.updateDetectedCallSession(signals: [(.zoom, .micInput)], now: startedAt)
        recording = true
        detector.updateDetectedCallSession(signals: [], now: endedAt)

        assertEqual(wasRecorded, true, "the ending sample must count an active manual recording")
        assertEqual(nudges, 0, "a recorded call must not raise an unrecorded-call nudge")
    }

    runSuite("Recording receipt survives a stop before evaluation and clears learned quiet") {
        var recording = false
        let detector = makeRecordingOverlapDetector(recording: { recording })
        let kind = MeetingPromptLearnedBackoff.nativeKind(for: .zoom)
        detector.learnedBackoff.recordDismissal(kind: kind, now: startedAt)
        var wasRecorded: Bool?
        var nudges = 0
        detector.onDetectedCallEnded = { wasRecorded = $0.wasRecorded }
        detector.onUnrecordedCallEnded = { _ in nudges += 1 }
        detector.updateDetectedCallSession(signals: [(.zoom, .micInput)], now: startedAt)
        detector.detectedCallSession?.candidateKinds.insert(kind)

        recording = true
        detector.meetingRecordingDidStart(now: recordingStartedAt)
        assertEqual(detector.learnedBackoff.entry(for: kind, now: recordingStartedAt).lastAcceptedAt,
                    recordingStartedAt, "the recording edge must teach before any later dismissal")
        // Both state edges occur before the scheduled evaluation gets a turn.
        recording = false
        detector.updateDetectedCallSession(signals: [], now: endedAt)

        assertEqual(wasRecorded, true, "the actual recording edge must survive until call end")
        assertEqual(nudges, 0, "a stopped manual recording still counts as recorded")
        assertEqual(detector.learnedBackoff.dismissStreak(for: kind, now: endedAt), 0,
                    "recording the candidate call must clear its learned dismissal streak")
        assertEqual(detector.learnedBackoff.entry(for: kind, now: endedAt).lastAcceptedAt, recordingStartedAt,
                    "the recording receipt must preserve its acceptance timestamp")
    }

    runSuite("A later dismissal of a kind accepted at recording start stays quiet") {
        var recording = false
        let detector = makeRecordingOverlapDetector(recording: { recording })
        let kind = MeetingPromptLearnedBackoff.nativeKind(for: .zoom)
        detector.updateDetectedCallSession(signals: [(.zoom, .micInput)], now: startedAt)
        detector.detectedCallSession?.candidateKinds.insert(kind)
        recording = true
        detector.meetingRecordingDidStart(now: recordingStartedAt)
        recording = false
        detector.learnedBackoff.recordDismissal(kind: kind, now: endedAt)
        detector.updateDetectedCallSession(signals: [], now: endedAt)

        assertEqual(detector.learnedBackoff.dismissStreak(for: kind, now: endedAt), 1,
                    "a later dismissal of the same kind must survive delayed evaluation")
        assertEqual(detector.learnedBackoff.entry(for: kind, now: endedAt).lastAcceptedAt, recordingStartedAt,
                    "call end must not reorder acceptance after the later dismissal")
    }

    runSuite("A prompt considered only after recording stops keeps its learned quiet") {
        var recording = false
        let detector = makeRecordingOverlapDetector(recording: { recording })
        let kind = MeetingPromptLearnedBackoff.nativeKind(for: .zoom)
        var wasRecorded: Bool?
        detector.onDetectedCallEnded = { wasRecorded = $0.wasRecorded }
        detector.updateDetectedCallSession(signals: [(.zoom, .micInput)], now: startedAt)
        recording = true
        detector.meetingRecordingDidStart(now: recordingStartedAt)
        recording = false
        // This candidate did not exist during the recording. Its later dismissal
        // must not be treated as accepted just because the call was recorded.
        detector.detectedCallSession?.candidateKinds.insert(kind)
        detector.learnedBackoff.recordDismissal(kind: kind, now: endedAt)
        detector.updateDetectedCallSession(signals: [], now: endedAt)

        assertEqual(wasRecorded, true, "the overlap still counts for the call summary")
        assertEqual(detector.learnedBackoff.dismissStreak(for: kind, now: endedAt), 1,
                    "an earlier recording must not clear a later candidate dismissal")
        assertEqual(detector.learnedBackoff.entry(for: kind, now: endedAt).lastAcceptedAt, nil,
                    "recording before any candidate was considered must teach nothing")
    }

    runSuite("A recording receipt without an active detected call does not mark the next call") {
        let detector = makeRecordingOverlapDetector(recording: { false })
        var wasRecorded: Bool?
        detector.onDetectedCallEnded = { wasRecorded = $0.wasRecorded }
        detector.meetingRecordingDidStart(now: recordingStartedAt)
        detector.updateDetectedCallSession(signals: [(.zoom, .micInput)], now: startedAt)
        detector.updateDetectedCallSession(signals: [], now: endedAt)
        assertEqual(wasRecorded, false, "a previous standalone recording must not count for a later call")
    }

    runSuite("A long call with no meeting recording still produces its missed-call nudge") {
        let detector = makeRecordingOverlapDetector(recording: { false })
        var wasRecorded: Bool?
        var nudges = 0
        detector.onDetectedCallEnded = { wasRecorded = $0.wasRecorded }
        detector.onUnrecordedCallEnded = { _ in nudges += 1 }

        detector.updateDetectedCallSession(signals: [(.zoom, .micInput)], now: startedAt)
        detector.updateDetectedCallSession(signals: [], now: endedAt)

        assertEqual(wasRecorded, false, "unrecorded calls must retain their funnel outcome")
        assertEqual(nudges, 1, "the existing missed-call flow must stay available")
    }
}

@MainActor
private func makeRecordingOverlapDetector(recording: @escaping () -> Bool) -> MeetingPromptDetector {
    let detector = MeetingPromptDetector(
        calendarAccessGranted: { false },
        refreshesCalendarEventSnapshots: false,
        fetchCalendarEventSnapshots: { _, _ in [] },
        learnedBackoffDefaults: nil,
        meetingShortcutDisplay: { "synthetic shortcut" }
    )
    detector.frontmostBundleIDProvider = { nil }
    detector.runningBundleIDsProvider = { [] }
    detector.browserWindowTitlesProvider = { _ in [] }
    detector.isAutoRecordEnabled = { false }
    detector.isMicInputPromptEnabled = { true }
    detector.callShortcutProvider = { _ in nil }
    detector.isOwnCaptureActive = recording
    detector.ownCaptureActivity = { recording() ? .meetingRecording : .none }
    return detector
}
