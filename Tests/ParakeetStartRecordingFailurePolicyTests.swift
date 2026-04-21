import Foundation

func testParakeetStartRecordingFailurePolicy() {
    runSuite("ParakeetStartRecordingFailurePolicy all known failures mark format unready") {
        let reasons: [ParakeetStartRecordingFailureReason] = [
            .invalidAudioFormat,
            .audioEngineStartFailed
        ]

        for reason in reasons {
            let initial = ParakeetStartRecordingFailurePolicy.action(for: reason, isRecoveryAttempt: false)
            let recovery = ParakeetStartRecordingFailurePolicy.action(for: reason, isRecoveryAttempt: true)

            assertTrue(initial.markFormatUnready, "\(reason) should mark format unready on initial start")
            assertTrue(recovery.markFormatUnready, "\(reason) should mark format unready on recovery start")
        }
    }

    runSuite("ParakeetStartRecordingFailurePolicy invalid format on initial start schedules retry") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .invalidAudioFormat,
            isRecoveryAttempt: false
        )

        assertTrue(action.markFormatUnready, "invalid format should mark format unready")
        assertTrue(action.schedulePrewarmRetry, "invalid format on initial start should schedule retry")
    }

    runSuite("ParakeetStartRecordingFailurePolicy invalid format on recovery start avoids extra retry scheduling") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .invalidAudioFormat,
            isRecoveryAttempt: true
        )

        assertTrue(action.markFormatUnready, "invalid format should still mark format unready during recovery")
        assertFalse(action.schedulePrewarmRetry, "recovery attempts should not chain extra retries")
    }

    runSuite("ParakeetStartRecordingFailurePolicy engine start failure on recovery start avoids extra retry scheduling") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioEngineStartFailed,
            isRecoveryAttempt: true
        )

        assertTrue(action.markFormatUnready, "engine start failure should mark format unready")
        assertFalse(action.schedulePrewarmRetry, "recovery attempts should not chain extra retries")
    }

    runSuite("ParakeetStartRecordingFailurePolicy engine start failure on initial start schedules retry") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioEngineStartFailed,
            isRecoveryAttempt: false
        )

        assertTrue(action.markFormatUnready, "engine start failure should mark format unready")
        assertTrue(action.schedulePrewarmRetry, "initial start failures should schedule retry")
    }
}
