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
    var onPromptSuppressed: ((MeetingPromptSuppression) -> Void)?
    var shouldSkipPromptEvaluation: (() -> Bool)?

    /// Returns true while Transcripted itself holds the mic (meeting recording or
    /// dictation). Gates the mic-activity path so we never prompt to record our
    /// own capture — belt-and-suspenders with `MicActivityMonitor`'s own-bundle
    /// filter. Wired in `TranscriptedApp`.
    var isOwnCaptureActive: (() -> Bool)?
    /// Optional richer shape for the same gate, used only for coarse analytics.
    var ownCaptureActivity: (() -> MeetingPromptOwnCaptureActivity)?
    /// Returns false when the Settings toggle is off. This keeps late monitor
    /// callbacks quiet after the user disables auto call detection.
    var isMicInputPromptEnabled: (() -> Bool)?

    private let calendarReader = MeetingPromptCalendarReader()
    private let calendarAccessGranted: () -> Bool
    private let refreshesCalendarEventSnapshots: Bool
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
    private var cooldownReasons: [String: String] = [:]
    private var runtimeSuppressionReasons: [MeetingPromptProvider: String] = [:]
    private var suppressionTelemetryUntil: [String: Date] = [:]
    // Bundle IDs currently holding the mic input, pushed by MicActivityMonitor.
    private var micActiveBundleIDs: Set<String> = []
    // Whether a camera is confirmed in use, pushed by CameraActivityMonitor.
    private var cameraInUse = false

    private let defaultSnoozeInterval: TimeInterval = 30 * 60
    private let pendingCooldown: TimeInterval = 90
    private let suppressionTelemetryCooldown: TimeInterval = 90
    private let pollIntervalNanoseconds: UInt64 = 20_000_000_000
    // Single fetch window covering both the near-term prompt window and the
    // farthest lookahead used for runtime-dismiss resume dates.
    private let calendarLookaheadInterval: TimeInterval = 12 * 60 * 60

    init(
        calendarAccessGranted: @escaping () -> Bool = { TranscriptedPermissionAccess.calendarAccessGranted() },
        calendarEventSnapshots: [MeetingPromptCalendarEventSnapshot] = [],
        refreshesCalendarEventSnapshots: Bool = true
    ) {
        self.calendarAccessGranted = calendarAccessGranted
        self.calendarEventSnapshots = calendarEventSnapshots
        self.refreshesCalendarEventSnapshots = refreshesCalendarEventSnapshots
    }

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
        suppressRuntimePrompts(for: candidate.provider, until: until, reason: decision.kind.rawValue)
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = decision.kind.rawValue
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
            suppressRuntimePrompts(for: candidate.provider, until: until, reason: decision.kind.rawValue)
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
            suppressRuntimePrompts(for: candidate.provider, until: until, reason: decision.kind.rawValue)
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = decision.kind.rawValue
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
            suppressRuntimePrompts(for: candidate.provider, until: until, reason: "record_selected")
        case .runtimeApp:
            until = runtimeSuppressionEndDate(for: candidate.provider, now: now)
                ?? now.addingTimeInterval(defaultSnoozeInterval)
            suppressRuntimePrompts(for: candidate.provider, until: until, reason: "record_selected")
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = "record_selected"
    }

    func currentSuggestedTranscriptTitle(now: Date = Date()) -> String? {
        guard calendarAccessGranted() else { return nil }
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
        if calendarAccessGranted() {
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
        candidates.append(contentsOf: micInputCandidates(now: now, frontmostBundleID: frontmostBundleID))

        let sortedCandidates = candidates.sorted(by: sortCandidates)
        guard let match = preferredCandidate(from: sortedCandidates) else { return }

        if shouldSkipPromptEvaluation?() == true {
            recordSuppression(
                candidate: match.candidate,
                reason: .presentationBlocked,
                now: now
            )
            return
        }

        if let until = snoozedUntil[match.candidate.id], until > now {
            recordSuppression(
                candidate: match.candidate,
                reason: .snoozedCandidate,
                now: now,
                cooldownReason: cooldownReasons[match.candidate.id]
            )
            return
        }

        if let until = pendingUntil[match.candidate.id], until > now {
            recordSuppression(
                candidate: match.candidate,
                reason: .pendingCandidate,
                now: now,
                cooldownReason: cooldownReasons[match.candidate.id] ?? "prompt_pending"
            )
            return
        }

        if onPromptRequest?(match.candidate) == true {
            pendingUntil[match.candidate.id] = now.addingTimeInterval(pendingCooldown)
            cooldownReasons[match.candidate.id] = "prompt_pending"
        } else {
            recordSuppression(
                candidate: match.candidate,
                reason: .presentationBlocked,
                now: now
            )
        }
    }

    private func refreshCalendarEventSnapshots() async {
        guard refreshesCalendarEventSnapshots else { return }
        guard calendarAccessGranted() else {
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
                recordSuppression(
                    candidate: runtimeCandidate(for: provider, now: now),
                    reason: .runtimeSuppressed,
                    now: now,
                    cooldownReason: runtimeSuppressionReasons[provider]
                )
                return nil
            }

            let isFrontmost = frontmostBundleID.map(provider.activeBundleIdentifiers.contains) ?? false
            guard let presentation = MeetingPromptHeuristics.runtimePresentation(
                providerName: provider.displayName,
                isFrontmost: isFrontmost,
                lastActiveAt: recentNativeActivity[provider],
                now: now
            ) else { return nil }

            return ScoredCandidate(
                candidate: runtimeCandidate(
                    for: provider,
                    now: now,
                    title: presentation.title,
                    detail: presentation.detail
                ),
                score: presentation.score
            )
        }
    }

    // MARK: - Mic-activity candidates (ad-hoc call detection)

    /// Pushed by `MicActivityMonitor` with the set of non-self bundle IDs holding
    /// the mic input. Stores it and re-evaluates; existing pending/dismiss
    /// cooldowns survive inactive edges so mute/unmute cannot re-prompt early.
    func updateMicInputUsers(_ bundleIDs: Set<String>) {
        guard bundleIDs != micActiveBundleIDs else { return }
        micActiveBundleIDs = bundleIDs
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    /// Pushed by `CameraActivityMonitor`: `true` when a camera is confirmed in
    /// use. Re-evaluates so a camera-on, mic-muted call can prompt; de-dupes with
    /// the mic signal in `callSignals` so a normal video call raises one prompt.
    func updateCameraInUse(_ inUse: Bool) {
        guard inUse != cameraInUse else { return }
        cameraInUse = inUse
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    private func micInputCandidates(now: Date, frontmostBundleID: String?) -> [ScoredCandidate] {
        let signals = callSignals(frontmostBundleID: frontmostBundleID)
        guard !signals.isEmpty else { return [] }
        guard isMicInputPromptEnabled?() != false else {
            signals.forEach {
                recordSuppression(
                    candidate: micInputCandidate(for: $0.provider, reason: $0.reason, now: now).candidate,
                    reason: .micInputDisabled,
                    now: now
                )
            }
            return []
        }
        // Never prompt to record a call while we already hold the mic ourselves.
        let captureActivity = currentOwnCaptureActivity()
        guard captureActivity == .none else {
            signals.forEach {
                recordSuppression(
                    candidate: micInputCandidate(for: $0.provider, reason: $0.reason, now: now).candidate,
                    reason: .ownCaptureActive,
                    now: now,
                    captureActivity: captureActivity
                )
            }
            return []
        }

        var candidates: [ScoredCandidate] = []
        for signal in signals {
            if let suppressedUntil = runtimeSuppressedUntil[signal.provider], suppressedUntil > now {
                recordSuppression(
                    candidate: micInputCandidate(for: signal.provider, reason: signal.reason, now: now).candidate,
                    reason: .runtimeSuppressed,
                    now: now,
                    cooldownReason: runtimeSuppressionReasons[signal.provider]
                )
                continue
            }

            candidates.append(micInputCandidate(for: signal.provider, reason: signal.reason, now: now))
        }
        return candidates
    }

    /// Ad-hoc call signals. The mic is the primary signal; the camera is only a
    /// standalone signal when nothing holds the mic (the mic-muted join), so a
    /// normal mic-and-camera call is a single mic prompt and the camera's
    /// frontmost-based attribution never overrides or duplicates a live mic call.
    /// Mirrors `MeetingPromptHeuristics.callSignals` used by the synthetic evaluator.
    private func callSignals(
        frontmostBundleID: String?
    ) -> [(provider: MeetingPromptProvider, reason: MeetingPromptReason)] {
        let micProviders = micInputProviders()
        if !micProviders.isEmpty {
            return micProviders.map { ($0, .micInput) }
        }

        if cameraInUse,
           let provider = MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID: frontmostBundleID) {
            return [(provider, .cameraInput)]
        }

        return []
    }

    private func micInputProviders() -> [MeetingPromptProvider] {
        Set(micActiveBundleIDs.compactMap(MeetingPromptProvider.micInputProvider(forBundleID:)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private func runtimeCandidate(
        for provider: MeetingPromptProvider,
        now: Date,
        title: String? = nil,
        detail: String? = nil
    ) -> Candidate {
        Candidate(
            id: "runtime:\(provider.rawValue)",
            title: title ?? "\(provider.displayName) is active",
            detail: detail ?? "If this is a meeting, start recording now or press Option-M anytime.",
            provider: provider,
            reason: MeetingPromptHeuristics.reason(for: .runtimeApp, hasRuntimeContext: false),
            source: .runtimeApp,
            startDate: now,
            endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
            meetingURL: nil,
            suggestedTranscriptTitle: nil
        )
    }

    private func micInputCandidate(
        for provider: MeetingPromptProvider,
        reason: MeetingPromptReason,
        now: Date
    ) -> ScoredCandidate {
        // Browser calls map to .googleMeet generically (could be Meet/Zoom-web/
        // Teams-web), so keep their title neutral instead of mislabeling them.
        let isBrowserCall = provider == .googleMeet
        let title = isBrowserCall
            ? "Call detected in your browser"
            : "\(provider.displayName) call detected"
        let presentation = MeetingPromptHeuristics.micInputPresentation(title: title)

        return ScoredCandidate(
            candidate: Candidate(
                id: micCandidateID(for: provider),
                title: presentation.title,
                detail: presentation.detail,
                provider: provider,
                reason: reason,
                source: .runtimeApp,
                startDate: now,
                endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
                meetingURL: nil,
                suggestedTranscriptTitle: nil
            ),
            score: presentation.score
        )
    }

    private func micCandidateID(for provider: MeetingPromptProvider) -> String {
        "mic:\(provider.rawValue)"
    }

    private func preferredCandidate(from sortedCandidates: [ScoredCandidate]) -> ScoredCandidate? {
        guard let first = sortedCandidates.first else { return nil }
        guard first.candidate.reason.isAdHocCallSignal else { return first }
        let calendarCandidate = sortedCandidates.first {
            $0.candidate.source == .calendarEvent &&
                $0.candidate.provider == first.candidate.provider
        }
        guard first.candidate.provider == .googleMeet else {
            return calendarCandidate ?? first
        }
        return sortedCandidates.first {
            $0.candidate.source == .calendarEvent &&
                $0.candidate.provider == first.candidate.provider &&
                (pendingUntil[$0.candidate.id] != nil || snoozedUntil[$0.candidate.id] != nil)
        } ?? first
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
        let runtimeSnapshot = MeetingPromptRuntimeSnapshot(
            runningBundleIDs: runningBundleIDs,
            frontmostBundleID: frontmostBundleID,
            recentNativeActivity: recentNativeActivity,
            runtimeSuppressedUntil: runtimeSuppressedUntil
        )

        return MeetingPromptSyntheticEvaluator.calendarCandidates(
            from: calendarEventSnapshots,
            now: now,
            runtimeSnapshot: runtimeSnapshot
        )
        .map { ScoredCandidate(candidate: $0.candidate, score: $0.score) }
    }

    private func provider(forBundleIdentifier bundleIdentifier: String) -> MeetingPromptProvider? {
        MeetingPromptProvider.allCases.first { $0.activeBundleIdentifiers.contains(bundleIdentifier) }
    }

    private func suppressRuntimePrompts(for provider: MeetingPromptProvider, until: Date) {
        suppressRuntimePrompts(for: provider, until: until, reason: nil)
    }

    private func suppressRuntimePrompts(for provider: MeetingPromptProvider, until: Date, reason: String?) {
        let existing = runtimeSuppressedUntil[provider] ?? .distantPast
        runtimeSuppressedUntil[provider] = max(existing, until)
        if let reason {
            runtimeSuppressionReasons[provider] = reason
        }
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
        guard calendarAccessGranted() else { return nil }

        return calendarEventSnapshots
            .filter { isRuntimeResumeEligibleCalendarSnapshot($0, for: targetProvider, after: now) }
            .min { $0.startDate < $1.startDate }
    }

    private func isRuntimeResumeEligibleCalendarSnapshot(
        _ snapshot: MeetingPromptCalendarEventSnapshot,
        for targetProvider: MeetingPromptProvider,
        after now: Date
    ) -> Bool {
        guard !snapshot.isAllDay else { return false }
        guard snapshot.provider == targetProvider else { return false }
        guard snapshot.meetingURL != nil else { return false }
        return snapshot.endDate > now
    }

    private func pruneExpiredEntries(now: Date) {
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        pendingUntil = pendingUntil.filter { $0.value > now }
        runtimeSuppressedUntil = runtimeSuppressedUntil.filter { $0.value > now }
        cooldownReasons = cooldownReasons.filter { entry in
            (snoozedUntil[entry.key] ?? pendingUntil[entry.key]) != nil
        }
        runtimeSuppressionReasons = runtimeSuppressionReasons.filter { entry in
            runtimeSuppressedUntil[entry.key] != nil
        }
        suppressionTelemetryUntil = suppressionTelemetryUntil.filter { $0.value > now }
        recentNativeActivity = recentNativeActivity.filter {
            now.timeIntervalSince($0.value) <= MeetingPromptHeuristics.runtimeActivityFreshness
        }
    }

    private func currentOwnCaptureActivity() -> MeetingPromptOwnCaptureActivity {
        if let activity = ownCaptureActivity?(), activity != .none {
            return activity
        }
        return isOwnCaptureActive?() == true ? .unknown : .none
    }

    private func recordSuppression(
        candidate: Candidate,
        reason: MeetingPromptSuppressionReason,
        now: Date,
        cooldownReason: String? = nil,
        captureActivity: MeetingPromptOwnCaptureActivity? = nil
    ) {
        let dedupeKey = [
            reason.rawValue,
            candidate.id,
            cooldownReason ?? "",
            captureActivity?.rawValue ?? ""
        ].joined(separator: "|")
        guard (suppressionTelemetryUntil[dedupeKey] ?? .distantPast) <= now else { return }
        suppressionTelemetryUntil[dedupeKey] = now.addingTimeInterval(suppressionTelemetryCooldown)
        onPromptSuppressed?(
            MeetingPromptSuppression(
                candidate: candidate,
                reason: reason,
                cooldownReason: cooldownReason,
                captureActivity: captureActivity
            )
        )
    }
}

// Built on the reader's queue because EKEvent objects must not cross threads.
// The synthetic evaluator owns URL/provider filtering so tests and production
// share the same prompt policy.
@available(macOS 14.0, *)
private extension MeetingPromptCalendarEventSnapshot {
    init?(event: EKEvent) {
        guard let startDate = event.startDate,
              let endDate = event.endDate else { return nil }

        let snapshot = MeetingPromptCalendarEventSnapshot(
            id: event.calendarItemIdentifier,
            title: event.title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay,
            url: event.url,
            location: event.location,
            notes: event.notes
        )
        guard snapshot.meetingURL != nil else { return nil }
        self = snapshot
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
