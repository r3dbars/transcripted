import Foundation

/// PostHog properties for how long a meeting took to turn into a saved
/// transcript, and where that time went. Timings are rounded to 10 ms, the
/// recording length to whole minutes, and the speech input to whole seconds,
/// so each value stays a coarse speed diagnostic. No audio, text, names, or
/// paths are involved.
enum MeetingProcessingTelemetry {
    struct Timings: Equatable {
        var processingSeconds: Double
        var sleepSeconds: Double
        var modelsReadySeconds: Double
        var resampleSeconds: Double
        var diarizeSeconds: Double
        var speechToTextSeconds: Double
        var speechToTextCalls: Int
        var speechToTextInputSeconds: Double
        var recordingSeconds: Double?
        var speechModel: String?
    }

    static func properties(
        for timings: Timings,
        machineClass: [String: String] = MachineClassTelemetry.current
    ) -> [String: String] {
        var properties: [String: String] = [
            "processing_ms": milliseconds(timings.processingSeconds),
            "sleep_ms": milliseconds(timings.sleepSeconds),
            "models_ready_ms": milliseconds(timings.modelsReadySeconds),
            "resample_ms": milliseconds(timings.resampleSeconds),
            "diarize_ms": milliseconds(timings.diarizeSeconds),
            "stt_ms": milliseconds(timings.speechToTextSeconds),
            "stt_calls": "\(max(0, timings.speechToTextCalls))",
            "stt_input_seconds": "\(wholeUnits(timings.speechToTextInputSeconds))",
        ]
        if let recordingSeconds = timings.recordingSeconds {
            properties["recording_minutes"] = "\(wholeUnits(recordingSeconds / 60))"
        }
        if let speechModel = timings.speechModel {
            properties["stt_model"] = speechModel
        }
        return properties.merging(machineClass, uniquingKeysWith: { current, _ in current })
    }

    private static func milliseconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0" }
        return MachineClassTelemetry.roundedMilliseconds(Int((seconds * 1_000).rounded()))
    }

    private static func wholeUnits(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(value.rounded())
    }
}
