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
        let provider: MeetingPromptProvider
        let reason: MeetingPromptReason
        let source: MeetingPromptSource
        let startDate: Date
        let endDate: Date
        let meetingURL: URL?
        let suggestedTranscriptTitle: String?
    }

    private struct ScoredCandidate {
        let candidate: Candidate
        let score: Int
    }

    var onPromptRequest: ((Candidate) -> Bool)?

    /// Returns true while Transcripted itself holds the mic (meeting recording or
    /// dictation). Gates the mic-activity path so we never prompt to record our
    /// own capture — belt-and-suspenders with `MicActivityMonitor`'s own-bundle
    /// filter. Wired in `TranscriptedApp`.
    var isOwnCaptureActive: (() -> Bool)?

    private let calendarReader = MeetingPromptCalendarReader()
    // Cache of upcoming meeting-link events refreshed off-main by each poll cycle.
    // Dismiss/markAccepted/title paths must stay synchronous (overlay callbacks and
    // the recording-start title closure), so they read this cache instead of querying
    // EKEventStore on the main actor.
    private var calendarEventSnapshots: [MeetingPromptCalendarEventSnapshot] = []
    private var pollingTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var snoozedUntil: [String: Date] = [:]
    private var pendingUntil: [String: Date] = [:]
    private var recentNativeActivity: [MeetingPromptProvider: Date] = [:]
    private var runtimeSuppressedUntil: [MeetingPromptProvider: Date] = [:]
    // Bundle IDs currently holding the mic input, pushed by MicActivityMonitor.
    private var micActiveBundleIDs: Set<String> = []

    private let defaultSnoozeInterval: TimeInterval = 30 * 60
    private let pendingCooldown: TimeInterval = 90
    private let pollIntervalNanoseconds: UInt64 = 20_000_000_000
    // Single fetch window covering both the near-term prompt window and the
    // farthest lookahead used for runtime-dismiss resume dates.
    private let calendarLookaheadInterval: TimeInterval = 12 * 60 * 60

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

    @discardableResult
    func dismiss(candidate: Candidate) -> MeetingPromptBackoffDecision {
        return dismiss(candidate: candidate, interval: nil)
    }

    @discardableResult
    func remindSoon(candidate: Candidate) -> MeetingPromptBackoffDecision {
        let now = Date()
        let until = now.addingTimeInterval(MeetingPromptHeuristics.remindSoonInterval)
        let decision = MeetingPromptBackoffDecision(
            kind: MeetingPromptHeuristics.remindSoonBackoffKind(for: candidate.source),
            until: until
        )
        suppressRuntimePrompts(for: candidate.provider, until: until)
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        return decision
    }

    @discardableResult
    func snooze(candidate: Candidate, interval: TimeInterval? = nil) -> MeetingPromptBackoffDecision {
        return dismiss(candidate: candidate, interval: interval)
    }

    private func dismiss(candidate: Candidate, interval: TimeInterval?) -> MeetingPromptBackoffDecision {
        let now = Date()
        let baseInterval = MeetingPromptHeuristics.snoozeInterval(
            for: candidate.source,
            explicit: interval,
            defaultInterval: defaultSnoozeInterval
        )
        let decision: MeetingPromptBackoffDecision
        let until: Date
        switch candidate.source {
        case .calendarEvent:
            let minimumInterval = MeetingPromptHeuristics.dismissMinimumInterval(
                for: candidate.provider,
                default: baseInterval
            )
            until = max(
                now.addingTimeInterval(minimumInterval),
                candidate.endDate.addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
            )
            decision = MeetingPromptBackoffDecision(
                kind: MeetingPromptHeuristics.backoffKind(for: candidate.provider, source: .calendarEvent),
                until: until
            )
            suppressRuntimePrompts(for: candidate.provider, until: until)
        case .runtimeApp:
            if let resumeDate = nextRuntimePromptResumeDate(for: candidate.provider, now: now) {
                until = resumeDate
                decision = MeetingPromptBackoffDecision(
                    kind: MeetingPromptHeuristics.backoffKind(for: candidate.provider, source: .runtimeApp, hasResumeDate: true),
                    until: until
                )
            } else {
                let fallbackInterval = MeetingPromptHeuristics.dismissMinimumInterval(
                    for: candidate.provider,
                    default: MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval
                )
                until = now.addingTimeInterval(fallbackInterval)
                decision = MeetingPromptBackoffDecision(
                    kind: MeetingPromptHeuristics.backoffKind(for: candidate.provider, source: .runtimeApp),
                    until: until
                )
            }
            suppressRuntimePrompts(for: candidate.provider, until: until)
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        return decision
    }

    func markAccepted(candidate: Candidate) {
        let now = Date()
        let until: Date
        switch candidate.source {
        case .calendarEvent:
            until = max(
                now.addingTimeInterval(defaultSnoozeInterval),
                candidate.endDate.addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
            )
            suppressRuntimePrompts(for: candidate.provider, until: until)
        case .runtimeApp:
            until = runtimeSuppressionEndDate(for: candidate.provider, now: now)
                ?? now.addingTimeInterval(defaultSnoozeInterval)
            suppressRuntimePrompts(for: candidate.provider, until: until)
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
    }

    func currentSuggestedTranscriptTitle(now: Date = Date()) -> String? {
        guard TranscriptedPermissionAccess.calendarAccessGranted() else { return nil }
        return upcomingCalendarCandidates(
            now: now,
            runningBundleIDs: [],
            frontmostBundleID: nil
        )
        .sorted(by: sortCandidates)
        .lazy
        .compactMap(\.candidate.suggestedTranscriptTitle)
        .first
    }

    private func evaluate() async {
        await refreshCalendarEventSnapshots()

        let now = Date()
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        pruneExpiredEntries(now: now)
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
        candidates.append(contentsOf: micInputCandidates(now: now))

        guard let match = candidates.sorted(by: sortCandidates).first else { return }

        guard snoozedUntil[match.candidate.id] == nil, pendingUntil[match.candidate.id] == nil else { return }

        if onPromptRequest?(match.candidate) == true {
            pendingUntil[match.candidate.id] = now.addingTimeInterval(pendingCooldown)
        }
    }

    private func refreshCalendarEventSnapshots() async {
        guard TranscriptedPermissionAccess.calendarAccessGranted() else {
            calendarEventSnapshots = []
            return
        }

        let now = Date()
        calendarEventSnapshots = await calendarReader.fetchMeetingEventSnapshots(
            start: now.addingTimeInterval(-MeetingPromptHeuristics.calendarReminderPostStartGrace),
            end: now.addingTimeInterval(calendarLookaheadInterval)
        )
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
        MeetingPromptProvider.allCases.compactMap { provider in
            guard provider.supportsRuntimeOnlyPrompt else { return nil }
            guard provider.activeBundleIdentifiers.contains(where: runningBundleIDs.contains) else { return nil }
            if let suppressedUntil = runtimeSuppressedUntil[provider], suppressedUntil > now {
                return nil
            }

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

    // MARK: - Mic-activity candidates (ad-hoc call detection)

    /// Pushed by `MicActivityMonitor` with the set of non-self bundle IDs holding
    /// the mic input. Stores it, resets mic-suppression for any provider that just
    /// left the call (the "inactive" edge, so the next call re-prompts), and
    /// re-evaluates.
    func updateMicInputUsers(_ bundleIDs: Set<String>) {
        guard bundleIDs != micActiveBundleIDs else { return }
        let departed = micProviders(for: micActiveBundleIDs).subtracting(micProviders(for: bundleIDs))
        micActiveBundleIDs = bundleIDs
        for provider in departed {
            clearMicSuppression(for: provider)
        }
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    private func micInputCandidates(now: Date) -> [ScoredCandidate] {
        guard !micActiveBundleIDs.isEmpty else { return [] }
        // Never prompt to record a call while we already hold the mic ourselves.
        guard isOwnCaptureActive?() != true else { return [] }

        var seenProviders: Set<MeetingPromptProvider> = []
        var candidates: [ScoredCandidate] = []
        for bundleID in micActiveBundleIDs.sorted() {
            guard let provider = MeetingPromptProvider.micInputProvider(forBundleID: bundleID) else { continue }
            guard seenProviders.insert(provider).inserted else { continue }
            if let suppressedUntil = runtimeSuppressedUntil[provider], suppressedUntil > now { continue }

            // Browser calls map to .googleMeet generically (could be Meet/Zoom-web/
            // Teams-web), so keep their title neutral instead of mislabeling them.
            let isBrowserCall = provider == .googleMeet
            let title = isBrowserCall
                ? "Call detected in your browser"
                : "\(displayName(for: provider)) call detected"
            let presentation = MeetingPromptHeuristics.micInputPresentation(title: title)

            candidates.append(
                ScoredCandidate(
                    candidate: Candidate(
                        id: micCandidateID(for: provider),
                        title: presentation.title,
                        detail: presentation.detail,
                        provider: provider,
                        reason: .micInput,
                        source: .runtimeApp,
                        startDate: now,
                        endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
                        meetingURL: nil,
                        suggestedTranscriptTitle: nil
                    ),
                    score: presentation.score
                )
            )
        }
        return candidates
    }

    private func micProviders(for bundleIDs: Set<String>) -> Set<MeetingPromptProvider> {
        Set(bundleIDs.compactMap { MeetingPromptProvider.micInputProvider(forBundleID: $0) })
    }

    // Clears the mic-prompt backoff for a provider whose call just ended, so the
    // next distinct call can prompt again. Within a single call, snooze/dismiss
    // still suppress as usual.
    private func clearMicSuppression(for provider: MeetingPromptProvider) {
        runtimeSuppressedUntil[provider] = nil
        let id = micCandidateID(for: provider)
        snoozedUntil[id] = nil
        pendingUntil[id] = nil
    }

    private func micCandidateID(for provider: MeetingPromptProvider) -> String {
        "mic:\(provider.rawValue)"
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
        calendarEventSnapshots.compactMap { snapshot in
            scoredCandidate(
                from: snapshot,
                now: now,
                runningBundleIDs: runningBundleIDs,
                frontmostBundleID: frontmostBundleID
            )
        }
    }

    private func scoredCandidate(
        from snapshot: MeetingPromptCalendarEventSnapshot,
        now: Date,
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?
    ) -> ScoredCandidate? {
        let startsIn = snapshot.startDate.timeIntervalSince(now)
        let endsIn = snapshot.endDate.timeIntervalSince(now)
        let genericWindow = MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
            startsIn: startsIn,
            endsIn: endsIn
        )
        let runtimeReason = activeRuntimeReason(
            for: snapshot.provider,
            runningBundleIDs: runningBundleIDs,
            frontmostBundleID: frontmostBundleID
        )
        guard genericWindow else { return nil }

        let eventTitle = displayTitle(from: snapshot)
        let transcriptTitle = suggestedTranscriptTitle(from: snapshot)
        let detail = buildDetail(eventTitle: eventTitle, startsIn: startsIn, runtimeReason: runtimeReason)
        let score = scoreForCandidate(startsIn: startsIn, runtimeReason: runtimeReason)

        return ScoredCandidate(
            candidate: Candidate(
                id: "calendar:\(snapshot.id)",
                title: "Meeting detected",
                detail: detail,
                provider: snapshot.provider,
                reason: MeetingPromptHeuristics.reason(
                    for: .calendarEvent,
                    hasRuntimeContext: runtimeReason != nil
                ),
                source: .calendarEvent,
                startDate: snapshot.startDate,
                endDate: snapshot.endDate,
                meetingURL: snapshot.meetingURL,
                suggestedTranscriptTitle: transcriptTitle
            ),
            score: score
        )
    }

    private func displayTitle(from snapshot: MeetingPromptCalendarEventSnapshot) -> String {
        suggestedTranscriptTitle(from: snapshot) ?? "Upcoming meeting"
    }

    private func suggestedTranscriptTitle(from snapshot: MeetingPromptCalendarEventSnapshot) -> String? {
        let trimmed = (snapshot.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        for provider: MeetingPromptProvider,
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

    private func displayName(for provider: MeetingPromptProvider) -> String {
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

    private func provider(forBundleIdentifier bundleIdentifier: String) -> MeetingPromptProvider? {
        MeetingPromptProvider.allCases.first { $0.activeBundleIdentifiers.contains(bundleIdentifier) }
    }

    private func suppressRuntimePrompts(for provider: MeetingPromptProvider, until: Date) {
        let existing = runtimeSuppressedUntil[provider] ?? .distantPast
        runtimeSuppressedUntil[provider] = max(existing, until)
    }

    private func nextRuntimePromptResumeDate(for provider: MeetingPromptProvider, now: Date) -> Date? {
        guard let snapshot = nextRelevantCalendarSnapshot(for: provider, after: now) else { return nil }

        let promptDate = snapshot.startDate.addingTimeInterval(-MeetingPromptHeuristics.calendarReminderLeadTime)
        if promptDate > now {
            return promptDate
        }

        return snapshot.endDate.addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
    }

    private func runtimeSuppressionEndDate(for provider: MeetingPromptProvider, now: Date) -> Date? {
        nextRelevantCalendarSnapshot(for: provider, after: now)?
            .endDate
            .addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
    }

    private func nextRelevantCalendarSnapshot(
        for targetProvider: MeetingPromptProvider,
        after now: Date
    ) -> MeetingPromptCalendarEventSnapshot? {
        guard TranscriptedPermissionAccess.calendarAccessGranted() else { return nil }

        return calendarEventSnapshots
            .filter { $0.provider == targetProvider && $0.endDate > now }
            .min { $0.startDate < $1.startDate }
    }

    private func pruneExpiredEntries(now: Date) {
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        pendingUntil = pendingUntil.filter { $0.value > now }
        runtimeSuppressedUntil = runtimeSuppressedUntil.filter { $0.value > now }
        recentNativeActivity = recentNativeActivity.filter {
            now.timeIntervalSince($0.value) <= MeetingPromptHeuristics.runtimeActivityFreshness
        }
    }
}

// Plain-value snapshot of a calendar event carrying a recognized meeting link.
// Built on the reader's queue because EKEvent objects must not cross threads;
// all-day events and events without a supported meeting URL are dropped here.
private struct MeetingPromptCalendarEventSnapshot: Sendable {
    let id: String
    let title: String?
    let startDate: Date
    let endDate: Date
    let meetingURL: URL
    let provider: MeetingPromptProvider

    init?(event: EKEvent) {
        guard !event.isAllDay,
              let startDate = event.startDate,
              let endDate = event.endDate,
              let meetingURL = Self.extractMeetingURL(from: event),
              let provider = Self.provider(for: meetingURL) else { return nil }

        self.id = event.calendarItemIdentifier
        self.title = event.title
        self.startDate = startDate
        self.endDate = endDate
        self.meetingURL = meetingURL
        self.provider = provider
    }

    private static let meetingURLDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func extractMeetingURL(from event: EKEvent) -> URL? {
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

// Runs the synchronous EKEventStore queries on a background queue so large
// calendars never block the main actor. @unchecked Sendable is safe because
// EKEventStore is documented thread-safe and all queries serialize on `queue`.
private final class MeetingPromptCalendarReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingPromptDetector.calendar-reader", qos: .utility)
    private let eventStore = EKEventStore()

    func fetchMeetingEventSnapshots(start: Date, end: Date) async -> [MeetingPromptCalendarEventSnapshot] {
        await withCheckedContinuation { continuation in
            queue.async {
                let predicate = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
                let snapshots = self.eventStore.events(matching: predicate)
                    .compactMap { MeetingPromptCalendarEventSnapshot(event: $0) }
                continuation.resume(returning: snapshots)
            }
        }
    }
}
