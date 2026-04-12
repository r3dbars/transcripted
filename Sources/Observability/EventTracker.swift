import Foundation

// Compatibility shim for older call sites while EventReporter owns the
// canonical product-analytics event stream.
enum EventTracker {
    static func track(_ signal: String, with payload: [String: String] = [:]) {
        let entry = ObservabilityEvent(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: EventLevel.info.rawValue,
            engine: "legacy_analytics",
            event: legacyEventName(for: signal),
            message: signal,
            context: payload.isEmpty ? nil : payload,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        PostHogTracker.shared.capture(event: entry)
    }

    private static func legacyEventName(for signal: String) -> String {
        signal.replacingOccurrences(of: ".", with: "_")
    }
}
