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

    runSuite("ParakeetStartRecordingFailurePolicy route-not-settled during recovery does not chain retries") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioRouteNotSettled,
            isRecoveryAttempt: true
        )

        assertTrue(action.markFormatUnready, "recovery route failures should still hold recording starts")
        assertFalse(action.schedulePrewarmRetry, "recovery route failures should not recursively schedule retries")
        assertTrue(action.rebuildAudioEngine, "recovery route failures should rebuild the audio engine")
    }

    runSuite("ParakeetDeviceRecoveryFailurePolicy keeps idle device settling out of Sentry") {
        let action = ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: false)

        assertFalse(action.reportSentryFailure, "idle device changes should keep transient rewarm failures local")
        assertFalse(action.markRecordingInterrupted, "idle recovery should not mark a recording interruption")
        assertTrue(action.schedulePrewarmRetry, "idle recovery should keep retrying prewarm until the route settles")
    }

    runSuite("ParakeetDeviceRecoveryFailurePolicy reports recording interruptions") {
        let action = ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: true)

        assertTrue(action.reportSentryFailure, "active recordings should still report rewarm failures")
        assertTrue(action.markRecordingInterrupted, "active recordings should surface interruption state")
        assertTrue(action.schedulePrewarmRetry, "recording recovery should still schedule a follow-up prewarm")
    }

    runSuite("ParakeetDeviceRecoveryTimeoutPolicy abandons blocked audio graph") {
        let idleAction = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: false)
        let recordingAction = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: true)

        assertEqual(idleAction.rebuildStrategy, .abandonBlockedAudioGraph, "timeout recovery must not queue behind a stuck CoreAudio snapshot")
        assertEqual(recordingAction.rebuildStrategy, .abandonBlockedAudioGraph, "active recording timeout needs the same hard graph reset")
        assertFalse(idleAction.failureAction.reportSentryFailure, "idle timeout should stay local-only")
        assertTrue(recordingAction.failureAction.reportSentryFailure, "active recording timeout should still be visible")
    }

    runSuite("ParakeetAudioEngineRetirementPolicy outlives CoreAudio recovery") {
        assertTrue(
            ParakeetAudioEngineRetirementPolicy.deferredReleaseDelayNanoseconds
                > TranscriptedConstants.audioDeviceRecoveryTimeout,
            "retired AVAudioEngine instances should stay alive beyond the route recovery timeout"
        )
    }

    runSuite("ParakeetAudioFormatReadinessPolicy accepts normal built-in formats") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "built_in",
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
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: false
        )

        assertEqual(readiness, .ready, "AirPods HFP 24k hardware to 48k output should remain valid")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy accepts built-in mic with Bluetooth output speech bus") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: true
        )

        assertEqual(readiness, .ready, "built-in mic with Bluetooth output can capture at the 24k bus and resample")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy defers stale AirPods-to-built-in switch formats") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "built_in",
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
            outputDeviceClass: "built_in",
            selectionOverrodeDefault: true
        )

        assertEqual(readiness, .invalid, "zero output rate should still be invalid")
        assertEqual(readiness.startFailureReason, .invalidAudioFormat, "invalid format should map to invalidAudioFormat")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy rejects invalid input-side formats") {
        let zeroInputRate = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 0,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "built_in",
            selectionOverrodeDefault: true
        )
        let zeroInputChannels = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 0,
            selectedInputClass: "built_in",
            outputDeviceClass: "built_in",
            selectionOverrodeDefault: true
        )

        assertEqual(zeroInputRate, .invalid, "zero input rate should be invalid")
        assertEqual(zeroInputRate.startFailureReason, .invalidAudioFormat, "zero input rate should map to invalidAudioFormat")
        assertEqual(zeroInputChannels, .invalid, "zero input channels should be invalid")
        assertEqual(zeroInputChannels.startFailureReason, .invalidAudioFormat, "zero input channels should map to invalidAudioFormat")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy rejects non-finite sample rates") {
        for sampleRate in [Double.nan, Double.infinity, -Double.infinity] {
            let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: sampleRate,
                outputChannelCount: 1,
                inputSampleRate: 48_000,
                inputChannelCount: 1,
                selectedInputClass: "built_in",
                outputDeviceClass: "built_in",
                selectionOverrodeDefault: false
            )

            assertEqual(readiness, .invalid, "non-finite output sample rates must not become ready")
        }
    }

    runSuite("ParakeetAudioFormatReadinessPolicy rejects implausible capture sample rates") {
        for sampleRate in [-1.0, 1.0, 7_999.0, 384_001.0] {
            let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: sampleRate,
                outputChannelCount: 1,
                inputSampleRate: 48_000,
                inputChannelCount: 1,
                selectedInputClass: "built_in",
                outputDeviceClass: "built_in",
                selectionOverrodeDefault: false
            )

            assertEqual(readiness, .invalid, "implausible output sample rates must wait for recovery")
        }

        assertTrue(
            ParakeetAudioFormatReadinessPolicy.isUsableCaptureSampleRate(48_000),
            "normal capture rates should remain usable"
        )
    }

    runSuite("ParakeetAudioFormatReadinessPolicy uses bounded fallback buffer sizing") {
        let fallbackCapacity = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
            sampleRate: .nan,
            seconds: 10
        )
        let cappedCapacity = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
            sampleRate: 384_000,
            seconds: 10
        )
        let normalCapacity = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
            sampleRate: 48_000,
            seconds: 10
        )

        assertEqual(fallbackCapacity, 480_000, "invalid rates should fall back to 48k for buffer math")
        assertEqual(cappedCapacity, 960_000, "high valid rates should be capped for memory sizing")
        assertEqual(normalCapacity, 480_000, "normal rates should size buffers normally")
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

    runSuite("ParakeetAudioFormatReadinessPolicy maps generic CoreAudio errors to start failure") {
        let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: -1)

        assertEqual(
            ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error),
            .audioEngineStartFailed,
            "non-route CoreAudio errors should stay generic engine-start failures"
        )
    }
}
