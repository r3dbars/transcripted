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
        switch self {
        case .zoom, .teams, .googleMeet:
            return false
        case .webex, .facetime:
            return supportsNativeRuntimePrompt
        }
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

    // MARK: - Mic-activity attribution (ad-hoc call detection)

    /// Bundle-ID prefixes for browser families that can host a web call.
    ///
    /// Matching is by *family prefix*, not exact bundle ID, because browsers
    /// spread audio across helper/service processes. This was confirmed against a
    /// live Google Meet call: the only process holding the mic input was
    /// `com.google.Chrome.helper` (Chrome's Audio Service), not the main
    /// `com.google.Chrome`. Safari/WKWebView audio likewise runs in
    /// `com.apple.WebKit.GPU`, which is not prefixed by `com.apple.Safari`.
    static let browserBundleIDPrefixes: [String] = [
        "com.google.Chrome",          // Chrome, Chrome.canary, and *.helper children
        "com.microsoft.edgemac",      // Edge + helpers
        "com.brave.Browser",          // Brave + helpers
        "company.thebrowser.Browser", // Arc + helpers
        "org.mozilla.firefox",        // Firefox + plugin-container children
        "com.apple.Safari",           // Safari main process
        "com.apple.WebKit",           // Safari / WKWebView service processes (GPU, Networking, WebContent)
    ]

    /// Whether `bundleID` belongs to a known browser family (main app or any of
    /// its helper/service processes). Prefix-aware: a prefix matches the exact id
    /// or any dotted child (`com.google.Chrome` matches `com.google.Chrome.helper`).
    static func isBrowserBundleID(_ bundleID: String) -> Bool {
        browserBundleIDPrefixes.contains { bundleID.matchesBundleFamily($0) }
    }

    /// Maps a process bundle ID that is *currently holding the mic input* to a
    /// meeting provider, or `nil` if it is not a recognized call source.
    ///
    /// - Native conferencing apps (Zoom, Teams, Webex, FaceTime) map to their own
    ///   provider, matched by family prefix so a helper process still attributes
    ///   to the parent app.
    /// - Any browser-family process maps to `.googleMeet` — the representative
    ///   "browser call" (Meet / Zoom-web / Teams-web). This is the branch that
    ///   closes the spontaneous-Google-Meet gap.
    /// - Everything else (QuickTime, Voice Memos, Photo Booth, …) returns `nil`,
    ///   so it never produces a prompt.
    ///
    /// Because `.googleMeet` carries no `activeBundleIdentifiers`, it is never a
    /// native match — so a `.googleMeet` result unambiguously means "browser call".
    static func micInputProvider(forBundleID bundleID: String) -> MeetingPromptProvider? {
        if let native = allCases.first(where: { provider in
            provider.activeBundleIdentifiers.contains { bundleID.matchesBundleFamily($0) }
        }) {
            return native
        }
        if isBrowserBundleID(bundleID) {
            return .googleMeet
        }
        return nil
    }
}

extension String {
    /// True when the receiver is `family` exactly or a dotted child of it
    /// (`com.google.Chrome.helper`.matchesBundleFamily(`com.google.Chrome`)).
    /// Guards against false matches like `com.google.ChromeEvil`.
    func matchesBundleFamily(_ family: String) -> Bool {
        self == family || hasPrefix(family + ".")
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
    // A process is actively holding the mic input (ad-hoc call detection).
    // Distinct from `runtimeOnly` so analytics can tell the stronger signal
    // apart, even though both reuse the `.runtimeApp` source for backoff.
    case micInput = "mic_input"
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
    static func shouldOfferCalendarPrompt(startsIn: TimeInterval, endsIn: TimeInterval) -> Bool {
        guard endsIn > 0 else { return false }
        return (-MeetingPromptHeuristics.calendarReminderPostStartGrace ... MeetingPromptHeuristics.calendarReminderLeadTime)
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

    /// Score for a mic-in-use candidate. Deliberately above the frontmost-browser
    /// runtime score (4): a process actively holding the mic is stronger evidence
    /// of a live call than "a browser is frontmost".
    static let micInputPromptScore = 5

    /// Presentation for an ad-hoc call detected from mic activity. The caller
    /// builds the user-facing `title` (provider-specific for native apps, generic
    /// for browser calls so a Zoom-web/Teams-web call is not mislabeled "Meet").
    static func micInputPresentation(title: String) -> RuntimeMeetingPromptPresentation {
        RuntimeMeetingPromptPresentation(
            title: title,
            detail: "Start recording now or press Option-M anytime.",
            score: micInputPromptScore
        )
    }
}
