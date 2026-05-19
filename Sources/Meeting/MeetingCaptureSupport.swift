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

        let quietMicState = quietMicRecoveryState(
            rawPeak: context["mic_raw_peak"],
            processedPeak: context["mic_processed_peak"]
        )
        context["quiet_mic_recovered"] = quietMicState.recovered
        context["quiet_mic_unrecovered"] = quietMicState.unrecovered
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

    private static func outputDuckingState(dropStates: [String?]) -> String {
        let values = dropStates.compactMap { $0 }
        if values.contains("true") { return "true" }
        if values.allSatisfy({ $0 == "false" }) { return "false" }
        return "unavailable"
    }
}
