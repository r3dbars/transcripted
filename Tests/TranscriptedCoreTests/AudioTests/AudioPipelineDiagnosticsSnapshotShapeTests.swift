import XCTest
@testable import TranscriptedCore

// Privacy-payload-shape regression guard for AudioPipelineDiagnosticsSnapshot.
//
// The bucketing helpers (successRateBucket / deviceClass / rateString /
// nominalRate) are `private static` inside AudioPipelineDiagnosticsSnapshot.swift,
// which is outside this change's editable scope, so they cannot be exercised
// directly here. Instead this guards the surface that actually leaves the
// device: the public memberwise initializer and the privacySafeContext mapping.
// If anyone renames a key, drops a field, or leaks a non-bucketed value into the
// off-device payload, these assertions fail.
@available(macOS 14.0, *)
final class AudioPipelineDiagnosticsSnapshotShapeTests: XCTestCase {

    private func makeSnapshot() -> AudioPipelineDiagnosticsSnapshot {
        AudioPipelineDiagnosticsSnapshot(
            inputDeviceClass: "built_in",
            outputDeviceClass: "bluetooth",
            systemOutputDeviceClass: "usb",
            inputRateHz: "48000",
            outputRateHz: "44100",
            systemOutputRateHz: "48000",
            systemRateHz: "16000",
            inputChannels: "1",
            systemChannels: "2",
            systemBackend: "sck",
            systemStatus: "healthy",
            bufferSuccessBucket: "98_100",
            gapCount: 2,
            routeChangeCount: 1,
            recoveryAttemptCount: 3,
            selectionReason: "preservedDefaultInput",
            stabilizationAttemptBucket: "1",
            stabilizationOutcome: "switched_to_built_in",
            routeStabilityWarning: true,
            micRecovering: true,
            systemFailed: false,
            voiceProcessingRequested: false,
            voiceProcessingActive: false,
            voiceProcessingStartFallback: "attempted",
            softwareAGCRequested: true,
            realtimeAGCActive: true,
            micRawPeak: "0.03000",
            micProcessedPeak: "0.36000",
            systemAudioPeak: "0.25000",
            defaultInputVolumeBefore: "0.50",
            defaultOutputVolumeBefore: "0.60",
            defaultSystemOutputVolumeBefore: "0.70",
            defaultInputVolumeDuring: "0.55",
            defaultOutputVolumeDuring: "0.65",
            defaultSystemOutputVolumeDuring: "0.75",
            capturedInputVolumeBefore: "0.40",
            capturedInputVolumeDuring: "0.45"
        )
    }

    func testPrivacySafeContextMapsEveryField() {
        let context = makeSnapshot().privacySafeContext

        XCTAssertEqual(context["input_device_class"], "built_in")
        XCTAssertEqual(context["output_device_class"], "bluetooth")
        XCTAssertEqual(context["system_output_device_class"], "usb")
        XCTAssertEqual(context["input_rate_hz"], "48000")
        XCTAssertEqual(context["output_rate_hz"], "44100")
        XCTAssertEqual(context["system_output_rate_hz"], "48000")
        XCTAssertEqual(context["system_rate_hz"], "16000")
        XCTAssertEqual(context["input_channels"], "1")
        XCTAssertEqual(context["system_channels"], "2")
        XCTAssertEqual(context["system_backend"], "sck")
        XCTAssertEqual(context["system_status"], "healthy")
        XCTAssertEqual(context["buffer_success_bucket"], "98_100")
        XCTAssertEqual(context["gap_count"], "2")
        XCTAssertEqual(context["route_change_count"], "1")
        XCTAssertEqual(context["recovery_attempt_count"], "3")
        XCTAssertEqual(context["selection_reason"], "preservedDefaultInput")
        XCTAssertEqual(context["stabilization_attempt_bucket"], "1")
        XCTAssertEqual(context["stabilization_outcome"], "switched_to_built_in")
        XCTAssertEqual(context["route_stability_warning"], "true")
        XCTAssertEqual(context["mic_recovering"], "true")
        XCTAssertEqual(context["system_failed"], "false")
        XCTAssertEqual(context["voice_processing"], "false")
        XCTAssertEqual(context["voice_processing_active"], "false")
        XCTAssertEqual(context["voice_processing_start_fallback"], "attempted")
        XCTAssertEqual(context["realtime_agc"], "true")
        XCTAssertEqual(context["mic_raw_peak"], "0.03000")
        XCTAssertEqual(context["mic_processed_peak"], "0.36000")
        XCTAssertEqual(context["system_peak"], "0.25000")
        XCTAssertEqual(context["default_input_volume_before"], "0.50")
        XCTAssertEqual(context["default_output_volume_before"], "0.60")
        XCTAssertEqual(context["default_system_output_volume_before"], "0.70")
        XCTAssertEqual(context["default_input_volume_during"], "0.55")
        XCTAssertEqual(context["default_output_volume_during"], "0.65")
        XCTAssertEqual(context["default_system_output_volume_during"], "0.75")
        XCTAssertEqual(context["captured_input_volume_before"], "0.40")
        XCTAssertEqual(context["captured_input_volume_during"], "0.45")
        XCTAssertEqual(context["system_tap_step"], "none", "no tap failure defaults to none")
        XCTAssertEqual(context["system_tap_status"], "none", "no tap failure defaults to none")
        XCTAssertEqual(context["system_end_reason"], "none")
        XCTAssertEqual(context["system_wake_reconnects"], "0")
        XCTAssertEqual(context["system_silent_unresolved"], "false")
        XCTAssertEqual(context["mic_format_rebuilds"], "0")
    }

    func testTapUpkeepCountsMapToContext() {
        var snapshot = makeSnapshot()
        var tap = SystemAudioTapDiagnostics()
        tap.wakeReconnects = 2
        tap.formatReconnects = 1
        tap.silentAfterWakeReconnects = 3
        tap.stallReconnects = 1
        tap.rebuildRetries = 4
        tap.sleeps = 2
        tap.silentAfterWakeUnresolved = true
        tap.endReason = "reconnect_failed"
        snapshot.systemTap = tap
        snapshot.micFormatRebuildCount = 1
        let context = snapshot.privacySafeContext

        XCTAssertEqual(context["system_wake_reconnects"], "2")
        XCTAssertEqual(context["system_format_reconnects"], "1")
        XCTAssertEqual(context["system_silent_reconnects"], "3")
        XCTAssertEqual(context["system_stall_reconnects"], "1")
        XCTAssertEqual(context["system_rebuild_retries"], "4")
        XCTAssertEqual(context["system_sleep_count"], "2")
        XCTAssertEqual(context["system_silent_unresolved"], "true")
        XCTAssertEqual(context["system_end_reason"], "reconnect_failed")
        XCTAssertEqual(context["mic_format_rebuilds"], "1")
    }

    func testSilentPlaybackWatchFoldsIntoTheSilentTapKeys() {
        var snapshot = makeSnapshot()
        var tap = SystemAudioTapDiagnostics()
        tap.silentAfterWakeReconnects = 1
        tap.silentPlaybackReconnects = 1
        tap.unheardPlayback = true
        snapshot.systemTap = tap
        let context = snapshot.privacySafeContext

        XCTAssertEqual(context["system_silent_reconnects"], "2", "wake and playback watches share one count")
        XCTAssertEqual(context["system_silent_unresolved"], "true", "a tap that never heard the playing call is unresolved")
    }

    func testTapFailureMapsToCoarseCodes() {
        var snapshot = makeSnapshot()
        let failure = SystemAudioTapFailure(operation: "aggregate creation", status: -10877)
        snapshot.systemTapFailedStep = failure.step
        snapshot.systemTapFailedStatus = failure.status

        XCTAssertEqual(snapshot.privacySafeContext["system_tap_step"], "aggregate_creation")
        XCTAssertEqual(snapshot.privacySafeContext["system_tap_status"], "neg10877")
    }

    func testTapFailureCodesStayCategorical() {
        XCTAssertEqual(SystemAudioTapFailure(operation: "own-process lookup", status: 0x6E6F7065).step, "own_process_lookup")
        XCTAssertEqual(SystemAudioTapFailure(operation: "tap creation", status: 0x6E6F7065).status, "1852797029")
        XCTAssertEqual(SystemAudioTapFailure(operation: "start", status: Int32.min).status, "neg2147483648")
        XCTAssertEqual(SystemAudioTapFailure(operation: "unsupported format", status: nil), SystemAudioTapFailure(step: "unsupported_format", status: "none"))
        XCTAssertEqual(SystemAudioTapFailure.none.step, "none")
    }

    func testMicProcessingKeyDerivesFromVoiceProcessingRequested() {
        // mic_processing is a derived label, not a stored field — guard both arms.
        var requested = makeSnapshot()
        requested = AudioPipelineDiagnosticsSnapshot(
            inputDeviceClass: requested.inputDeviceClass,
            outputDeviceClass: requested.outputDeviceClass,
            systemOutputDeviceClass: requested.systemOutputDeviceClass,
            inputRateHz: requested.inputRateHz,
            outputRateHz: requested.outputRateHz,
            systemOutputRateHz: requested.systemOutputRateHz,
            systemRateHz: requested.systemRateHz,
            inputChannels: requested.inputChannels,
            systemChannels: requested.systemChannels,
            systemBackend: requested.systemBackend,
            systemStatus: requested.systemStatus,
            bufferSuccessBucket: requested.bufferSuccessBucket,
            gapCount: requested.gapCount,
            routeChangeCount: requested.routeChangeCount,
            recoveryAttemptCount: requested.recoveryAttemptCount,
            selectionReason: requested.selectionReason,
            stabilizationAttemptBucket: requested.stabilizationAttemptBucket,
            stabilizationOutcome: requested.stabilizationOutcome,
            routeStabilityWarning: requested.routeStabilityWarning,
            micRecovering: requested.micRecovering,
            systemFailed: requested.systemFailed,
            voiceProcessingRequested: true,
            voiceProcessingActive: requested.voiceProcessingActive,
            voiceProcessingStartFallback: requested.voiceProcessingStartFallback,
            softwareAGCRequested: false,
            realtimeAGCActive: requested.realtimeAGCActive,
            micRawPeak: requested.micRawPeak,
            micProcessedPeak: requested.micProcessedPeak,
            systemAudioPeak: requested.systemAudioPeak,
            defaultInputVolumeBefore: requested.defaultInputVolumeBefore,
            defaultOutputVolumeBefore: requested.defaultOutputVolumeBefore,
            defaultSystemOutputVolumeBefore: requested.defaultSystemOutputVolumeBefore,
            defaultInputVolumeDuring: requested.defaultInputVolumeDuring,
            defaultOutputVolumeDuring: requested.defaultOutputVolumeDuring,
            defaultSystemOutputVolumeDuring: requested.defaultSystemOutputVolumeDuring,
            capturedInputVolumeBefore: requested.capturedInputVolumeBefore,
            capturedInputVolumeDuring: requested.capturedInputVolumeDuring
        )

        XCTAssertEqual(requested.privacySafeContext["mic_processing"], "apple_voice_processing")
        XCTAssertEqual(makeSnapshot().privacySafeContext["mic_processing"], "software_agc")

        let off = AudioPipelineDiagnosticsSnapshot(
            inputDeviceClass: requested.inputDeviceClass,
            outputDeviceClass: requested.outputDeviceClass,
            systemOutputDeviceClass: requested.systemOutputDeviceClass,
            inputRateHz: requested.inputRateHz,
            outputRateHz: requested.outputRateHz,
            systemOutputRateHz: requested.systemOutputRateHz,
            systemRateHz: requested.systemRateHz,
            inputChannels: requested.inputChannels,
            systemChannels: requested.systemChannels,
            systemBackend: requested.systemBackend,
            systemStatus: requested.systemStatus,
            bufferSuccessBucket: requested.bufferSuccessBucket,
            gapCount: requested.gapCount,
            routeChangeCount: requested.routeChangeCount,
            recoveryAttemptCount: requested.recoveryAttemptCount,
            selectionReason: requested.selectionReason,
            stabilizationAttemptBucket: requested.stabilizationAttemptBucket,
            stabilizationOutcome: requested.stabilizationOutcome,
            routeStabilityWarning: requested.routeStabilityWarning,
            micRecovering: requested.micRecovering,
            systemFailed: requested.systemFailed,
            voiceProcessingRequested: false,
            voiceProcessingActive: false,
            voiceProcessingStartFallback: "none",
            softwareAGCRequested: false,
            realtimeAGCActive: false,
            micRawPeak: requested.micRawPeak,
            micProcessedPeak: requested.micProcessedPeak,
            systemAudioPeak: requested.systemAudioPeak,
            defaultInputVolumeBefore: requested.defaultInputVolumeBefore,
            defaultOutputVolumeBefore: requested.defaultOutputVolumeBefore,
            defaultSystemOutputVolumeBefore: requested.defaultSystemOutputVolumeBefore,
            defaultInputVolumeDuring: requested.defaultInputVolumeDuring,
            defaultOutputVolumeDuring: requested.defaultOutputVolumeDuring,
            defaultSystemOutputVolumeDuring: requested.defaultSystemOutputVolumeDuring,
            capturedInputVolumeBefore: requested.capturedInputVolumeBefore,
            capturedInputVolumeDuring: requested.capturedInputVolumeDuring
        )

        XCTAssertEqual(off.privacySafeContext["mic_processing"], "none")
    }
}
