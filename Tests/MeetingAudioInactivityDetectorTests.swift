import Foundation

func testMeetingAudioInactivityDetector() {
    runSuite("MeetingAudioInactivityDetector warns after configured silence") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 300,
                countdownSeconds: 30,
                activeLevelThreshold: 0.02
            )
        )

        assertEqual(detector.startRecording(at: 0), .none)
        assertEqual(detector.tick(at: 299), .none)
        assertEqual(
            detector.tick(at: 300),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 300, countdownSeconds: 30))
        )
    }

    runSuite("MeetingAudioInactivityDetector clears warning when audio resumes") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        assertEqual(
            detector.tick(at: 10),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
        assertEqual(detector.observe(micLevel: 0.03, systemLevel: 0, at: 12), .warningCleared)
        assertNil(detector.warning)
        assertEqual(detector.tick(at: 21), .none)
        assertEqual(
            detector.tick(at: 22),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
    }

    runSuite("MeetingAudioInactivityDetector dismiss snoozes until audio resumes") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        _ = detector.tick(at: 10)
        assertEqual(detector.dismissWarning(), .warningCleared)
        assertEqual(detector.tick(at: 100), .none)
        assertNil(detector.warning)

        assertEqual(detector.observe(micLevel: 0, systemLevel: 0.03, at: 101), .none)
        assertEqual(
            detector.tick(at: 111),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
    }

    runSuite("MeetingAudioInactivityDetector treats either audio stream as active") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        assertEqual(detector.observe(micLevel: 0, systemLevel: 0.03, at: 8), .none)
        assertEqual(detector.tick(at: 17), .none)
        assertEqual(
            detector.tick(at: 18),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
    }

    runSuite("MeetingAudioInactivityDetector stop clears active warning") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        _ = detector.tick(at: 10)
        assertEqual(detector.stopRecording(), .warningCleared)
        assertNil(detector.warning)
        assertEqual(detector.tick(at: 100), .none)
    }
}
