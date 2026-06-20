import Foundation

enum MeetingCaptureHealthTelemetry {
    struct HealthFacts {
        let captureQuality: String
        let audioGaps: Int
        let deviceSwitches: Int
    }

    struct SnapshotInput {
        let captureDiagnostics: [String: String]
        let health: HealthFacts
        let trigger: String
        let reason: String
        let durationSeconds: Double
        let systemStreamPresent: Bool
        let stopTimedOut: Bool
    }

    struct DegradedReportInput {
        let captureDiagnostics: [String: String]
        let health: HealthFacts
        let trigger: String
        let reason: String
        let durationSeconds: Double
        let micFileAvailable: Bool
        let systemStreamPresent: Bool
        let stopTimedOut: Bool
        let systemFailed: Bool
        let systemStatus: String
    }

    static func snapshotProperties(_ input: SnapshotInput) -> [String: String] {
        input.captureDiagnostics.merging(
            sharedProperties(
                health: input.health,
                trigger: input.trigger,
                reason: input.reason,
                durationSeconds: input.durationSeconds,
                systemStreamPresent: input.systemStreamPresent,
                stopTimedOut: input.stopTimedOut
            ),
            uniquingKeysWith: { _, new in new }
        )
    }

    static func shouldReportDegraded(_ input: DegradedReportInput) -> Bool {
        input.stopTimedOut
            || !input.micFileAvailable
            || input.health.captureQuality == "degraded"
            || input.systemFailed
            || input.systemStatus == "failed"
    }

    static func degradedDiagnosticsContext(_ input: DegradedReportInput) -> [String: String]? {
        guard shouldReportDegraded(input) else { return nil }

        var context = input.captureDiagnostics
        context.removeValue(forKey: "gap_count")
        context.removeValue(forKey: "route_change_count")
        context.merge(
            sharedProperties(
                health: input.health,
                trigger: input.trigger,
                reason: input.reason,
                durationSeconds: input.durationSeconds,
                systemStreamPresent: input.systemStreamPresent,
                stopTimedOut: input.stopTimedOut
            ),
            uniquingKeysWith: { _, new in new }
        )
        context["mic_file_available"] = boolString(input.micFileAvailable)
        return context
    }

    private static func sharedProperties(
        health: HealthFacts,
        trigger: String,
        reason: String,
        durationSeconds: Double,
        systemStreamPresent: Bool,
        stopTimedOut: Bool
    ) -> [String: String] {
        [
            "capture_quality": health.captureQuality,
            "duration_bucket": AnalyticsReporter.durationBucket(seconds: durationSeconds),
            "gap_count_bucket": AnalyticsReporter.countBucket(health.audioGaps),
            "reason": reason,
            "route_change_count_bucket": AnalyticsReporter.countBucket(health.deviceSwitches),
            "system_stream_present": boolString(systemStreamPresent),
            "stop_timed_out": boolString(stopTimedOut),
            "trigger": trigger,
        ]
    }

    private static func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}
