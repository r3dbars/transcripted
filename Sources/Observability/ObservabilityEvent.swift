import Foundation

/// Only `.error` events leave the machine: `EventReporter` forwards an
/// allowlisted event to Sentry and the reliability counter at this level alone.
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
