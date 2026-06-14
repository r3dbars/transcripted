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

    var displayName: String {
        switch self {
        case .zoom:
            return "Zoom"
        case .googleMeet:
            return "Google Meet"
        case .teams:
            return "Teams"
        case .webex:
            return "Webex"
        case .facetime:
            return "FaceTime"
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
}

@available(macOS 14.0, *)
struct MeetingPromptCalendarEventSnapshot: Equatable {
    let id: String
    let title: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let url: URL?
    let location: String?
    let notes: String?
    let meetingURL: URL?
    let provider: MeetingPromptProvider?

    init(
        id: String,
        title: String?,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        url: URL?,
        location: String?,
        notes: String?
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.url = url
        self.location = location
        self.notes = notes

        let meetingURL = Self.extractMeetingURL(url: url, location: location, notes: notes)
        self.meetingURL = meetingURL
        self.provider = meetingURL.flatMap(Self.provider(for:))
    }

    private static let meetingURLDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func extractMeetingURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, provider(for: url) != nil {
            return url
        }

        for source in [location, notes] {
            guard let source else { continue }
            guard let url = extractFirstMeetingURL(in: source) else { continue }
            return url
        }

        return nil
    }

    private static func extractFirstMeetingURL(in text: String) -> URL? {
        guard let detector = meetingURLDetector else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        for match in matches {
            guard let url = match.url, provider(for: url) != nil else { continue }
            return url
        }
        return nil
    }

    private static func provider(for url: URL) -> MeetingPromptProvider? {
        guard let host = url.host else { return nil }
        return MeetingPromptProvider.provider(forMeetingHost: host)
    }
}

@available(macOS 14.0, *)
struct MeetingPromptRuntimeSnapshot: Equatable {
    let runningBundleIDs: Set<String>
    let frontmostBundleID: String?
    let recentNativeActivity: [MeetingPromptProvider: Date]
    let runtimeSuppressedUntil: [MeetingPromptProvider: Date]

    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.mozilla.firefox"
    ]
}

@available(macOS 14.0, *)
struct MeetingPromptScoredCandidate {
    let candidate: MeetingPromptDetector.Candidate
    let score: Int
}

enum MeetingPromptSessionPromptState: Equatable {
    case idle
    case loadingModels
    case ready
    case recording
    case transcribing
    case error

    var allowsDetectedMeetingPrompt: Bool {
        switch self {
        case .idle, .ready, .error:
            return true
        case .loadingModels, .recording, .transcribing:
            return false
        }
    }
}

enum MeetingPromptOverlayPromptState: Equatable {
    case idle
    case prompt
    case preparing
    case recording
    case transcribing
    case saved
    case error

    var allowsDetectedMeetingPrompt: Bool {
        switch self {
        case .idle, .saved:
            return true
        case .prompt, .preparing, .recording, .transcribing, .error:
            return false
        }
    }
}

struct MeetingPromptPresentationSnapshot: Equatable {
    let sessionState: MeetingPromptSessionPromptState
    let overlayState: MeetingPromptOverlayPromptState
}

enum MeetingPromptPresentationGate {
    static func allowsDetectedMeetingPrompt(_ snapshot: MeetingPromptPresentationSnapshot) -> Bool {
        snapshot.sessionState.allowsDetectedMeetingPrompt
            && snapshot.overlayState.allowsDetectedMeetingPrompt
    }
}

@available(macOS 14.0, *)
enum MeetingPromptSyntheticSuppressionReason: String, Equatable {
    case noCandidate = "no_candidate"
    case snoozedCandidate = "snoozed_candidate"
    case pendingCandidate = "pending_candidate"
    case presentationBlocked = "presentation_blocked"
}

@available(macOS 14.0, *)
struct MeetingPromptSyntheticEvaluation: Equatable {
    let candidate: MeetingPromptDetector.Candidate?
    let suppressionReason: MeetingPromptSyntheticSuppressionReason?

    var shouldPrompt: Bool {
        candidate != nil && suppressionReason == nil
    }
}

@available(macOS 14.0, *)
enum MeetingPromptSyntheticEvaluator {
    private static let meetingURLDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func evaluate(
        now: Date,
        calendarAccessGranted: Bool,
        calendarEvents: [MeetingPromptCalendarEventSnapshot],
        runtimeSnapshot: MeetingPromptRuntimeSnapshot,
        snoozedUntil: [String: Date],
        pendingUntil: [String: Date],
        presentationSnapshot: MeetingPromptPresentationSnapshot? = nil
    ) -> MeetingPromptSyntheticEvaluation {
        if let presentationSnapshot,
           !MeetingPromptPresentationGate.allowsDetectedMeetingPrompt(presentationSnapshot) {
            return MeetingPromptSyntheticEvaluation(candidate: nil, suppressionReason: .presentationBlocked)
        }

        var candidates: [MeetingPromptScoredCandidate] = []
        if calendarAccessGranted {
            candidates.append(contentsOf: calendarCandidates(
                from: calendarEvents,
                now: now,
                runtimeSnapshot: runtimeSnapshot
            ))
        }
        candidates.append(contentsOf: runtimeCandidates(from: runtimeSnapshot, now: now))

        guard let match = candidates.sorted(by: sortCandidates).first else {
            return MeetingPromptSyntheticEvaluation(candidate: nil, suppressionReason: .noCandidate)
        }

        if let until = snoozedUntil[match.candidate.id], until > now {
            return MeetingPromptSyntheticEvaluation(candidate: nil, suppressionReason: .snoozedCandidate)
        }

        if let until = pendingUntil[match.candidate.id], until > now {
            return MeetingPromptSyntheticEvaluation(candidate: nil, suppressionReason: .pendingCandidate)
        }

        return MeetingPromptSyntheticEvaluation(candidate: match.candidate, suppressionReason: nil)
    }

    static func runtimeCandidates(
        from snapshot: MeetingPromptRuntimeSnapshot,
        now: Date
    ) -> [MeetingPromptScoredCandidate] {
        MeetingPromptProvider.allCases.compactMap { provider in
            guard provider.supportsRuntimeOnlyPrompt else { return nil }
            guard provider.activeBundleIdentifiers.contains(where: snapshot.runningBundleIDs.contains) else { return nil }
            if let suppressedUntil = snapshot.runtimeSuppressedUntil[provider], suppressedUntil > now {
                return nil
            }

            let isFrontmost = snapshot.frontmostBundleID.map(provider.activeBundleIdentifiers.contains) ?? false
            guard let presentation = MeetingPromptHeuristics.runtimePresentation(
                providerName: provider.displayName,
                isFrontmost: isFrontmost,
                lastActiveAt: snapshot.recentNativeActivity[provider],
                now: now
            ) else { return nil }

            return MeetingPromptScoredCandidate(
                candidate: MeetingPromptDetector.Candidate(
                    id: "runtime:\(provider.rawValue)",
                    title: presentation.title,
                    detail: presentation.detail,
                    provider: provider,
                    reason: MeetingPromptHeuristics.reason(for: .runtimeApp, hasRuntimeContext: false),
                    source: .runtimeApp,
                    startDate: now,
                    endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
                    meetingURL: nil,
                    suggestedTranscriptTitle: nil
                ),
                score: presentation.score
            )
        }
    }

    static func calendarCandidates(
        from events: [MeetingPromptCalendarEventSnapshot],
        now: Date,
        runtimeSnapshot: MeetingPromptRuntimeSnapshot
    ) -> [MeetingPromptScoredCandidate] {
        events.compactMap { event in
            scoredCalendarCandidate(
                from: event,
                now: now,
                runtimeSnapshot: runtimeSnapshot
            )
        }
    }

    static func sortCandidates(_ lhs: MeetingPromptScoredCandidate, _ rhs: MeetingPromptScoredCandidate) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.candidate.startDate < rhs.candidate.startDate
    }

    private static func scoredCalendarCandidate(
        from event: MeetingPromptCalendarEventSnapshot,
        now: Date,
        runtimeSnapshot: MeetingPromptRuntimeSnapshot
    ) -> MeetingPromptScoredCandidate? {
        guard !event.isAllDay else { return nil }
        guard let meetingURL = event.meetingURL,
              let provider = event.provider else { return nil }

        let startsIn = event.startDate.timeIntervalSince(now)
        let endsIn = event.endDate.timeIntervalSince(now)
        guard MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(startsIn: startsIn, endsIn: endsIn) else { return nil }

        let eventTitle = suggestedTranscriptTitle(from: event) ?? "Upcoming meeting"
        let transcriptTitle = suggestedTranscriptTitle(from: event)
        let runtimeReason = activeRuntimeReason(
            for: provider,
            runtimeSnapshot: runtimeSnapshot
        )
        let detail = buildDetail(eventTitle: eventTitle, startsIn: startsIn, runtimeReason: runtimeReason)
        let score = scoreForCandidate(startsIn: startsIn, runtimeReason: runtimeReason)

        return MeetingPromptScoredCandidate(
            candidate: MeetingPromptDetector.Candidate(
                id: "calendar:\(event.id)",
                title: "Meeting detected",
                detail: detail,
                provider: provider,
                reason: MeetingPromptHeuristics.reason(
                    for: .calendarEvent,
                    hasRuntimeContext: runtimeReason != nil
                ),
                source: .calendarEvent,
                startDate: event.startDate,
                endDate: event.endDate,
                meetingURL: meetingURL,
                suggestedTranscriptTitle: transcriptTitle
            ),
            score: score
        )
    }

    private static func suggestedTranscriptTitle(from event: MeetingPromptCalendarEventSnapshot) -> String? {
        let trimmed = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func buildDetail(eventTitle: String, startsIn: TimeInterval, runtimeReason: String?) -> String {
        if let runtimeReason {
            return "\(eventTitle) - \(runtimeReason)"
        }

        if startsIn > 90 {
            let minutes = Int(ceil(startsIn / 60))
            return "\(eventTitle) - starts in \(minutes) min"
        }

        if startsIn > 15 {
            return "\(eventTitle) - starts soon"
        }

        if startsIn >= -120 {
            return "\(eventTitle) - starting now"
        }

        return "\(eventTitle) - already in progress"
    }

    private static func scoreForCandidate(startsIn: TimeInterval, runtimeReason: String?) -> Int {
        var score = runtimeReason == nil ? 1 : 3

        if (-60 ... 120).contains(startsIn) {
            score += 2
        } else if (-5 * 60 ... 5 * 60).contains(startsIn) {
            score += 1
        }

        return score
    }

    private static func activeRuntimeReason(
        for provider: MeetingPromptProvider,
        runtimeSnapshot: MeetingPromptRuntimeSnapshot
    ) -> String? {
        if !provider.activeBundleIdentifiers.isEmpty,
           provider.activeBundleIdentifiers.contains(where: runtimeSnapshot.runningBundleIDs.contains) {
            return "\(provider.displayName) is open"
        }

        if provider.browserHosted,
           let frontmostBundleID = runtimeSnapshot.frontmostBundleID,
           MeetingPromptRuntimeSnapshot.browserBundleIdentifiers.contains(frontmostBundleID) {
            return "meeting tab is active"
        }

        return nil
    }

    private static func extractMeetingURL(from event: MeetingPromptCalendarEventSnapshot) -> URL? {
        if let url = event.url, provider(for: url) != nil {
            return url
        }

        for source in [event.location, event.notes] {
            guard let source else { continue }
            guard let url = extractFirstMeetingURL(in: source) else { continue }
            return url
        }

        return nil
    }

    private static func extractFirstMeetingURL(in text: String) -> URL? {
        guard let detector = meetingURLDetector else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        for match in matches {
            guard let url = match.url, provider(for: url) != nil else { continue }
            return url
        }
        return nil
    }

    private static func provider(for url: URL) -> MeetingPromptProvider? {
        guard let host = url.host else { return nil }
        return MeetingPromptProvider.provider(forMeetingHost: host)
    }
}
