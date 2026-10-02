import Foundation

/// Only `.error` events reach Sentry and `reliability_failure_observed`. The
/// allowlisted pinned-microphone lifecycle events also go to PostHog at any
/// level (see `ObservabilityEventCapturePlan` and `AnalyticsEventForwardingPolicy`).
enum EventLevel: String, Codable {
    case error
    case warning
    case info
}

struct ObservabilityEvent: Codable {
    let timestamp: String
    let level: String
    let engine: String
    let event: String
    let message: String
    let context: [String: String]?
    let appVersion: String
    let osVersion: String
}
