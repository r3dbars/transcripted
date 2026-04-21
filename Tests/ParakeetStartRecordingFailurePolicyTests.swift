import Foundation

func testParakeetStartRecordingFailurePolicy() {
    runSuite("ParakeetStartRecordingFailurePolicy invalid format on initial start schedules retry") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .invalidAudioFormat,
            isRecoveryAttempt: false
        )

        assertTrue(action.markFormatUnready, "invalid format should mark format unready")
        assertTrue(action.schedulePrewarmRetry, "invalid format on initial start should schedule retry")
        assertTrue(action.rebuildAudioEngine, "invalid format should rebuild the stale audio engine")
    }

    runSuite("ParakeetStartRecordingFailurePolicy invalid format on recovery start avoids extra retry scheduling") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .invalidAudioFormat,
            isRecoveryAttempt: true
        )

        assertTrue(action.markFormatUnready, "invalid format should still mark format unready during recovery")
        assertFalse(action.schedulePrewarmRetry, "recovery attempts should not chain extra retries")
        assertTrue(action.rebuildAudioEngine, "invalid format should rebuild the stale audio engine during recovery")
    }

    runSuite("ParakeetStartRecordingFailurePolicy engine start failure on recovery start avoids extra retry scheduling") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioEngineStartFailed,
            isRecoveryAttempt: true
        )

        assertTrue(action.markFormatUnready, "engine start failure should mark format unready")
        assertFalse(action.schedulePrewarmRetry, "recovery attempts should not chain extra retries")
        assertTrue(action.rebuildAudioEngine, "engine start failure should rebuild the stale audio engine during recovery")
    }

    runSuite("ParakeetStartRecordingFailurePolicy engine start failure on initial start schedules retry") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioEngineStartFailed,
            isRecoveryAttempt: false
        )

        assertTrue(action.markFormatUnready, "engine start failure should mark format unready")
        assertTrue(action.schedulePrewarmRetry, "initial start failures should schedule retry")
        assertTrue(action.rebuildAudioEngine, "engine start failure should rebuild the stale audio engine")
    }
}
