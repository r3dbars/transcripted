import Foundation

enum MeetingPromptSource: Equatable {
    case calendarEvent
    case runtimeApp
}

struct RuntimeMeetingPromptPresentation: Equatable {
    let title: String
    let detail: String
    let score: Int
}

enum MeetingPromptHeuristics {
    static let runtimeReminderSnoozeInterval: TimeInterval = 2 * 60
    static let runtimeActivityFreshness: TimeInterval = 5 * 60

    static func snoozeInterval(
        for source: MeetingPromptSource,
        explicit explicitInterval: TimeInterval?,
        defaultInterval: TimeInterval
    ) -> TimeInterval {
        if let explicitInterval {
            return explicitInterval
        }

        switch source {
        case .calendarEvent:
            return defaultInterval
        case .runtimeApp:
            return runtimeReminderSnoozeInterval
        }
    }

    static func runtimePresentation(
        providerName: String,
        isFrontmost: Bool,
        lastActiveAt: Date?,
        now: Date
    ) -> RuntimeMeetingPromptPresentation? {
        if isFrontmost {
            return RuntimeMeetingPromptPresentation(
                title: "\(providerName) is active",
                detail: "If this is a meeting, start recording now or press Option-M anytime.",
                score: 4
            )
        }

        guard let lastActiveAt else { return nil }
        let age = now.timeIntervalSince(lastActiveAt)
        guard age >= 0, age <= runtimeActivityFreshness else { return nil }

        return RuntimeMeetingPromptPresentation(
            title: "\(providerName) just opened",
            detail: "If this is a meeting, start recording now or press Option-M anytime.",
            score: 3
        )
    }
}
