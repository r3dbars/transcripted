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

    runSuite("ParakeetDeviceRecoveryReadinessPolicy waits on unsettled route formats") {
        assertEqual(
            ParakeetDeviceRecoveryReadinessPolicy.action(for: .routeNotSettled),
            .keepWaiting,
            "route churn should keep using the recovery budget instead of failing after the first stale format"
        )
    }

    runSuite("ParakeetDeviceRecoveryReadinessPolicy waits on invalid transient formats") {
        assertEqual(
            ParakeetDeviceRecoveryReadinessPolicy.action(for: .invalid),
            .keepWaiting,
            "zero or invalid formats during device churn should wait for the recovery timeout"
        )
    }

    runSuite("ParakeetDeviceRecoveryReadinessPolicy finishes only on ready formats") {
        assertEqual(
            ParakeetDeviceRecoveryReadinessPolicy.action(for: .ready),
            .finishRecovery,
            "ready formats should complete the device-change recovery"
        )
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

    runSuite("ParakeetASRManagerCleanupPolicy defers cleanup during active inference") {
        assertEqual(
            ParakeetASRManagerCleanupPolicy.decision(isTranscribing: true),
            .deferUntilProcessExit,
            "shutdown must not clean up CoreML ASR objects while prediction is active"
        )
        assertEqual(
            ParakeetASRManagerCleanupPolicy.decision(isTranscribing: false),
            .cleanupNow,
            "idle shutdown can still release ASR objects normally"
        )
    }

    runSuite("ParakeetASRInferenceActivityState stays active until all inference exits") {
        var state = ParakeetASRInferenceActivityState()

        state.begin()
        state.begin()
        assertTrue(state.isActive, "any active CoreML inference should block manager cleanup")
        assertEqual(state.activeCount, 2, "nested activity should keep an exact count")

        state.finish()
        assertTrue(state.isActive, "one completed inference should not clear cleanup protection while another remains")
        assertEqual(state.activeCount, 1, "finish should decrement one active inference")

        state.finish()
        assertFalse(state.isActive, "cleanup protection can clear once every inference is done")
        assertEqual(state.activeCount, 0, "activity count should return to zero")

        state.finish()
        assertEqual(state.activeCount, 0, "extra finish calls should not underflow")
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

    runSuite("ParakeetAudioFormatReadinessPolicy defers built-in override with Bluetooth output speech bus") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: true
        )

        assertEqual(readiness, .routeNotSettled, "built-in fallback should wait until the Bluetooth output bus leaves speech mode")
        assertEqual(readiness.startFailureReason, .audioRouteNotSettled, "stale Bluetooth output routes should map to route-not-settled")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy defers preferred built-in fallback with Bluetooth speech output") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: true,
            selectionReason: .preferredBuiltInForBluetoothHeadset
        )

        assertEqual(readiness, .routeNotSettled, "forced built-in fallback should wait until Bluetooth output leaves speech mode")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy defers preferred fallback across Bluetooth speech rates") {
        for outputRate in [8_000.0, 16_000.0] {
            let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: outputRate,
                outputChannelCount: 1,
                inputSampleRate: 48_000,
                inputChannelCount: 1,
                selectedInputClass: "built_in",
                outputDeviceClass: "bluetooth",
                selectionOverrodeDefault: true,
                selectionReason: .preferredBuiltInForBluetoothHeadset
            )

            assertEqual(readiness, .routeNotSettled, "preferred built-in fallback should wait on Bluetooth speech output rate \(outputRate)")
        }
    }

    runSuite("ParakeetAudioFormatReadinessPolicy defers non-preferred override reasons on Bluetooth output") {
        let nonPreferredReasons: [DictationInputDeviceSelectionReason] = [
            .defaultIsSafe,
            .builtInFallbackSuppressedForRecoveryAttempt,
            .noBuiltInFallbackAvailable
        ]

        for reason in nonPreferredReasons {
            let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: 24_000,
                outputChannelCount: 1,
                inputSampleRate: 48_000,
                inputChannelCount: 1,
                selectedInputClass: "built_in",
                outputDeviceClass: "bluetooth",
                selectionOverrodeDefault: true,
                selectionReason: reason
            )

            assertEqual(readiness, .routeNotSettled, "\(reason.rawValue) should not bypass route settling")
            assertEqual(readiness.startFailureReason, .audioRouteNotSettled, "\(reason.rawValue) should keep the start failure recoverable")
        }
    }

    runSuite("ParakeetAudioFormatReadinessPolicy scopes preferred fallback exception to Bluetooth output") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "built_in",
            selectionOverrodeDefault: true,
            selectionReason: .preferredBuiltInForBluetoothHeadset
        )

        assertEqual(readiness, .routeNotSettled, "preferred fallback should still wait on stale non-Bluetooth output formats")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy accepts intentional Bluetooth output speech bus") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: false
        )

        assertEqual(readiness, .ready, "native built-in capture with Bluetooth output can still use the speech bus when Transcripted did not force an input override")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy accepts settled built-in override with Bluetooth output") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: true
        )

        assertEqual(readiness, .ready, "built-in fallback can start once the Bluetooth output bus settles back to a normal capture rate")
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

    runSuite("ParakeetAudioFormatReadinessPolicy defers stale external-input formats") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "external",
            outputDeviceClass: "built_in",
            selectionOverrodeDefault: false
        )

        assertEqual(readiness, .routeNotSettled, "external mics can see the same stale 24k output bus during route churn")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy allows Bluetooth speech output routes") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "external",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: false
        )

        assertEqual(readiness, .ready, "Bluetooth output speech buses should not be deferred when that is the active route")
    }

    runSuite("ParakeetAudioFormatReadinessPolicy allows native low-rate external capture") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 24_000,
            outputChannelCount: 1,
            inputSampleRate: 24_000,
            inputChannelCount: 1,
            selectedInputClass: "external",
            outputDeviceClass: "built_in",
            selectionOverrodeDefault: false
        )

        assertEqual(readiness, .ready, "native 24k external capture should stay usable when input and output agree")
    }

    runSuite("ParakeetInputOverrideSettlePolicy waits after a ready input override") {
        assertEqual(
            ParakeetInputOverrideSettlePolicy.delayNanoseconds(afterImmediateReadiness: .ready),
            TranscriptedConstants.audioRecoveryDelay,
            "ready formats still get a short settle after forcing AirPods input away from the headset mic"
        )
    }

    runSuite("ParakeetInputOverrideSettlePolicy keeps delay while route is settling") {
        assertEqual(
            ParakeetInputOverrideSettlePolicy.delayNanoseconds(afterImmediateReadiness: .routeNotSettled),
            TranscriptedConstants.audioRecoveryDelay,
            "stale route formats should still get the full CoreAudio settle delay"
        )
        assertEqual(
            ParakeetInputOverrideSettlePolicy.delayNanoseconds(afterImmediateReadiness: .invalid),
            TranscriptedConstants.audioRecoveryDelay,
            "invalid formats should still get the full CoreAudio settle delay"
        )
    }

    runSuite("ParakeetTapSampleRatePolicy trusts the tap buffer rate over AirPods hardware rate") {
        let effectiveSampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
            bufferSampleRate: 48_000,
            hardwareSampleRate: 24_000
        )

        assertEqual(
            effectiveSampleRate,
            48_000,
            "AirPods HFP can expose 24k hardware while the tap delivers 48k buffers; dictation must resample from the tap rate"
        )
    }

    runSuite("ParakeetTapSampleRatePolicy falls back for invalid tap rates") {
        let effectiveSampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
            bufferSampleRate: 0,
            hardwareSampleRate: 24_000
        )

        assertEqual(
            effectiveSampleRate,
            ParakeetAudioFormatReadinessPolicy.fallbackCaptureSampleRate,
            "invalid tap rates should still use the central safe fallback"
        )
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

    runSuite("ParakeetAudioFormatReadinessPolicy rejects zero channel counts") {
        let zeroOutputChannels = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 0,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "built_in",
            selectionOverrodeDefault: true
        )

        assertEqual(zeroOutputChannels, .invalid, "zero output channels should be invalid")
        assertEqual(zeroOutputChannels.startFailureReason, .invalidAudioFormat, "zero output channels should map to invalidAudioFormat")
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

    runSuite("ParakeetAudioFormatReadinessPolicy accepts exact sample-rate bounds") {
        assertTrue(
            ParakeetAudioFormatReadinessPolicy.isUsableCaptureSampleRate(8_000),
            "the lower supported capture rate should remain usable"
        )
        assertTrue(
            ParakeetAudioFormatReadinessPolicy.isUsableCaptureSampleRate(384_000),
            "the upper supported capture rate should remain usable"
        )
        assertEqual(
            ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(7_999),
            ParakeetAudioFormatReadinessPolicy.fallbackCaptureSampleRate,
            "below-range capture rates should use the fallback"
        )
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

    runSuite("ParakeetAudioFormatReadinessPolicy handles invalid buffer windows safely") {
        let zeroSeconds = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
            sampleRate: 48_000,
            seconds: 0
        )
        let negativeSeconds = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
            sampleRate: 48_000,
            seconds: -5
        )

        assertEqual(zeroSeconds, 48_000, "zero-second buffers should still allocate one safe fallback second")
        assertEqual(negativeSeconds, 48_000, "negative buffer windows should still allocate one safe fallback second")
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

    runSuite("ParakeetEngine zombie watchdog marks recording idle before graph reset") {
        let source = readParakeetEngineSource()
        guard let watchdogStart = source.range(of: "private func startAudioWatchdog()"),
              let watchdogEnd = source.range(of: "func stopRecording()", range: watchdogStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the zombie watchdog body")
            return
        }
        let watchdog = String(source[watchdogStart.lowerBound..<watchdogEnd.lowerBound])
        guard let markIdle = watchdog.range(of: "self.isRecording = false"),
              let clearRestartFlag = watchdog.range(of: "self.configChangeWasRecording = false"),
              let suppressConfigChanges = watchdog.range(of: "self.ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent() + 1.0"),
              let removeTap = watchdog.range(of: "await self.removeRecordingTap()"),
              let stopEngine = watchdog.range(of: "await self.stopAudioEngine()") else {
            assertTrue(false, "zombie watchdog should mark internal reset state before touching CoreAudio")
            return
        }

        assertTrue(markIdle.lowerBound < removeTap.lowerBound, "zombie reset should stop being treated as active recording before tap removal can post config changes")
        assertTrue(markIdle.lowerBound < stopEngine.lowerBound, "zombie reset should stop being treated as active recording before engine stop can post config changes")
        assertTrue(clearRestartFlag.lowerBound < removeTap.lowerBound, "zombie reset should not leave the device-change restart flag armed")
        assertTrue(suppressConfigChanges.lowerBound < removeTap.lowerBound, "zombie reset should suppress self-induced config changes before graph teardown")
    }
}

private func readParakeetEngineSource(file: String = #file, line: Int = #line) -> String {
    let url = repoFixtureURL("Sources/Speech/ParakeetEngine.swift")
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        totalTests += 1
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] could not read ParakeetEngine.swift: \(error)")
        return ""
    }
}
