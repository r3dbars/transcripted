import Foundation

enum WorkflowRecoveryTelemetry {
    /// `track` sends one analytics event. Production uses the default,
    /// `AnalyticsReporter.track`; tests pass a recorder.
    static func attempted(
        workflowKind: String,
        failureKind: String,
        retrySource: String,
        attempt: Int = 1,
        surface: String,
        artifactRetained: Bool,
        track: (String, [String: String]) -> Void = { event, properties in
            AnalyticsReporter.track(event, properties: properties)
        }
    ) {
        track(
            "workflow_recovery_attempted",
            baseProperties(
                workflowKind: workflowKind,
                failureKind: failureKind,
                retrySource: retrySource,
                attempt: attempt,
                surface: surface,
                artifactRetained: artifactRetained
            )
        )
    }

    static func finished(
        workflowKind: String,
        failureKind: String,
        retrySource: String,
        attempt: Int = 1,
        result: String,
        elapsedSeconds: TimeInterval? = nil,
        surface: String,
        artifactRetained: Bool,
        track: (String, [String: String]) -> Void = { event, properties in
            AnalyticsReporter.track(event, properties: properties)
        }
    ) {
        var properties = baseProperties(
            workflowKind: workflowKind,
            failureKind: failureKind,
            retrySource: retrySource,
            attempt: attempt,
            surface: surface,
            artifactRetained: artifactRetained
        )
        properties["result"] = result
        if let elapsedSeconds {
            properties["elapsed_bucket"] = AnalyticsReporter.durationBucket(seconds: elapsedSeconds)
        }

        track("workflow_recovery_finished", properties)

        if result == "failed" {
            track("workflow_recovery_failed", properties)
        }
    }

    private static func baseProperties(
        workflowKind: String,
        failureKind: String,
        retrySource: String,
        attempt: Int,
        surface: String,
        artifactRetained: Bool
    ) -> [String: String] {
        [
            "workflow_kind": workflowKind,
            "failure_kind": failureKind,
            "retry_source": retrySource,
            "recovery_attempt_bucket": AnalyticsReporter.countBucket(attempt),
            "surface": surface,
            "artifact_retained": artifactRetained ? "true" : "false",
        ]
    }
}
