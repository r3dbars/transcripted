import Foundation

@MainActor
func testMeetingPromptQuietDeadline() async {
    guard #available(macOS 14.0, *) else { return }
    let suite = "Transcripted.QuietDeadlineTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let detector = MeetingPromptDetector(
        calendarAccessGranted: { false },
        refreshesCalendarEventSnapshots: false,
        learnedBackoffDefaults: defaults,
        meetingShortcutDisplay: { "test" }
    )
    detector.isOwnCaptureActive = { false }
    defer { detector.stop() }
    let now = Date()
    let candidate = detector.micInputCandidate(
        for: .teams, reason: .micInput, evidence: .nativeApp, now: now
    ).candidate
    detector.detectedCallSession = MeetingPromptDetector.DetectedCallSession(
        providers: [.teams], seenReasons: [.micInput], startedAt: now,
        sawMeetingRecording: false, userDeclined: false, promptShown: true
    )
    let decision = detector.dismiss(candidate: candidate)
    let notNows = detector.detectedCallSession!.nativeNotNows

    runSuite("A returning native call cannot extend the original dismissal deadline") {
        detector.nativeNotNowCallEnded(notNows, now: now)
        var returning = MeetingPromptDetector.DetectedCallSession(
            providers: [.teams], seenReasons: [.micInput], startedAt: now.addingTimeInterval(10),
            sawMeetingRecording: false, userDeclined: false, promptShown: false
        )
        detector.carryOverEndedNativeNotNows(into: &returning, now: now.addingTimeInterval(10))
        detector.detectedCallSession = returning
        assertNotNil(detector.learnedSuppression(for: candidate, now: decision.until.addingTimeInterval(-1)),
                     "a signal gap retains quiet until the original dismissal expires")
        assertTrue(detector.learnedSuppression(for: candidate, now: decision.until.addingTimeInterval(1)) == nil,
                   "a new call must not inherit an eight-hour extension")
        assertTrue(!detector.isAutoStartBlockedThisCall(now: decision.until.addingTimeInterval(1)),
                   "the inherited decline must expire for automatic recording too")
    }

    runSuite("A later quiet deadline keeps the earlier recheck scheduled") {
        detector.stop()
        detector.nativeNotNowCallEnded(notNows, now: now)
        let first = detector.recordedCallQuietEndTask
        detector.nativeNotNowCallEnded(notNows, now: now.addingTimeInterval(10))
        assertTrue(first?.isCancelled == false, "a later quiet window cannot cancel the earlier wake")
    }
}
