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

    runSuite("ParakeetStartRecordingFailurePolicy route-not-settled schedules prewarm") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioRouteNotSettled,
            isRecoveryAttempt: false
        )

        assertTrue(action.markFormatUnready, "stale route formats should hold recording starts")
        assertTrue(action.schedulePrewarmRetry, "stale route formats should wait for the next prewarm")
        assertTrue(action.rebuildAudioEngine, "stale route formats should rebuild the audio engine")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy accepts normal built-in formats") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            selectionOverrodeDefault: true
        )

        assertEqual(readiness, .ready, "built-in mic 48k/48k should be ready")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy accepts AirPods HFP upsample path") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 24_000,
            inputChannelCount: 1,
            selectedInputClass: "bluetooth",
            selectionOverrodeDefault: false
        )

        assertEqual(readiness, .ready, "AirPods HFP 24k hardware to 48k output should remain valid")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy defers stale AirPods-to-built-in switch formats") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            selectionOverrodeDefault: true
        )

        assertEqual(readiness, .routeNotSettled, "24k output against a 48k built-in override is the stale route seen in Sentry")
        assertEqual(readiness.startFailureReason, .audioRouteNotSettled, "route-not-settled should map to the matching start failure")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy rejects zero formats") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 0,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            selectionOverrodeDefault: true
        )

        assertEqual(readiness, .invalid, "zero output rate should still be invalid")
        assertEqual(readiness.startFailureReason, .invalidAudioFormat, "invalid format should map to invalidAudioFormat")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy maps CoreAudio format-not-supported") {
        let error = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: ParakeetAudioFormatReadinessPolicy.audioUnitFormatNotSupportedCode
        )

        assertEqual(
            ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error),
            .audioRouteNotSettled,
            "CoreAudio -10868 should be treated as a settling route instead of a terminal engine failure"
        )
    }
}
