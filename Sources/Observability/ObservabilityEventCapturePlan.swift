import Foundation

/// What `EventReporter.capture` sends where, worked out with no side effects
/// so the fast tests can check it. `EventReporter` runs the plan: it writes
/// `localEntry` to events.jsonl, hands `entry` to the reliability recorder,
/// tracks `forwarded` in PostHog, and reports `sentryPolicy` failures.
struct ObservabilityEventCapturePlan {
    /// The caller's context plus engine state, build identity, and telemetry
    /// enrichment. Sentry and the reliability-failure analytics event get this.
    let mergedContext: [String: String]
    /// The raw entry. The reliability recorder positive-allowlists and redacts
    /// every value itself, so it must see this one, not `localEntry`.
    let entry: ObservabilityEvent
    /// The locally sanitized copy that goes to disk.
    let localEntry: ObservabilityEvent
    /// The PostHog event, built only from the caller's own context.
    let forwarded: AnalyticsEventForwardingPolicy.ForwardedEvent?
    /// Set for allowlisted hard failures.
    let sentryPolicy: SentryEventPolicy?

    static func make(
        level: EventLevel,
        engine: String,
        event: String,
        message: String,
        context: [String: String]?,
        engineState: [String: String]?,
        infoDictionary: [String: Any]?,
        timestamp: String,
        appVersion: String,
        osVersion: String
    ) -> ObservabilityEventCapturePlan {
        // Merge caller context with live engine state
        var mergedContext = context ?? [:]
        if let engineState {
            for (key, value) in engineState where mergedContext[key] == nil {
                mergedContext[key] = value
            }
        }
        if mergedContext["build_version"] == nil {
            mergedContext["build_version"] = infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        }
        if mergedContext["build_channel"] == nil {
            mergedContext["build_channel"] = AnalyticsRuntimeConfiguration.buildChannel(infoDictionary: infoDictionary)
        }
        if mergedContext["build_revision"] == nil {
            mergedContext["build_revision"] = AnalyticsRuntimeConfiguration.buildRevision(infoDictionary: infoDictionary)
        }

        mergedContext = TelemetryContext.enrich(event: event, properties: mergedContext, isFailure: level == .error)
        let entry = ObservabilityEvent(
            timestamp: timestamp,
            level: level.rawValue,
            engine: engine,
            event: event,
            message: message,
            context: mergedContext.isEmpty ? nil : mergedContext,
            appVersion: appVersion,
            osVersion: osVersion
        )

        // A few local lifecycle events also count in PostHog (the pinned
        // dictation mic's rollout signals). The policy rebuilds every property
        // from the caller's own context with bounded values; `mergedContext`
        // (engine state, build metadata) is not handed over.
        let forwarded = AnalyticsEventForwardingPolicy.forwardedEvent(
            engine: engine,
            event: event,
            context: context ?? [:]
        )

        return ObservabilityEventCapturePlan(
            mergedContext: mergedContext,
            entry: entry,
            localEntry: LocalObservabilityPayloadSanitizer.sanitize(entry),
            forwarded: forwarded,
            sentryPolicy: level == .error ? SentryEventPolicy.policy(forEngine: engine, event: event) : nil
        )
    }
}
