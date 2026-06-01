import Foundation

/// Result of a stop request. `didTimeOut == true` means we did not receive
/// `Audio.onRecordingComplete` within `meetingStopTimeout`, so the WAV files
/// at the returned URLs may not be fully finalized — the controller should
/// route the audio to the failed queue rather than enqueuing for transcription.
struct CaptureStopResult {
    let micURL: URL?
    let systemURL: URL?
    let didTimeOut: Bool
}

final class MeetingCaptureAttempt<Output> {
    private var continuation: CheckedContinuation<Output, Never>?
    private var attemptID: UUID?
    private var timeoutTask: Task<Void, Never>?

    deinit {
        timeoutTask?.cancel()
    }

    func begin(_ continuation: CheckedContinuation<Output, Never>) -> UUID {
        let attemptID = UUID()
        self.continuation = continuation
        self.attemptID = attemptID
        return attemptID
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        timeoutTask?.cancel()
        timeoutTask = task
    }

    func reset() -> CheckedContinuation<Output, Never>? {
        let continuation = continuation
        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        attemptID = nil
        return continuation
    }

    func resetIfCurrent(_ attemptID: UUID) -> CheckedContinuation<Output, Never>? {
        guard self.attemptID == attemptID else { return nil }
        return reset()
    }
}

enum MeetingCaptureVolumeDiagnostics {
    private static let changeThreshold = 0.02
    private static let quietMicRawPeakThreshold = 0.05
    private static let usableMicProcessedPeakThreshold = 0.12
    private static let routePrefixes = [
        "default_input",
        "default_output",
        "default_system_output",
    ]

    static func annotatedStopContext(
        baseContext: [String: String],
        afterStopContext: [String: String]
    ) -> [String: String] {
        var context = baseContext.merging(afterStopContext, uniquingKeysWith: { _, new in new })

        for prefix in routePrefixes {
            let change = volumeChange(
                before: context["\(prefix)_volume_before"],
                after: context["\(prefix)_volume_after"] ?? context["\(prefix)_volume_during"]
            )
            context["\(prefix)_volume_changed"] = change.changedState
            context["\(prefix)_volume_dropped"] = change.droppedState
        }

        let capturedInputVolumeBefore = context["captured_input_volume_before"]
        let capturedInputVolumeCurrent = context["captured_input_volume_after"] ?? context["captured_input_volume_during"]
        let capturedInputContextPresent = capturedInputVolumeBefore != nil || capturedInputVolumeCurrent != nil
        let capturedInputChange = volumeChange(
            before: capturedInputVolumeBefore,
            after: capturedInputVolumeCurrent
        )
        context["captured_input_volume_changed"] = capturedInputChange.changedState
        context["captured_input_volume_dropped"] = capturedInputChange.droppedState

        let quietMicState = quietMicRecoveryState(
            rawPeak: context["mic_raw_peak"],
            processedPeak: context["mic_processed_peak"]
        )
        context["quiet_mic_recovered"] = quietMicState.recovered
        context["quiet_mic_unrecovered"] = quietMicState.unrecovered

        // Issue #500: classify WHICH attenuation (if any) hit this recording so
        // reports can tell the two distinct sub-bugs apart instead of lumping
        // every quiet mic together. `input_volume_scalar_available` records
        // whether the hardware even exposes a readable input scalar (often
        // absent on Apple Silicon built-in mics), which is what makes the
        // scalar-drop case detectable in the first place.
        let capturedInputScalarAvailable = inputScalarReadable(
            before: capturedInputVolumeBefore,
            current: capturedInputVolumeCurrent
        )
        let defaultInputScalarAvailable = inputScalarReadable(
            before: context["default_input_volume_before"],
            current: context["default_input_volume_after"] ?? context["default_input_volume_during"]
        )
        let inputScalarAvailable = capturedInputContextPresent ? capturedInputScalarAvailable : defaultInputScalarAvailable
        context["input_volume_scalar_available"] = inputScalarAvailable ? "true" : "false"
        context["attenuation_kind"] = attenuationKind(
            quietMic: quietMicState,
            inputVolumeDropped: selectedInputVolumeDropState(
                captured: capturedInputChange.droppedState,
                capturedContextPresent: capturedInputContextPresent,
                defaultInput: context["default_input_volume_dropped"]
            )
        )

        context["output_ducking_detected"] = outputDuckingState(
            dropStates: [
                context["default_output_volume_dropped"],
                context["default_system_output_volume_dropped"],
                optionalVolumeDrop(
                    before: context["default_output_volume_before"],
                    after: context["default_output_volume_during"]
                ),
                optionalVolumeDrop(
                    before: context["default_system_output_volume_before"],
                    after: context["default_system_output_volume_during"]
                ),
            ]
        )

        return context
    }

    private static func optionalVolumeDrop(before: String?, after: String?) -> String? {
        guard after != nil else { return nil }
        return volumeChange(before: before, after: after).droppedState
    }

    private static func volumeChange(before: String?, after: String?) -> (changedState: String, droppedState: String) {
        guard let before = scalarValue(before),
              let after = scalarValue(after) else {
            return ("unavailable", "unavailable")
        }

        let delta = after - before
        return (
            abs(delta) >= changeThreshold ? "true" : "false",
            delta <= -changeThreshold ? "true" : "false"
        )
    }

    private static func scalarValue(_ rawValue: String?) -> Double? {
        guard let rawValue,
              rawValue != "unavailable",
              let value = Double(rawValue),
              value.isFinite else {
            return nil
        }
        return value
    }

    private static func quietMicRecoveryState(
        rawPeak: String?,
        processedPeak: String?
    ) -> (recovered: String, unrecovered: String) {
        guard let rawPeak = scalarValue(rawPeak),
              let processedPeak = scalarValue(processedPeak) else {
            return ("unavailable", "unavailable")
        }

        guard rawPeak > 0, rawPeak < quietMicRawPeakThreshold else {
            return ("false", "false")
        }

        if processedPeak >= usableMicProcessedPeakThreshold {
            return ("true", "false")
        }

        return ("false", "true")
    }

    private static func inputScalarReadable(before: String?, current: String?) -> Bool {
        scalarValue(before) != nil || scalarValue(current) != nil
    }

    private static func selectedInputVolumeDropState(
        captured: String,
        capturedContextPresent: Bool,
        defaultInput: String?
    ) -> String? {
        capturedContextPresent ? captured : defaultInput
    }

    /// Classify which issue #500 sub-mechanism (if any) attenuated the mic on
    /// this recording, from facts already derived above:
    ///
    ///   - `scalar_drop`: a meeting app (classically Chrome/WebRTC) drove the
    ///     input device volume scalar down. A clean linear level change, fully
    ///     recoverable by gain.
    ///   - `voice_processed`: the raw mic was quiet but the input volume scalar
    ///     did NOT drop — the signature of a foreign app holding the shared
    ///     input device in macOS voice-processing / communication mode
    ///     (Zoom, native WhatsApp, an empty Google Meet). Nonlinear, lossy, and
    ///     only partially recoverable. This is issue #500's still-open case.
    ///   - `none`: the mic was not quiet; no attenuation observed.
    ///   - `unavailable`: not enough signal (no mic peak data) to classify.
    private static func attenuationKind(
        quietMic: (recovered: String, unrecovered: String),
        inputVolumeDropped: String?
    ) -> String {
        let micStateKnown = quietMic.recovered != "unavailable"
            || quietMic.unrecovered != "unavailable"
        guard micStateKnown else { return "unavailable" }

        let quiet = quietMic.recovered == "true" || quietMic.unrecovered == "true"
        guard quiet else { return "none" }

        if inputVolumeDropped == "true" { return "scalar_drop" }

        // Quiet raw mic with no visible scalar drop (whether the scalar was
        // readable-but-flat or unavailable) is voice-processing attenuation.
        return "voice_processed"
    }

    private static func outputDuckingState(dropStates: [String?]) -> String {
        let values = dropStates.compactMap { $0 }
        if values.contains("true") { return "true" }
        if values.allSatisfy({ $0 == "false" }) { return "false" }
        return "unavailable"
    }
}

enum MeetingAudioInactivityRecoveryPolicy {
    private static let longRecordingThreshold: TimeInterval = 10 * 60
    private static let routeChurnThreshold = 2

    static func warning(
        from warning: MeetingAudioInactivityWarning,
        durationSeconds: TimeInterval,
        diagnostics: [String: String]
    ) -> MeetingAudioInactivityWarning {
        let kind = warningKind(
            durationSeconds: durationSeconds,
            diagnostics: diagnostics
        )
        return MeetingAudioInactivityWarning(
            inactiveDuration: warning.inactiveDuration,
            countdownSeconds: warning.countdownSeconds,
            kind: kind,
            automaticStopAllowed: kind == .noAudio
        )
    }

    static func warningKind(
        durationSeconds: TimeInterval,
        diagnostics: [String: String]
    ) -> MeetingAudioInactivityWarning.Kind {
        guard durationSeconds >= longRecordingThreshold else {
            return .noAudio
        }

        let defaultInputDropped = diagnostics["default_input_volume_dropped"] == "true"
        let quietMicRecovered = diagnostics["quiet_mic_recovered"] == "true"
        let systemSilent = diagnostics["system_status"] == "silent"
        let routeChurned = intValue(diagnostics["route_change_count"]) >= routeChurnThreshold
        let bluetoothRoute = diagnostics["input_device_class"] == "bluetooth"
            || diagnostics["output_device_class"] == "bluetooth"
            || diagnostics["system_output_device_class"] == "bluetooth"

        if defaultInputDropped || (systemSilent && (routeChurned || bluetoothRoute || quietMicRecovered)) {
            return .degradedRoute
        }

        return .noAudio
    }

    private static func intValue(_ rawValue: String?) -> Int {
        guard let rawValue else { return 0 }
        return Int(rawValue) ?? 0
    }
}
