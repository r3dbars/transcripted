// ParakeetStartRecordingFailurePolicyTests.swift
//
// Two kinds of coverage live in this file; they are NOT the same strength of proof:
//
// REAL BEHAVIORAL COVERAGE (compiled): every `runSuite` from the top of the file
// down through the CoreAudio-error mapping suites exercises Foundation-pure decision
// types that are actually compiled into the fast-test runner —
// ParakeetStartRecordingFailurePolicy, ParakeetDeviceRecoveryFailurePolicy /
// ReadinessPolicy / TimeoutPolicy, ParakeetAudioEngineRetirementPolicy,
// ParakeetASRManagerCleanupPolicy, ParakeetASRInferenceActivityState,
// ParakeetAudioFormatReadinessPolicy, ParakeetInputOverrideSettlePolicy, and
// ParakeetTapSampleRatePolicy. These run the real logic and assert real outputs.
//
// IMPLEMENTATION-PINNING STRUCTURAL CONTRACTS (NOT compiled): the final two suites
// ("zombie watchdog marks recording idle before graph reset" and "stopRecording
// cancels pending zombie restart while idle") read Sources/Speech/ParakeetEngine.swift
// as TEXT and grep for relative ordering of statements. ParakeetEngine's teardown is
// CoreAudio/Carbon-wired and is NOT compiled into this Foundation-only runner, so these
// greps pin source structure, not runtime behavior. They guard REAL invariants that
// caused real AirPods / zombie-recording bugs (mark recording idle before touching
// CoreAudio; gate the zombie retry on the pending-restart flag so a user stop can cancel
// it). They are intentionally kept as source-text contracts rather than a runtime seam:
// extracting a seam would restructure real-time CoreAudio teardown control flow, which is
// too risky to refactor for testability. If you move/rename these functions or reorder
// their statements, update both the source and these greps together.

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

    runSuite("ParakeetEngine zombie watchdog uses a bounded fresh-engine recovery") {
        let source = readParakeetEngineSource()
        guard let watchdogStart = source.range(of: "private func startAudioWatchdog()"),
              let watchdogEnd = source.range(of: "func stopRecording()", range: watchdogStart.upperBound..<source.endIndex),
              let recordingStart = source.range(of: "func startRecording(isRecoveryAttempt: Bool = false) async -> Bool"),
              let recordingEnd = source.range(of: "/// Begin dictation by borrowing", range: recordingStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the zombie watchdog body")
            return
        }
        let watchdog = String(source[watchdogStart.lowerBound..<watchdogEnd.lowerBound])
        let recordingBody = String(source[recordingStart.lowerBound..<recordingEnd.lowerBound])
        guard let beginRecovery = watchdog.range(of: "self.startZombieEngineRecovery(failureKind: failureKind)"),
              let markResetStage = watchdog.range(of: "zombieRecoveryState.advance(to: .reset"),
              let markIdle = watchdog.range(of: "isRecording = false", range: markResetStage.upperBound..<watchdog.endIndex),
              let eouReset = watchdog.range(of: "await eouManager?.reset()", range: markIdle.upperBound..<watchdog.endIndex),
              let postEOUOwnershipGate = watchdog.range(of: "expectedOwner: recoveryGraphOwner", range: eouReset.upperBound..<watchdog.endIndex),
              let recreate = watchdog.range(of: "guard await recreateAudioEngineForZombieRecovery(", range: postEOUOwnershipGate.upperBound..<watchdog.endIndex),
              let settleStage = watchdog.range(of: "zombieRecoveryState.advance(to: .settle"),
              let restartStage = watchdog.range(of: "zombieRecoveryState.advance(to: .restart"),
              let preserveRecovery = watchdog.range(of: "zombieRecoveryStartGeneration = generation"),
              let retryStart = watchdog.range(of: "await startRecording(isRecoveryAttempt: true)"),
              let recreationStart = watchdog.range(of: "private func recreateAudioEngineForZombieRecovery("),
              let recreationEnd = watchdog.range(of: "func currentAudioGraphOwnerToken()", range: recreationStart.upperBound..<watchdog.endIndex) else {
            assertTrue(false, "zombie watchdog should use the bounded fresh-engine recovery path")
            return
        }
        let recreationBody = String(watchdog[recreationStart.lowerBound..<recreationEnd.lowerBound])
        guard let entryOwnershipGate = recreationBody.range(of: "expectedOwner: expectedOwner"),
              let trackRebuild = recreationBody.range(of: "trackAudioEngineRebuildChurn(reason: \"zombie_engine_recovery\")"),
              let beginTimedOwnership = recreationBody.range(of: "zombieEngineWorkOwnership.begin(owner: resetQueueOwner, phase: .zombieReset)"),
              let timedReset = recreationBody.range(of: "runTimedAudioEngineWork(operation: \"zombie_engine_reset\")"),
              let finishTimedOwnership = recreationBody.range(of: "zombieEngineWorkOwnership.finish(", range: timedReset.upperBound..<recreationBody.endIndex),
              let timeoutOwnershipGate = recreationBody.range(of: "expectedOwner: resetOwner", range: timedReset.upperBound..<recreationBody.endIndex),
              let abandonBlocked = recreationBody.range(of: "reason: \"zombie_engine_reset_timeout\"", range: timeoutOwnershipGate.upperBound..<recreationBody.endIndex),
              let abandonQueueOwner = recreationBody.range(of: "expectedOwner: resetQueueOwner", range: abandonBlocked.upperBound..<recreationBody.endIndex),
              let successOwnershipGate = recreationBody.range(of: "expectedOwner: resetOwner", range: abandonBlocked.upperBound..<recreationBody.endIndex),
              let firstSharedFlagMutation = recreationBody.range(of: "inputTapInstalled = false", range: successOwnershipGate.upperBound..<recreationBody.endIndex),
              let freshEngine = recreationBody.range(of: "audioEngine = AVAudioEngine()", range: firstSharedFlagMutation.upperBound..<recreationBody.endIndex),
              let beginRestartOwnership = recordingBody.range(of: "phase: .zombieRecoveryStart"),
              let timedRestart = recordingBody.range(of: "try await installTapAndStartEngine", range: beginRestartOwnership.upperBound..<recordingBody.endIndex),
              let finishRestartOwnership = recordingBody.range(of: "phase: .zombieRecoveryStart", range: timedRestart.upperBound..<recordingBody.endIndex) else {
            assertTrue(false, "zombie graph recreation should guard entry, timeout, and successful completion")
            return
        }

        assertTrue(beginRecovery.lowerBound < markResetStage.lowerBound, "detection should create one generation-gated recovery attempt")
        assertTrue(markResetStage.lowerBound < markIdle.lowerBound, "zombie reset should enter its terminally tracked stage before publishing idle state")
        assertTrue(markIdle.lowerBound < eouReset.lowerBound, "recording must publish idle before resetting end-of-utterance state")
        assertTrue(eouReset.lowerBound < postEOUOwnershipGate.lowerBound, "the eou reset suspension must be followed by cancellation and graph ownership validation")
        assertTrue(postEOUOwnershipGate.lowerBound < recreate.lowerBound, "a cancelled or stale recovery must not enter graph recreation")
        assertTrue(markIdle.lowerBound < recreate.lowerBound, "recording must be idle before replacing the stale graph")
        assertTrue(recreate.lowerBound < settleStage.lowerBound, "the fresh engine must exist before the route settle delay")
        assertTrue(settleStage.lowerBound < restartStage.lowerBound, "settling must finish before the one restart attempt")
        assertTrue(restartStage.lowerBound < preserveRecovery.lowerBound, "restart telemetry should advance before entering the normal start path")
        assertTrue(preserveRecovery.lowerBound < retryStart.lowerBound, "the normal start path must know not to cancel its owning recovery task")
        assertTrue(entryOwnershipGate.lowerBound < trackRebuild.lowerBound, "recreation must validate exact ownership before any shared-state mutation")
        assertTrue(beginTimedOwnership.lowerBound < timedReset.lowerBound, "timed reset must publish engine+queue ownership before it can suspend")
        assertTrue(timedReset.lowerBound < finishTimedOwnership.lowerBound, "actual reset completion must retire only its exact timed-work owner")
        assertTrue(timedReset.lowerBound < timeoutOwnershipGate.lowerBound, "timed reset completion must revalidate exact ownership")
        assertTrue(timeoutOwnershipGate.lowerBound < abandonBlocked.lowerBound, "a stale timeout must not abandon a newer graph owner")
        assertTrue(abandonBlocked.lowerBound < abandonQueueOwner.lowerBound, "timeout abandonment must include the exact serial queue owner")
        assertTrue(abandonBlocked.lowerBound < successOwnershipGate.lowerBound, "the successful-completion branch needs its own ownership validation")
        assertTrue(successOwnershipGate.lowerBound < firstSharedFlagMutation.lowerBound, "stale reset completion must not clear tap, prewarm, or sample flags")
        assertTrue(firstSharedFlagMutation.lowerBound < freshEngine.lowerBound, "fresh engine assignment should follow guarded reset-state cleanup")
        assertTrue(beginRestartOwnership.lowerBound < timedRestart.lowerBound, "recovery restart must lease its exact engine and queue before install/start can block")
        assertTrue(timedRestart.lowerBound < finishRestartOwnership.lowerBound, "recovery restart completion must finish only its exact lease")
    }

    runSuite("ParakeetEngine delayed cleanup mutates only its exact graph owner") {
        let source = readParakeetEngineSource()
        guard let removeTapStart = source.range(of: "func removeRecordingTap(force: Bool = false) async"),
              let removeTapEnd = source.range(of: "/// Share the user-consented", range: removeTapStart.upperBound..<source.endIndex),
              let startFailureStart = source.range(of: "private func resetAudioGraphAfterStartFailure("),
              let startFailureEnd = source.range(of: "/// Tracks rebuild frequency", range: startFailureStart.upperBound..<source.endIndex),
              let rebuildStart = source.range(of: "func rebuildAudioEngine(reason: String) async"),
              let rebuildEnd = source.range(of: "func abandonBlockedAudioEngine", range: rebuildStart.upperBound..<source.endIndex),
              let failedStartCleanupStart = source.range(of: "func resetAfterFailedRecordingStart() async"),
              let failedStartCleanupEnd = source.range(of: "func abandonBlockedRecordingStart", range: failedStartCleanupStart.upperBound..<source.endIndex),
              let idleCleanupStart = source.range(of: "private func releaseIdleAudioHardware("),
              let idleCleanupEnd = source.range(of: "private func cancelAudioWatchdogForRecordingStart()", range: idleCleanupStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the delayed audio cleanup helpers")
            return
        }

        let removeTap = String(source[removeTapStart.lowerBound..<removeTapEnd.lowerBound])
        let startFailure = String(source[startFailureStart.lowerBound..<startFailureEnd.lowerBound])
        let rebuild = String(source[rebuildStart.lowerBound..<rebuildEnd.lowerBound])
        let failedStartCleanup = String(source[failedStartCleanupStart.lowerBound..<failedStartCleanupEnd.lowerBound])
        let idleCleanup = String(source[idleCleanupStart.lowerBound..<idleCleanupEnd.lowerBound])

        assertPostAwaitOwnershipGuard(
            in: removeTap,
            ownerCapture: "let tapOwner = currentAudioGraphOwnerToken()",
            suspension: "await runAudioEngineWork",
            guardStatement: "guard ownsAudioGraph(tapOwner) else { return }",
            mutation: "inputTapInstalled = false",
            helper: "removeRecordingTap"
        )
        assertPostAwaitOwnershipGuard(
            in: startFailure,
            ownerCapture: "let resetOwner = currentAudioGraphOwnerToken()",
            suspension: "await runAudioEngineWork",
            guardStatement: "guard ownsAudioGraph(resetOwner) else { return nil }",
            mutation: "inputTapInstalled = false",
            helper: "resetAudioGraphAfterStartFailure"
        )
        assertPostAwaitOwnershipGuard(
            in: rebuild,
            ownerCapture: "let rebuildOwner = currentAudioGraphOwnerToken()",
            suspension: "await runAudioEngineWork",
            guardStatement: "guard ownsAudioGraph(rebuildOwner) else { return nil }",
            mutation: "audioEngine = AVAudioEngine()",
            helper: "rebuildAudioEngine"
        )
        assertPostAwaitOwnershipGuard(
            in: failedStartCleanup,
            ownerCapture: "let failedStartCleanupOwner = currentAudioEngineQueueOwnerToken()",
            suspension: "await eouManager?.reset()",
            guardStatement: "guard ownsAudioEngineQueue(failedStartCleanupOwner) else { return }",
            mutation: "isRecording = false",
            helper: "resetAfterFailedRecordingStart"
        )
        assertPostAwaitOwnershipGuard(
            in: idleCleanup,
            ownerCapture: "let idleCleanupOwner = currentAudioEngineQueueOwnerToken()",
            suspension: "await removeRecordingTap(force: true)",
            guardStatement: "guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }",
            mutation: "await stopAudioEngine()",
            helper: "releaseIdleAudioHardware remove-tap completion"
        )

        guard let stopSuspension = idleCleanup.range(of: "await stopAudioEngine()"),
              let postStopGuard = idleCleanup.range(
                of: "guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }",
                range: stopSuspension.upperBound..<idleCleanup.endIndex
              ),
              let clearPrewarm = idleCleanup.range(of: "isEnginePrewarmed = false", range: postStopGuard.upperBound..<idleCleanup.endIndex) else {
            assertTrue(false, "releaseIdleAudioHardware should revalidate ownership after stopping the engine")
            return
        }
        assertTrue(
            stopSuspension.lowerBound < postStopGuard.lowerBound && postStopGuard.lowerBound < clearPrewarm.lowerBound,
            "releaseIdleAudioHardware must preserve a newer owner's prewarm state after delayed stop completion"
        )
    }

    runSuite("ParakeetEngine device-change rewarm abandons the wedged queue instead of re-queuing on it") {
        // Simulates a route change mid-stream: handleAudioConfigChange tears down
        // and schedules attemptDeviceRecovery; if the recovery snapshot times out
        // (queue wedged on a CoreAudio call during the AirPods/Bluetooth switch),
        // the catch block must hard-reset the graph rather than await
        // rebuildAudioEngine on the same blocked queue (which never returns and
        // strands the recording until the user force-quits).
        //
        // ParakeetEngine's recovery control flow is CoreAudio-wired and not
        // compiled into this Foundation-only runner, so this pins source structure.
        // It guards a REAL invariant behind the device_change_rewarm_failed (x207)
        // and app.unclean_shutdown_detected (x166) Sentry pair. If you move/rename
        // attemptDeviceRecovery or reorder its catch handling, update this together.
        //
        // Device-change detection/recovery lives in ParakeetDeviceRecovery.swift
        // (codebase audit 2026-07-08 wave 2) — read that file instead of
        // ParakeetEngine.swift.
        let source = readParakeetDeviceRecoverySource()
        guard let recoveryStart = source.range(of: "private func attemptDeviceRecovery()"),
              let recoveryEnd = source.range(of: "private func scheduleConfigRecoveryTimeout", range: recoveryStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the attemptDeviceRecovery body")
            return
        }
        let recovery = String(source[recoveryStart.lowerBound..<recoveryEnd.lowerBound])

        guard let catchClause = recovery.range(of: "} catch {"),
              let blockedProbe = recovery.range(of: "error is ParakeetAudioEngineWorkError", range: catchClause.upperBound..<recovery.endIndex),
              let strategySwitch = recovery.range(of: "ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(", range: catchClause.upperBound..<recovery.endIndex),
              let abandonCase = recovery.range(of: "reason: \"device_change_rewarm_failed\"", range: catchClause.upperBound..<recovery.endIndex),
              let expectedQueueOwner = recovery.range(of: "expectedOwner: lastSnapshotOwner", range: abandonCase.upperBound..<recovery.endIndex),
              let queuedRebuildCase = recovery.range(of: "await self.rebuildAudioEngine(reason: \"device_change_rewarm_failed\")", range: catchClause.upperBound..<recovery.endIndex) else {
            assertTrue(false, "rewarm catch must branch the graph recovery on whether the engine queue is blocked")
            return
        }

        assertTrue(blockedProbe.lowerBound < strategySwitch.lowerBound, "rewarm catch should detect a wedged engine queue before choosing a rebuild strategy")
        assertTrue(strategySwitch.lowerBound < abandonCase.lowerBound, "rewarm catch should route through the rebuild-strategy policy before abandoning the graph")
        assertTrue(abandonCase.lowerBound < expectedQueueOwner.lowerBound, "blocked rewarm must abandon only its captured engine+queue owner")
        assertTrue(strategySwitch.lowerBound < queuedRebuildCase.lowerBound, "the in-place rebuild must also sit behind the rebuild-strategy switch, not run unconditionally")

        // The blocked-queue rebuild MUST be the synchronous abandon path. An
        // `await rebuildAudioEngine` reached unconditionally (the old bug) would
        // hang on the wedged queue, so the awaited rebuild may only appear inside
        // the strategy switch alongside the abandon case.
        let queuedCount = recovery.components(separatedBy: "await self.rebuildAudioEngine(reason: \"device_change_rewarm_failed\")").count - 1
        assertEqual(queuedCount, 1, "there should be exactly one guarded in-place rebuild in the rewarm catch")
    }

    runSuite("ParakeetEngine ASR inference gate reserves handoff before admitting another decoder call") {
        // The TDT decoder is a shared CoreML object. If one inference finishes and
        // resumes a waiting continuation, a third caller must not observe
        // activeCount == 0 and start immediately before that resumed waiter begins.
        // This source contract pins the tiny handoff window that protects
        // dictation, meeting, and imported-audio transcription from overlapping
        // decoder calls.
        let source = readParakeetEngineSource()
        guard let gateStart = source.range(of: "private func beginASRInference()"),
              let gateEnd = source.range(of: "private func finishASRInference()", range: gateStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the ASR inference gate")
            return
        }
        let gate = String(source[gateStart.lowerBound..<gateEnd.lowerBound])

        guard let admissionCheck = gate.range(of: "asrInferenceActivity.canStartImmediately(reservedHandoffCount: asrInferenceHandoffCount)"),
              let begin = gate.range(of: "asrInferenceActivity.begin()"),
              let enqueueWaiter = gate.range(of: "asrInferenceWaiters.append(continuation)"),
              let consumeHandoff = gate.range(of: "asrInferenceHandoffCount = max(0, asrInferenceHandoffCount - 1)") else {
            assertTrue(false, "ASR inference admission should account for the reserved handoff slot")
            return
        }

        assertTrue(admissionCheck.lowerBound < begin.lowerBound, "handoff-aware admission should run before starting decoder work")
        assertTrue(begin.lowerBound < enqueueWaiter.lowerBound, "immediate starts should happen only before the wait path")
        assertTrue(enqueueWaiter.lowerBound < consumeHandoff.lowerBound, "queued waiters should consume the reserved handoff only after resuming")
    }

    runSuite("ParakeetEngine stopRecording cancels pending zombie restart while idle") {
        let source = readParakeetEngineSource()
        guard let stopStart = source.range(of: "func stopRecording()"),
              let stopEnd = source.range(of: "// MARK: - EOU Streaming", range: stopStart.upperBound..<source.endIndex),
              let startHelperStart = source.range(of: "private func cancelAudioWatchdogForRecordingStart()"),
              let cancelStart = source.range(of: "private func cancelZombieEngineRecovery()", range: startHelperStart.upperBound..<source.endIndex),
              let publicCancelStart = source.range(of: "func cancelAudioWatchdog()", range: cancelStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find stopRecording and watchdog cancellation bodies")
            return
        }
        let stopBody = String(source[stopStart.lowerBound..<stopEnd.lowerBound])
        let startHelperBody = String(source[startHelperStart.lowerBound..<cancelStart.lowerBound])
        let cancelBody = String(source[cancelStart.lowerBound..<source.endIndex])
        guard let pendingBranch = stopBody.range(of: "if zombieRecoveryRestartPending"),
              let graphBump = stopBody.range(of: "audioGraphGeneration += 1", range: pendingBranch.upperBound..<stopBody.endIndex),
              let stopOwner = stopBody.range(of: "let stopGraphGeneration = audioGraphGeneration", range: graphBump.upperBound..<stopBody.endIndex),
              let cancelWatchdog = stopBody.range(of: "cancelAudioWatchdog()", range: pendingBranch.upperBound..<stopBody.endIndex),
              let clearTimeline = stopBody.range(of: "clearRecoveredRecordingTimeline(keepingCapacity: true)", range: pendingBranch.upperBound..<stopBody.endIndex),
              let releaseHardware = stopBody.range(of: "await releaseIdleAudioHardware(", range: pendingBranch.upperBound..<stopBody.endIndex),
              let returnFromBranch = stopBody.range(of: "return", range: pendingBranch.upperBound..<stopBody.endIndex),
              let claimBlockedQueue = cancelBody.range(of: "zombieEngineWorkOwnership.claimPendingWorkForSuccessor("),
              let classifyBlockedQueue = cancelBody.range(of: "let reason = blockedLease.phase", range: claimBlockedQueue.upperBound..<cancelBody.endIndex),
              let recoveryStartReason = cancelBody.range(of: "\"zombie_engine_recovery_start_cancelled\"", range: classifyBlockedQueue.upperBound..<cancelBody.endIndex),
              let replaceBlockedQueue = cancelBody.range(of: "abandonBlockedAudioEngine(reason: reason)", range: recoveryStartReason.upperBound..<cancelBody.endIndex),
              let cancelTerminal = cancelBody.range(of: "zombieRecoveryState.cancelActiveAttempt()", range: replaceBlockedQueue.upperBound..<cancelBody.endIndex) else {
            assertTrue(false, "inactive stopRecording should cancel pending zombie recovery restart")
            return
        }

        assertTrue(graphBump.lowerBound < cancelWatchdog.lowerBound, "canceling a pending zombie restart should invalidate in-flight audio starts")
        assertTrue(graphBump.lowerBound < stopOwner.lowerBound, "stop should capture its new graph ownership generation")
        let stopInvalidationWindow = String(stopBody[graphBump.lowerBound..<cancelWatchdog.upperBound])
        assertFalse(stopInvalidationWindow.contains("await "), "stop should invalidate graph ownership and cancel the recovery in one actor turn")
        assertTrue(cancelWatchdog.lowerBound < returnFromBranch.lowerBound, "stopRecording should cancel the watchdog before returning from pending zombie restart")
        assertTrue(clearTimeline.lowerBound < returnFromBranch.lowerBound, "stopRecording should clear recovered timeline before returning from pending zombie restart")
        assertTrue(cancelWatchdog.lowerBound < releaseHardware.lowerBound, "stop should own old-graph teardown after cancelling zombie recreation")
        assertTrue(claimBlockedQueue.lowerBound < classifyBlockedQueue.lowerBound, "cancellation should classify the exact blocked recovery phase")
        assertTrue(classifyBlockedQueue.lowerBound < replaceBlockedQueue.lowerBound, "cancellation must synchronously claim and replace a still-blocked engine queue")
        assertTrue(replaceBlockedQueue.lowerBound < cancelTerminal.lowerBound, "blocked queue replacement must finish before cancellation publishes its terminal result")
        let blockedQueueReplacement = String(cancelBody[claimBlockedQueue.lowerBound..<cancelTerminal.lowerBound])
        assertFalse(blockedQueueReplacement.contains("await "), "successor queue replacement must happen in one MainActor turn")
        assertTrue(
            cancelBody.contains("zombieRecoveryTask?.cancel()")
                && cancelBody.contains("zombieRecoveryState.cancelActiveAttempt()"),
            "shared watchdog cancellation should cancel the task and consume its one terminal state"
        )
        assertTrue(
            startHelperBody.contains("zombieRecoveryState.canContinue(generation: zombieRecoveryStartGeneration)")
                && publicCancelStart.lowerBound > cancelStart.lowerBound,
            "normal recording starts should use the helper that preserves only their owning zombie recovery"
        )
        assertTrue(
            source.contains("guard !zombieRecoveryState.isActive else { return }")
                && source.contains("reportZombieEngineRecoveryTerminal(terminal)"),
            "duplicate detector callbacks should not replace an active attempt, and every terminal path should share one reporter"
        )
    }

    runSuite("ParakeetEngine config changes invalidate zombie ownership before cancellation can suspend") {
        let source = readParakeetDeviceRecoverySource()
        guard let handlerStart = source.range(of: "private func handleAudioConfigChange() async"),
              let handlerEnd = source.range(of: "private func recordStableRouteChangeAnalytics", range: handlerStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the audio config-change handler")
            return
        }
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        guard let graphBump = handler.range(of: "audioGraphGeneration += 1"),
              let cancelRecovery = handler.range(of: "cancelAudioWatchdog()", range: graphBump.upperBound..<handler.endIndex) else {
            assertTrue(false, "config changes should invalidate and cancel an in-flight zombie recovery")
            return
        }

        let invalidationWindow = String(handler[graphBump.lowerBound..<cancelRecovery.upperBound])
        assertTrue(graphBump.lowerBound < cancelRecovery.lowerBound, "config change must invalidate the graph owner before cancelling zombie recovery")
        assertFalse(invalidationWindow.contains("await "), "the stale zombie task must not resume between graph invalidation and cancellation")
    }

    runSuite("ParakeetEngine preserves recovered dictation audio for stop and wake recovery") {
        let source = readParakeetEngineSource()
        guard let wakeStart = source.range(of: "private func handleSystemWake()"),
              let wakeEnd = source.range(of: "// MARK: - Recording", range: wakeStart.upperBound..<source.endIndex),
              let stopStart = source.range(of: "func stopRecording()"),
              let stopEnd = source.range(of: "// MARK: - EOU Streaming", range: stopStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find wake and stopRecording bodies")
            return
        }

        let wakeBody = String(source[wakeStart.lowerBound..<wakeEnd.lowerBound])
        let stopBody = String(source[stopStart.lowerBound..<stopEnd.lowerBound])

        assertTrue(
            wakeBody.contains("preserveCurrentRecordingBuffersForRecovery()"),
            "system wake during dictation should move buffered speech into the recovered timeline before teardown"
        )
        assertTrue(
            wakeBody.contains("interruptRecordingPreservingRecoveredTimeline()"),
            "system wake should mark the interruption without clearing recovered audio"
        )
        assertTrue(
            stopBody.contains("preservingRecordingAcrossRecovery || !recoveredRecordingTimeline.isEmpty"),
            "stopRecording while recovery holds audio should preserve the timeline"
        )
        assertTrue(
            stopBody.contains("cancelPendingRecordingRecovery()"),
            "user stop during recovery should cancel pending restart tasks before transcribing recovered audio"
        )
        assertTrue(
            source.contains("var hasRecoverableRecording: Bool"),
            "the router/UI need a public engine signal for recovered dictation audio"
        )
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

private func assertPostAwaitOwnershipGuard(
    in body: String,
    ownerCapture: String,
    suspension: String,
    guardStatement: String,
    mutation: String,
    helper: String,
    file: String = #file,
    line: Int = #line
) {
    guard let capture = body.range(of: ownerCapture),
          let awaitPoint = body.range(of: suspension, range: capture.upperBound..<body.endIndex),
          let ownershipGuard = body.range(of: guardStatement, range: awaitPoint.upperBound..<body.endIndex),
          let sharedMutation = body.range(of: mutation, range: ownershipGuard.upperBound..<body.endIndex) else {
        assertTrue(false, "\(helper) should guard delayed completion before shared-state mutation", file: file, line: line)
        return
    }
    assertTrue(
        capture.lowerBound < awaitPoint.lowerBound
            && awaitPoint.lowerBound < ownershipGuard.lowerBound
            && ownershipGuard.lowerBound < sharedMutation.lowerBound,
        "\(helper) should capture owner, await work, revalidate owner, then mutate shared state",
        file: file,
        line: line
    )
}

/// Device-change detection/recovery lives in ParakeetDeviceRecovery.swift
/// (codebase audit 2026-07-08 wave 2), split out of ParakeetEngine.swift.
private func readParakeetDeviceRecoverySource(file: String = #file, line: Int = #line) -> String {
    let url = repoFixtureURL("Sources/Speech/ParakeetDeviceRecovery.swift")
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        totalTests += 1
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] could not read ParakeetDeviceRecovery.swift: \(error)")
        return ""
    }
}
