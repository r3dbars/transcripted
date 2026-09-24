import Foundation

/// The last Core Audio process-tap step that failed, as two coarse codes for
/// PostHog and Sentry. The tap path has no ScreenCaptureKit fallback, so when
/// system audio does not start (or does not come back after a reconnect) this
/// is the only off-device signal for *which* HAL call refused and with what
/// status. Codes only: never a device name, UID, path, or error text.
public struct SystemAudioTapFailure: Equatable, Sendable {
    /// Snake-case step, e.g. `tap_creation`, `aggregate_creation`, `start`.
    public let step: String
    /// OSStatus as digits, `neg` prefixed when negative (`neg10877`), because
    /// the shared category check rejects a leading `-`. `none` when the step
    /// failed without an OSStatus (unsupported format, self-exclusion).
    public let status: String

    public static let none = SystemAudioTapFailure(step: "none", status: "none")

    public init(step: String, status: String) {
        self.step = step
        self.status = status
    }

    init(operation: String, status: OSStatus?) {
        self.step = Self.stepCode(operation)
        self.status = status.map(Self.statusCode) ?? "none"
    }

    static func stepCode(_ operation: String) -> String {
        let code = operation.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(code)
    }

    static func statusCode(_ status: OSStatus) -> String {
        status < 0 ? "neg\(Int64(status).magnitude)" : "\(status)"
    }
}

/// Per-recording counts of what the process tap did to keep call audio
/// alive, and why it gave up if it did. Counts and fixed codes only, so the
/// app can bucket them for PostHog and tag Sentry without any device detail.
public struct SystemAudioTapDiagnostics: Equatable, Sendable {
    /// Reconnects by what caused them (one per interruption, not per retry).
    public var stallReconnects = 0
    public var wakeReconnects = 0
    public var formatReconnects = 0
    public var silentAfterWakeReconnects = 0
    /// Extra rebuild attempts after a wake or route change failed at first.
    public var rebuildRetries = 0
    /// Sleep notices while this recording's tap was live or released.
    public var sleeps = 0
    /// The tap stayed silent after its wake reconnects while other audio
    /// played, so the watch gave up.
    public var silentAfterWakeUnresolved = false
    /// Why system audio ended mid-recording: `none`, `buffer_overflow`,
    /// `format_change_limit`, `no_buffers_after_reconnect`, `reconnect_failed`.
    public var endReason = "none"

    public static let empty = SystemAudioTapDiagnostics()

    public init() {}
}
