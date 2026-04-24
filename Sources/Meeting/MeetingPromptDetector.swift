import AppKit
import EventKit
import Foundation

@available(macOS 14.0, *)
@MainActor
final class MeetingPromptDetector {
    struct Candidate: Equatable {
        let id: String
        let title: String
        let detail: String
        let startDate: Date
        let endDate: Date
        let meetingURL: URL
    }

    private enum Provider: Equatable {
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
    }

    private struct ScoredCandidate {
        let candidate: Candidate
        let score: Int
    }

    var onPromptRequest: ((Candidate) -> Bool)?

    private let eventStore = EKEventStore()
    private var pollingTask: Task<Void, Never>?
    private var snoozedUntil: [String: Date] = [:]
    private var pendingUntil: [String: Date] = [:]

    private let defaultSnoozeInterval: TimeInterval = 30 * 60
    private let pendingCooldown: TimeInterval = 90
    private let pollIntervalNanoseconds: UInt64 = 20_000_000_000

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.mozilla.firefox"
    ]

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }

            await evaluate()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                await evaluate()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func snooze(candidate: Candidate, interval: TimeInterval? = nil) {
        let until = max(
            Date().addingTimeInterval(interval ?? defaultSnoozeInterval),
            candidate.endDate.addingTimeInterval(5 * 60)
        )
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
    }

    func markAccepted(candidate: Candidate) {
        let until = max(Date().addingTimeInterval(defaultSnoozeInterval), candidate.endDate.addingTimeInterval(5 * 60))
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
    }

    private func evaluate() async {
        pruneExpiredEntries()

        guard MeetingPromptPreferences.isEnabled else { return }
        guard TranscriptedPermissionAccess.calendarAccessGranted() else { return }

        let now = Date()
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard let match = upcomingCandidates(
            now: now,
            runningBundleIDs: runningBundleIDs,
            frontmostBundleID: frontmostBundleID
        ).first else {
            return
        }

        guard snoozedUntil[match.candidate.id] == nil, pendingUntil[match.candidate.id] == nil else { return }

        if onPromptRequest?(match.candidate) == true {
            pendingUntil[match.candidate.id] = now.addingTimeInterval(pendingCooldown)
        }
    }

    private func upcomingCandidates(
        now: Date,
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?
    ) -> [ScoredCandidate] {
        let searchStart = now.addingTimeInterval(-5 * 60)
        let searchEnd = now.addingTimeInterval(15 * 60)
        let predicate = eventStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)

        return eventStore.events(matching: predicate)
            .compactMap { event in
                scoredCandidate(
                    from: event,
                    now: now,
                    runningBundleIDs: runningBundleIDs,
                    frontmostBundleID: frontmostBundleID
                )
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.candidate.startDate < $1.candidate.startDate
            }
    }

    private func scoredCandidate(
        from event: EKEvent,
        now: Date,
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?
    ) -> ScoredCandidate? {
        guard !event.isAllDay else { return nil }
        guard let meetingURL = extractMeetingURL(from: event), let provider = provider(for: meetingURL) else { return nil }

        let startsIn = event.startDate.timeIntervalSince(now)
        let genericWindow = (-90.0 ... 5 * 60).contains(startsIn)
        let runtimeReason = activeRuntimeReason(
            for: provider,
            runningBundleIDs: runningBundleIDs,
            frontmostBundleID: frontmostBundleID
        )
        let extendedRuntimeWindow = runtimeReason != nil && (-5 * 60 ... 10 * 60).contains(startsIn)

        guard genericWindow || extendedRuntimeWindow else { return nil }

        let title = trimmedTitle(from: event)
        let detail = buildDetail(title: title, startsIn: startsIn, runtimeReason: runtimeReason)
        let score = scoreForCandidate(startsIn: startsIn, runtimeReason: runtimeReason)

        return ScoredCandidate(
            candidate: Candidate(
                id: event.calendarItemIdentifier,
                title: title,
                detail: detail,
                startDate: event.startDate,
                endDate: event.endDate,
                meetingURL: meetingURL
            ),
            score: score
        )
    }

    private func trimmedTitle(from event: EKEvent) -> String {
        let trimmed = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Upcoming meeting" : trimmed
    }

    private func buildDetail(title: String, startsIn: TimeInterval, runtimeReason: String?) -> String {
        if let runtimeReason {
            return "\(title) - \(runtimeReason)"
        }

        if startsIn > 90 {
            let minutes = Int(ceil(startsIn / 60))
            return "\(title) - starts in \(minutes) min"
        }

        if startsIn > 15 {
            return "\(title) - starts soon"
        }

        if startsIn >= -120 {
            return "\(title) - starting now"
        }

        return "\(title) - already in progress"
    }

    private func scoreForCandidate(startsIn: TimeInterval, runtimeReason: String?) -> Int {
        var score = runtimeReason == nil ? 1 : 3

        if (-60 ... 120).contains(startsIn) {
            score += 2
        } else if (-5 * 60 ... 5 * 60).contains(startsIn) {
            score += 1
        }

        return score
    }

    private func activeRuntimeReason(
        for provider: Provider,
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?
    ) -> String? {
        if !provider.activeBundleIdentifiers.isEmpty,
           provider.activeBundleIdentifiers.contains(where: runningBundleIDs.contains) {
            return "\(displayName(for: provider)) is open"
        }

        if provider.browserHosted,
           let frontmostBundleID,
           Self.browserBundleIdentifiers.contains(frontmostBundleID) {
            return "meeting tab is active"
        }

        return nil
    }

    private func displayName(for provider: Provider) -> String {
        switch provider {
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

    private func extractMeetingURL(from event: EKEvent) -> URL? {
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

    private func extractFirstMeetingURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let matches = detector.matches(in: text, options: [], range: range)
        for match in matches {
            guard let url = match.url, provider(for: url) != nil else { continue }
            return url
        }

        return nil
    }

    private func provider(for url: URL) -> Provider? {
        guard let host = url.host?.lowercased() else { return nil }

        if host.contains("zoom.us") {
            return .zoom
        }
        if host == "meet.google.com" {
            return .googleMeet
        }
        if host.contains("teams.microsoft.com") {
            return .teams
        }
        if host.contains("webex.com") {
            return .webex
        }
        if host.contains("facetime.apple.com") {
            return .facetime
        }

        return nil
    }

    private func pruneExpiredEntries() {
        let now = Date()
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        pendingUntil = pendingUntil.filter { $0.value > now }
    }
}
