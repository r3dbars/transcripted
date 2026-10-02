// ParakeetStartRecordingFailurePolicyTests.swift
//
// Pure policy suites compile and execute real decision logic. They are not
// runtime audio proof. The zombie-recovery order and the ASR decoder gate have
// their own behavior suites beside this one.

import Foundation

func testParakeetStartRecordingFailurePolicy() {
    runSuite("ParakeetAudioEngineWorkError distinguishes timeout from circuit-open") {
        let timedOut = ParakeetAudioEngineWorkError.timedOut(
            operation: "start_recording",
            timeoutMs: 1500
        )
        let circuitOpen = ParakeetAudioEngineWorkError.circuitOpen(
            operation: "start_recording",
            activeWorkers: 1
        )

        assertTrue(timedOut.isTimedOut, "timed-out work should report isTimedOut")
        assertFalse(timedOut.isCircuitOpen, "timed-out work should not report circuit-open")
        assertTrue(timedOut.requiresGraphAbandonment, "timed-out work should abandon a blocked graph")
        assertFalse(circuitOpen.isTimedOut, "circuit-open work should not be counted as a timeout")
        assertTrue(circuitOpen.isCircuitOpen, "circuit-open work should report isCircuitOpen")
        assertFalse(circuitOpen.requiresGraphAbandonment, "circuit-open work should keep the existing graph fail-closed")

        let systemInputCircuitOpen = ParakeetSystemInputWorkError.circuitOpen(
            operation: "start_recording_selection",
            activeTimeouts: 2
        )
        assertFalse(systemInputCircuitOpen.isTimedOut, "system-input circuit-open work should not report a timeout")
        assertTrue(systemInputCircuitOpen.isCircuitOpen, "system-input circuit-open work should report isCircuitOpen")
    }

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

    runSuite("ParakeetStartRecordingFailurePolicy engine start timeout stays explicit and retryable") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioEngineStartTimedOut,
            isRecoveryAttempt: false
        )

        assertTrue(action.markFormatUnready, "timed-out engine starts should hold new starts until recovery refreshes readiness")
        assertTrue(action.schedulePrewarmRetry, "a timed-out first start should still schedule readiness recovery for Try Again")
        assertTrue(action.rebuildAudioEngine, "timed-out starts should keep using the graph recovery action")
    }

    runSuite("ParakeetStartRecordingFailurePolicy engine start timeout on recovery does not chain retries") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioEngineStartTimedOut,
            isRecoveryAttempt: true
        )

        assertTrue(action.markFormatUnready, "recovery timeout should keep input marked unready")
        assertFalse(action.schedulePrewarmRetry, "recovery timeout should not recursively schedule more recovery starts")
        assertTrue(action.rebuildAudioEngine, "recovery timeout should keep graph recovery enabled")
    }

    runSuite("ParakeetStartRecordingFailurePolicy route-not-settled schedules prewarm") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioRouteNotSettled,
            isRecoveryAttempt: false
        )

        assertTrue(action.markFormatUnready, "stale route formats should hold recording starts")
        assertTrue(action.schedulePrewarmRetry, "stale route formats should wait for the next prewarm")
        assertFalse(action.rebuildAudioEngine, "stale route formats should wait without rebuilding the audio engine")
    }

    runSuite("ParakeetStartRecordingFailurePolicy route-not-settled during recovery keeps readiness retry") {
        let action = ParakeetStartRecordingFailurePolicy.action(
            for: .audioRouteNotSettled,
            isRecoveryAttempt: true
        )

        assertTrue(action.markFormatUnready, "recovery route failures should still hold recording starts")
        assertTrue(action.schedulePrewarmRetry, "recovery route failures should leave a bounded readiness retry path")
        assertFalse(action.rebuildAudioEngine, "recovery route failures should not churn the audio graph")
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

    runSuite("ParakeetDeviceRecoveryFailurePolicy abandons the wedged queue on a blocked rewarm") {
        // A timed-out recovery snapshot means the serial audio-engine queue is
        // stuck behind a CoreAudio call that never returned (the AirPods/Bluetooth
        // route-switch hang). Rebuilding on that same queue would never run, so the
        // recovery must hard-reset onto a fresh engine + queue instead.
        assertEqual(
            ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(audioEngineQueueBlocked: true),
            .abandonBlockedAudioGraph,
            "a blocked engine queue must be abandoned, not queued behind, or rewarm hangs until force-quit"
        )
    }

    runSuite("ParakeetDeviceRecoveryFailurePolicy rebuilds on the live queue when it is not blocked") {
        assertEqual(
            ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(audioEngineQueueBlocked: false),
            .queuedOnAudioEngineQueue,
            "a responsive queue can still rebuild the engine in place"
        )
    }

    runSuite("ParakeetDeviceRecoveryFailurePolicy blocked-rewarm strategy matches the timeout path") {
        // The recovery-timeout path already abandons the blocked graph. A blocked
        // rewarm is the same wedged-queue condition reached a different way, so the
        // two must agree — otherwise rewarm and timeout diverge on the same hang.
        assertEqual(
            ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(audioEngineQueueBlocked: true),
            ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: true).rebuildStrategy,
            "blocked rewarm recovery must use the same hard reset as the recovery-timeout path"
        )
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
        assertEqual(
            ParakeetAudioEngineRetirementPolicy.maximumRetainedEngineCount,
            4,
            "route churn should have a small hard cap on concurrently retained native graphs"
        )
    }

    runSuite("ParakeetTimedAudioEngineWorkLimiter holds slots until workers finish") {
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 2)
        guard let first = limiter.acquire(), let second = limiter.acquire() else {
            assertTrue(false, "the configured worker slots should be available")
            return
        }

        assertEqual(limiter.activeWorkerCount, 2, "both running workers should hold a slot")
        assertTrue(limiter.acquire() == nil, "a third timed worker must fail closed")

        first.release()
        assertEqual(limiter.activeWorkerCount, 1, "a slot returns only when its worker releases")
        guard let replacement = limiter.acquire() else {
            assertTrue(false, "a completed worker should make exactly one slot reusable")
            return
        }
        assertEqual(limiter.activeWorkerCount, 2, "replacement work should consume the released slot")

        // Release is idempotent; timeout and late-completion paths may both
        // drop references to the same lease.
        first.release()
        assertEqual(limiter.activeWorkerCount, 2, "double release must not open an extra slot")
        second.release()
        replacement.release()
        assertEqual(limiter.activeWorkerCount, 0, "all completed workers should release their slots")
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

        assertTrue(
            state.canStartImmediately(reservedHandoffCount: 0),
            "idle inference should start immediately when no handoff is reserved"
        )

        state.begin()
        state.begin()
        assertTrue(state.isActive, "any active CoreML inference should block manager cleanup")
        assertFalse(
            state.canStartImmediately(reservedHandoffCount: 0),
            "active decoder work should serialize the next inference"
        )
        assertEqual(state.activeCount, 2, "nested activity should keep an exact count")

        state.finish()
        assertTrue(state.isActive, "one completed inference should not clear cleanup protection while another remains")
        assertEqual(state.activeCount, 1, "finish should decrement one active inference")

        state.finish()
        assertFalse(state.isActive, "cleanup protection can clear once every inference is done")
        assertEqual(state.activeCount, 0, "activity count should return to zero")
        assertFalse(
            state.canStartImmediately(reservedHandoffCount: 1),
            "a reserved handoff should block another caller from slipping into CoreML before the next waiter begins"
        )

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

    runSuite("ParakeetAudioFormatReadinessPolicy defers suppressed Bluetooth recovery speech bus") {
        for outputRate in [8_000.0, 16_000.0, 24_000.0] {
            let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: outputRate,
                outputChannelCount: 3,
                inputSampleRate: 48_000,
                inputChannelCount: 1,
                selectedInputClass: "bluetooth",
                outputDeviceClass: "bluetooth",
                selectionOverrodeDefault: false,
                selectionReason: .builtInFallbackSuppressedForRecoveryAttempt
            )

            assertEqual(readiness, .routeNotSettled, "suppressed recovery should wait instead of recording on a low-rate Bluetooth output bus \(outputRate)")
            assertEqual(readiness.startFailureReason, .audioRouteNotSettled, "suppressed Bluetooth recovery should remain a recoverable route-settling failure")
        }
    }

    runSuite("ParakeetAudioFormatReadinessPolicy allows settled suppressed Bluetooth recovery bus") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 24_000,
            inputChannelCount: 1,
            selectedInputClass: "bluetooth",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: false,
            selectionReason: .builtInFallbackSuppressedForRecoveryAttempt
        )

        assertEqual(readiness, .ready, "suppressed recovery should still allow a settled Bluetooth capture bus")
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

    runSuite("ParakeetSampleSignalPolicy distinguishes zero callbacks from real signal") {
        assertFalse(
            ParakeetSampleSignalPolicy.hasNonZeroSignal([]),
            "empty buffers should not count as signal"
        )
        assertFalse(
            ParakeetSampleSignalPolicy.hasNonZeroSignal([0, 0, 0]),
            "all-zero buffers should not mark the microphone route healthy"
        )
        assertFalse(
            ParakeetSampleSignalPolicy.hasNonZeroSignal([0, 0.000_000_1, -0.000_000_5]),
            "sub-threshold noise should not defeat the zero-route watchdog"
        )
        assertTrue(
            ParakeetSampleSignalPolicy.hasNonZeroSignal([0, 0.000_01, 0]),
            "normal mic noise or speech should count as real sample signal"
        )
    }

    runSuite("ParakeetSampleSignalPolicy scopes zero-signal restart to risky routes") {
        assertTrue(
            ParakeetSampleSignalPolicy.shouldResetStartupAudio(
                sampleCount: 0,
                hasNonZeroSignal: false,
                isLikelyBluetoothHandsFreeRoute: false
            ),
            "no callbacks should still trigger startup recovery on any route"
        )
        assertFalse(
            ParakeetSampleSignalPolicy.shouldResetStartupAudio(
                sampleCount: 512,
                hasNonZeroSignal: false,
                isLikelyBluetoothHandsFreeRoute: false
            ),
            "normal initial silence should not look like a dead engine"
        )
        assertTrue(
            ParakeetSampleSignalPolicy.shouldResetStartupAudio(
                sampleCount: 512,
                hasNonZeroSignal: false,
                isLikelyBluetoothHandsFreeRoute: true
            ),
            "zero-only buffers on Bluetooth HFP should recover from the garbled route"
        )
        assertFalse(
            ParakeetSampleSignalPolicy.shouldResetStartupAudio(
                sampleCount: 512,
                hasNonZeroSignal: true,
                isLikelyBluetoothHandsFreeRoute: true
            ),
            "real signal on Bluetooth HFP should not be restarted"
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

    runSuite("A rewarm that timed out on a wedged queue abandons the graph instead of queuing a rebuild") {
        // The AirPods/Bluetooth route-switch hang: the recovery snapshot times out
        // because the serial engine queue is stuck in CoreAudio. A rebuild queued
        // behind it never runs and strands the recording until force-quit.
        let timedOut = ParakeetAudioEngineWorkError.timedOut(operation: "device_recovery", timeoutMs: 1500)
        assertEqual(
            ParakeetDeviceRecoveryFailurePolicy.graphRepair(after: timedOut),
            .abandonBlockedAudioGraph,
            "a timed-out rewarm must swap in a fresh engine and queue synchronously"
        )
    }

    runSuite("A rewarm skipped by the open circuit keeps the current graph") {
        let circuitOpen = ParakeetAudioEngineWorkError.circuitOpen(operation: "device_recovery", activeWorkers: 2)
        assertEqual(
            ParakeetDeviceRecoveryFailurePolicy.graphRepair(after: circuitOpen),
            .keepCurrentGraph,
            "work that never entered the queue must not retire another healthy graph"
        )
    }

    runSuite("Any other rewarm failure rebuilds on the live queue") {
        struct FormatProbeFailed: Error {}
        assertEqual(
            ParakeetDeviceRecoveryFailurePolicy.graphRepair(after: FormatProbeFailed()),
            .rebuildOnAudioEngineQueue,
            "a responsive queue can still rebuild the engine in place"
        )
        assertEqual(
            ParakeetDeviceRecoveryFailurePolicy.graphRepair(after: CancellationError()),
            .rebuildOnAudioEngineQueue,
            "a non-engine error is not evidence that the queue is wedged"
        )
    }

    runSuite("Only a brand-new start gets a fresh recording identity") {
        assertTrue(
            ParakeetRecordingContinuityPolicy.startsFreshRecording(isRecoveryAttempt: false, preservingAcrossRecovery: false),
            "a user's new dictation starts a fresh recording"
        )
        assertFalse(
            ParakeetRecordingContinuityPolicy.startsFreshRecording(isRecoveryAttempt: true, preservingAcrossRecovery: false),
            "a zombie or device recovery restart continues the same dictation"
        )
        assertFalse(
            ParakeetRecordingContinuityPolicy.startsFreshRecording(isRecoveryAttempt: false, preservingAcrossRecovery: true),
            "a route restart while earlier segments are held must not relabel them as a new dictation"
        )
    }

    runSuite("A stop while idle keeps recovered speech ahead of a pending zombie restart") {
        assertEqual(
            ParakeetRecordingContinuityPolicy.idleStopAction(
                preservingAcrossRecovery: false,
                hasRecoveredAudio: true,
                zombieRestartPending: true
            ),
            .drainRecoveredAudio,
            "real pre-interruption speech must be transcribed, not discarded with the retry"
        )
        assertEqual(
            ParakeetRecordingContinuityPolicy.idleStopAction(
                preservingAcrossRecovery: true,
                hasRecoveredAudio: false,
                zombieRestartPending: false
            ),
            .drainRecoveredAudio,
            "a recovery that is still holding the recording keeps it on stop"
        )
        assertEqual(
            ParakeetRecordingContinuityPolicy.idleStopAction(
                preservingAcrossRecovery: false,
                hasRecoveredAudio: false,
                zombieRestartPending: true
            ),
            .cancelPendingZombieRestart,
            "with nothing kept, a stop during the zombie retry window cancels the restart"
        )
        assertEqual(
            ParakeetRecordingContinuityPolicy.idleStopAction(
                preservingAcrossRecovery: false,
                hasRecoveredAudio: false,
                zombieRestartPending: false
            ),
            .settleIdleGraph,
            "a plain idle stop has no recovery to keep or cancel"
        )
    }
}
