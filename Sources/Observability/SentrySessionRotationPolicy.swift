import Foundation

/// Decides when the Release Health session ends and a new one starts.
///
/// Transcripted is a menu bar app that often runs for days, so one session per
/// launch made the per-session crash-free rate rest on a handful of very long
/// sessions. A session now ends when the Mac sleeps and a new one starts on
/// wake, and a session that has been open for a day is closed and restarted.
enum SentrySessionRotationPolicy {
    /// A session open this long is closed and a new one started.
    static let maxSessionAge: TimeInterval = 24 * 60 * 60

    /// How often CrashReporter checks the open session's age.
    static let checkInterval: TimeInterval = 15 * 60

    enum Trigger: Equatable {
        case willSleep
        case didWake
        case periodicCheck
    }

    enum Action: Equatable {
        case none
        case end
        case start
        case restart
    }

    /// - Parameters:
    ///   - sessionStartedAt: when the open session started, or nil if none is open.
    ///   - wantsSession: sessions are allowed (onboarding done) and crash reporting is on.
    static func action(
        for trigger: Trigger,
        sessionStartedAt: Date?,
        wantsSession: Bool,
        now: Date
    ) -> Action {
        switch trigger {
        case .willSleep:
            return sessionStartedAt == nil ? .none : .end
        case .didWake:
            guard wantsSession else { return sessionStartedAt == nil ? .none : .end }
            // A wake without a matching sleep notice still splits the session.
            return sessionStartedAt == nil ? .start : .restart
        case .periodicCheck:
            guard let sessionStartedAt else { return .none }
            guard wantsSession else { return .end }
            return now.timeIntervalSince(sessionStartedAt) >= maxSessionAge ? .restart : .none
        }
    }
}
