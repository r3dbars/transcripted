import Foundation

enum WorkflowRecoveryTelemetry {
    static func attempted(
        workflowKind: String,
        failureKind: String,
        retrySource: String,
        attempt: Int = 1,
        surface: String,
        artifactRetained: Bool
    ) {
        AnalyticsReporter.track(
            "workflow_recovery_attempted",
            properties: baseProperties(
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
        artifactRetained: Bool
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

        AnalyticsReporter.track(
            "workflow_recovery_finished",
            properties: properties
        )
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
            "attempt_bucket": AnalyticsReporter.countBucket(attempt),
            "surface": surface,
            "artifact_retained": artifactRetained ? "true" : "false",
        ]
    }
}
