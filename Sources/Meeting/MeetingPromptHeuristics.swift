import Foundation

enum MeetingPromptProvider: String, CaseIterable, Hashable {
    case zoom
    case googleMeet
    case teams
    case webex
    case facetime

    var browserHosted: Bool {
        switch self {
        case .googleMeet, .teams, .webex:
            return true
        case .zoom, .facetime:
            return false
        }
    }

    var activeBundleIdentifiers: Set<String> {
        switch self {
        case .zoom:
            return ["us.zoom.xos"]
        case .googleMeet:
            return []
        case .teams:
            return ["com.microsoft.teams", "com.microsoft.teams2"]
        case .webex:
            return ["com.cisco.webexmeetingsapp", "com.webex.meetingmanager"]
        case .facetime:
            return ["com.apple.FaceTime"]
        }
    }

    var supportsNativeRuntimePrompt: Bool {
        !activeBundleIdentifiers.isEmpty
    }

    var supportsRuntimeOnlyPrompt: Bool {
        supportsNativeRuntimePrompt && self != .teams
    }

    static func provider(forMeetingHost host: String) -> MeetingPromptProvider? {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        if hostMatches(normalizedHost, domain: "zoom.us") {
            return .zoom
        }
        if normalizedHost == "meet.google.com" {
            return .googleMeet
        }
        if hostMatches(normalizedHost, domain: "teams.microsoft.com") {
            return .teams
        }
        if hostMatches(normalizedHost, domain: "webex.com") {
            return .webex
        }
        if hostMatches(normalizedHost, domain: "facetime.apple.com") {
            return .facetime
        }

        return nil
    }

    private static func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

enum MeetingPromptSource: Equatable {
    case calendarEvent
    case runtimeApp
}

enum MeetingPromptReason: String, Equatable {
    case calendarNearby = "calendar_nearby"
    case calendarPlusRuntimeMatch = "calendar_plus_runtime_match"
    case runtimeOnly = "runtime_only"
}

enum MeetingPromptBackoffKind: String, Equatable {
    case calendarDefault = "calendar_default"
    case calendarTeamsExtended = "calendar_teams_extended"
    case calendarShortReminder = "calendar_short_reminder"
    case runtimeUntilNextCalendar = "runtime_until_next_calendar"
    case runtimeDefaultFallback = "runtime_default_fallback"
    case runtimeTeamsExtended = "runtime_teams_extended"
    case runtimeShortReminder = "runtime_short_reminder"
}

struct MeetingPromptBackoffDecision: Equatable {
    let kind: MeetingPromptBackoffKind
    let until: Date
}

enum MeetingPromptWindowPolicy {
    static func shouldOfferCalendarPrompt(startsIn: TimeInterval) -> Bool {
        (-MeetingPromptHeuristics.calendarReminderPostStartGrace ... MeetingPromptHeuristics.calendarReminderLeadTime)
            .contains(startsIn)
    }
}

struct RuntimeMeetingPromptPresentation: Equatable {
    let title: String
    let detail: String
    let score: Int
}

enum MeetingPromptHeuristics {
    static let remindSoonInterval: TimeInterval = 2 * 60
    static let runtimeReminderSnoozeInterval: TimeInterval = remindSoonInterval
    static let defaultRuntimeDismissFallbackInterval: TimeInterval = 30 * 60
    static let teamsDismissMinimumInterval: TimeInterval = 2 * 60 * 60
    static let runtimeActivityFreshness: TimeInterval = 5 * 60
    static let calendarReminderLeadTime: TimeInterval = 60
    static let calendarReminderPostStartGrace: TimeInterval = 5 * 60

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

    static func dismissMinimumInterval(for provider: MeetingPromptProvider, default defaultInterval: TimeInterval) -> TimeInterval {
        provider == .teams ? max(defaultInterval, teamsDismissMinimumInterval) : defaultInterval
    }

    static func backoffKind(
        for provider: MeetingPromptProvider,
        source: MeetingPromptSource,
        hasResumeDate: Bool = false
    ) -> MeetingPromptBackoffKind {
        switch source {
        case .calendarEvent:
            return provider == .teams ? .calendarTeamsExtended : .calendarDefault
        case .runtimeApp:
            if hasResumeDate { return .runtimeUntilNextCalendar }
            return provider == .teams ? .runtimeTeamsExtended : .runtimeDefaultFallback
        }
    }

    static func remindSoonBackoffKind(for source: MeetingPromptSource) -> MeetingPromptBackoffKind {
        switch source {
        case .calendarEvent:
            return .calendarShortReminder
        case .runtimeApp:
            return .runtimeShortReminder
        }
    }

    static func reason(
        for source: MeetingPromptSource,
        hasRuntimeContext: Bool
    ) -> MeetingPromptReason {
        switch source {
        case .calendarEvent:
            return hasRuntimeContext ? .calendarPlusRuntimeMatch : .calendarNearby
        case .runtimeApp:
            return .runtimeOnly
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
