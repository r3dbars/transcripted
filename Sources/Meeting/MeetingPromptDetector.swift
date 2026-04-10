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
        let source: MeetingPromptSource
        let startDate: Date
        let endDate: Date
        let meetingURL: URL?
    }

    private enum Provider: String, CaseIterable, Hashable {
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
    }

    private struct ScoredCandidate {
        let candidate: Candidate
        let score: Int
    }

    var onPromptRequest: ((Candidate) -> Bool)?

    private let eventStore = EKEventStore()
    private var pollingTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var snoozedUntil: [String: Date] = [:]
    private var pendingUntil: [String: Date] = [:]
    private var recentNativeActivity: [Provider: Date] = [:]

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
        installWorkspaceObservers()

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
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    func snooze(candidate: Candidate, interval: TimeInterval? = nil) {
        let now = Date()
        let baseInterval = MeetingPromptHeuristics.snoozeInterval(
            for: candidate.source,
            explicit: interval,
            defaultInterval: defaultSnoozeInterval
        )
        let until: Date
        switch candidate.source {
        case .calendarEvent:
            until = max(
                now.addingTimeInterval(baseInterval),
                candidate.endDate.addingTimeInterval(5 * 60)
            )
        case .runtimeApp:
            until = now.addingTimeInterval(baseInterval)
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
    }

    func markAccepted(candidate: Candidate) {
        let now = Date()
        let until: Date
        switch candidate.source {
        case .calendarEvent:
            until = max(now.addingTimeInterval(defaultSnoozeInterval), candidate.endDate.addingTimeInterval(5 * 60))
        case .runtimeApp:
            until = now.addingTimeInterval(defaultSnoozeInterval)
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
    }

    private func evaluate() async {
        pruneExpiredEntries()

        let now = Date()
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        seedNativeActivityIfNeeded(frontmostBundleID: frontmostBundleID, now: now)

        var candidates: [ScoredCandidate] = []
        if TranscriptedPermissionAccess.calendarAccessGranted() {
            candidates.append(contentsOf: upcomingCalendarCandidates(
                now: now,
                runningBundleIDs: runningBundleIDs,
                frontmostBundleID: frontmostBundleID
            ))
        }
        candidates.append(contentsOf: runtimeReminderCandidates(
            now: now,
            runningBundleIDs: runningBundleIDs,
            frontmostBundleID: frontmostBundleID
        ))

        guard let match = candidates.sorted(by: sortCandidates).first else { return }

        guard snoozedUntil[match.candidate.id] == nil, pendingUntil[match.candidate.id] == nil else { return }

        if onPromptRequest?(match.candidate) == true {
            pendingUntil[match.candidate.id] = now.addingTimeInterval(pendingCooldown)
        }
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }

        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification
        ]

        workspaceObservers = names.map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleWorkspaceApplicationNotification(notification)
                }
            }
        }
    }

    private func handleWorkspaceApplicationNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleIdentifier = app.bundleIdentifier,
              let provider = provider(forBundleIdentifier: bundleIdentifier),
              provider.supportsNativeRuntimePrompt else { return }

        recentNativeActivity[provider] = Date()
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    private func seedNativeActivityIfNeeded(frontmostBundleID: String?, now: Date) {
        guard let frontmostBundleID,
              let provider = provider(forBundleIdentifier: frontmostBundleID),
              provider.supportsNativeRuntimePrompt,
              recentNativeActivity[provider] == nil else { return }

        recentNativeActivity[provider] = now
    }

    private func runtimeReminderCandidates(
        now: Date,
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?
    ) -> [ScoredCandidate] {
        Provider.allCases.compactMap { provider in
            guard provider.supportsNativeRuntimePrompt else { return nil }
            guard provider.activeBundleIdentifiers.contains(where: runningBundleIDs.contains) else { return nil }

            let isFrontmost = frontmostBundleID.map(provider.activeBundleIdentifiers.contains) ?? false
            guard let presentation = MeetingPromptHeuristics.runtimePresentation(
                providerName: displayName(for: provider),
                isFrontmost: isFrontmost,
                lastActiveAt: recentNativeActivity[provider],
                now: now
            ) else { return nil }

            return ScoredCandidate(
                candidate: Candidate(
                    id: "runtime:\(provider.rawValue)",
                    title: presentation.title,
                    detail: presentation.detail,
                    source: .runtimeApp,
                    startDate: now,
                    endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
                    meetingURL: nil
                ),
                score: presentation.score
            )
        }
    }

    private func sortCandidates(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.candidate.startDate < rhs.candidate.startDate
    }

    private func upcomingCalendarCandidates(
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
            .sorted(by: sortCandidates)
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

        let eventTitle = trimmedTitle(from: event)
        let detail = buildDetail(eventTitle: eventTitle, startsIn: startsIn, runtimeReason: runtimeReason)
        let score = scoreForCandidate(startsIn: startsIn, runtimeReason: runtimeReason)

        return ScoredCandidate(
            candidate: Candidate(
                id: "calendar:\(event.calendarItemIdentifier)",
                title: "Meeting detected",
                detail: detail,
                source: .calendarEvent,
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

    private func buildDetail(eventTitle: String, startsIn: TimeInterval, runtimeReason: String?) -> String {
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

    private func provider(forBundleIdentifier bundleIdentifier: String) -> Provider? {
        Provider.allCases.first { $0.activeBundleIdentifiers.contains(bundleIdentifier) }
    }

    private func pruneExpiredEntries() {
        let now = Date()
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        pendingUntil = pendingUntil.filter { $0.value > now }
        recentNativeActivity = recentNativeActivity.filter {
            now.timeIntervalSince($0.value) <= MeetingPromptHeuristics.runtimeActivityFreshness
        }
    }
}
