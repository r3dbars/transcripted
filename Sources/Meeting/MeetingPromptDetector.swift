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
    /// A detected ad-hoc call ended without a meeting recording and passed the
    /// `MissedCallNudgePolicy` gates (long enough, not declined, rate-limited).
    /// Wired in `TranscriptedApp` to the overlay's missed-call nudge.
    var onUnrecordedCallEnded: ((MeetingPromptUnrecordedCall) -> Void)?
    /// Every detected call ≥ `MeetingPromptCallTelemetry.minimumReportableCallDuration`
    /// ends with exactly one summary — recorded or not. Wired in
    /// `TranscriptedApp` to the `meeting_detected_call_ended` funnel event.
    var onDetectedCallEnded: ((MeetingPromptDetectedCallSummary) -> Void)?

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
    private var lastCalendarEventRefreshAt: Date?
    private var pollingTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var calendarChangeObserver: NSObjectProtocol?
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
    // Native conferencing bundle IDs confirmed playing audio output, pushed by
    // MicActivityMonitor's output side (listen-only / hard-muted call detection).
    private var audioOutputActiveBundleIDs: Set<String> = []
    // Consecutive unattended-countdown expiries per candidate id, so an ignored
    // prompt re-offers a couple of times before inheriting the full dismissal.
    private var promptExpiryHistory: [String: (count: Int, lastExpiredAt: Date)] = [:]

    // The live detected-call session assembled from the ad-hoc signals (mic /
    // output / camera). Tracked across evaluate() passes so a call that ends
    // unrecorded can raise the missed-call nudge.
    private struct DetectedCallSession {
        var providers: Set<MeetingPromptProvider>
        // Every ad-hoc reason seen during the call (mic/output/camera), for the
        // coarse signal_kinds funnel property.
        var seenReasons: Set<MeetingPromptReason>
        let startedAt: Date
        var sawMeetingRecording: Bool
        var userDeclined: Bool
        var promptShown: Bool
    }

    private var detectedCallSession: DetectedCallSession?
    private var lastMissedCallNudgeAt: Date?
    // Consecutive explicit dismissals per provider since the last accepted
    // recording — the "keeps hitting Not now" telemetry signal.
    private var dismissStreaks: [MeetingPromptProvider: Int] = [:]

    private let defaultSnoozeInterval: TimeInterval = 30 * 60
    private let pendingCooldown: TimeInterval = 90
    private let suppressionTelemetryCooldown: TimeInterval = 90
    private let pollIntervalNanoseconds: UInt64 = 20_000_000_000
    // Single fetch window covering both the near-term prompt window and the
    // farthest lookahead used for runtime-dismiss resume dates.
    private let calendarLookaheadInterval: TimeInterval = 12 * 60 * 60
    // Calendar queries are synchronous XPC work behind EventKit. Keep the 20s
    // prompt loop in-memory most of the time and refresh the EventKit snapshot
    // on a minutes-scale TTL or when EventKit tells us the calendar changed.
    private let calendarSnapshotRefreshInterval: TimeInterval = 5 * 60

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
        installCalendarChangeObserver()

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
        if let calendarChangeObserver {
            NotificationCenter.default.removeObserver(calendarChangeObserver)
            self.calendarChangeObserver = nil
        }
    }

    @discardableResult
    func dismiss(candidate: Candidate) -> MeetingPromptBackoffDecision {
        // An explicit dismissal during a live call means the user chose not to
        // record it — the missed-call nudge must respect that and stay quiet.
        detectedCallSession?.userDeclined = true
        dismissStreaks[candidate.provider, default: 0] += 1
        return dismiss(candidate: candidate, interval: nil)
    }

    /// Consecutive explicit dismissals for `provider` since the last accepted
    /// recording, for the dismiss-streak telemetry bucket.
    func dismissStreak(for provider: MeetingPromptProvider) -> Int {
        dismissStreaks[provider] ?? 0
    }

    /// What the ad-hoc sensors see right now, for prompt-decision telemetry.
    func currentSignalSnapshot() -> MeetingPromptSignalSnapshot {
        MeetingPromptSignalSnapshot(
            micActive: !micInputProviders().isEmpty,
            speakerActive: !audioOutputProviders().isEmpty,
            cameraActive: cameraInUse
        )
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
        detectedCallSession?.userDeclined = true
        dismissStreaks[candidate.provider, default: 0] += 1
        return dismiss(candidate: candidate, interval: interval)
    }

    /// The prompt countdown ran out with no interaction. That is weaker evidence
    /// of "don't record" than an explicit dismissal — the user may be heads-down
    /// in the call or on another Space — so schedule a short candidate-level
    /// re-offer instead of the provider-wide dismissal backoff. Capped at
    /// `MeetingPromptHeuristics.maxPromptExpiryReoffers` consecutive expiries;
    /// past the cap the candidate inherits the normal dismissal so an ignored
    /// call eventually goes quiet.
    @discardableResult
    func expire(candidate: Candidate) -> MeetingPromptBackoffDecision {
        let now = Date()
        var expiryCount = 1
        if let history = promptExpiryHistory[candidate.id],
           now.timeIntervalSince(history.lastExpiredAt) <= MeetingPromptHeuristics.promptExpiryStreakResetInterval {
            expiryCount = history.count + 1
        }
        promptExpiryHistory[candidate.id] = (expiryCount, now)

        guard MeetingPromptHeuristics.shouldReofferAfterExpiry(expiryCount: expiryCount) else {
            return dismiss(candidate: candidate)
        }

        // Candidate-level cooldown only — no `suppressRuntimePrompts` — so the
        // same call can re-offer once the interval passes.
        let until = now.addingTimeInterval(MeetingPromptHeuristics.promptExpiryReofferInterval)
        let decision = MeetingPromptBackoffDecision(kind: .expiredReoffer, until: until)
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = decision.kind.rawValue
        return decision
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
        // Recording is starting; the session is covered even if the recording
        // begins after the next evaluate() pass samples own-capture state.
        detectedCallSession?.sawMeetingRecording = true
        dismissStreaks[candidate.provider] = nil
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
        updateDetectedCallSession(
            signals: callSignals(frontmostBundleID: frontmostBundleID),
            now: now
        )

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
            // Any prompt shown while a call is live feeds the funnel outcome:
            // an unrecorded end now counts as "ignored", not "no_prompt".
            detectedCallSession?.promptShown = true
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
            lastCalendarEventRefreshAt = nil
            return
        }

        let now = Date()
        if let lastCalendarEventRefreshAt,
           now.timeIntervalSince(lastCalendarEventRefreshAt) < calendarSnapshotRefreshInterval {
            return
        }

        calendarEventSnapshots = await calendarReader.fetchMeetingEventSnapshots(
            start: now.addingTimeInterval(-MeetingPromptHeuristics.calendarReminderPostStartGrace),
            end: now.addingTimeInterval(calendarLookaheadInterval)
        )
        lastCalendarEventRefreshAt = now
    }

    private func installCalendarChangeObserver() {
        guard calendarChangeObserver == nil else { return }
        calendarChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastCalendarEventRefreshAt = nil
                await self.evaluate()
            }
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

    /// Pushed by `MicActivityMonitor`'s output side with the set of native
    /// conferencing bundle IDs confirmed to be playing audio output. Catches the
    /// listen-only / hard-muted join where nothing holds the mic; de-dupes with
    /// the mic and camera signals in `callSignals`.
    func updateAudioOutputUsers(_ bundleIDs: Set<String>) {
        guard bundleIDs != audioOutputActiveBundleIDs else { return }
        audioOutputActiveBundleIDs = bundleIDs
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    // MARK: - Detected-call session (missed-call nudge)

    /// Folds the current ad-hoc call signals into the running session. A
    /// nonempty→empty transition ends the call; if it was long enough,
    /// unrecorded, and not explicitly declined, `onUnrecordedCallEnded` fires.
    /// Runs every evaluate() pass, so signal-inactive edges from the monitors
    /// end the session promptly and the 20s poll bounds recording-overlap
    /// sampling. Meeting recordings keep the underlying app's signals alive
    /// (only our own bundle is filtered), so recording never splits a session.
    private func updateDetectedCallSession(
        signals: [(provider: MeetingPromptProvider, reason: MeetingPromptReason)],
        now: Date
    ) {
        let providers = Set(signals.map(\.provider))
        let reasons = Set(signals.map(\.reason))
        let isMeetingRecording = currentOwnCaptureActivity() == .meetingRecording

        guard var session = detectedCallSession else {
            if !providers.isEmpty {
                detectedCallSession = DetectedCallSession(
                    providers: providers,
                    seenReasons: reasons,
                    startedAt: now,
                    sawMeetingRecording: isMeetingRecording,
                    userDeclined: false,
                    promptShown: false
                )
            }
            return
        }

        if providers.isEmpty {
            detectedCallSession = nil
            finishDetectedCallSession(session, endedAt: now)
        } else {
            session.providers.formUnion(providers)
            session.seenReasons.formUnion(reasons)
            session.sawMeetingRecording = session.sawMeetingRecording || isMeetingRecording
            detectedCallSession = session
        }
    }

    private func finishDetectedCallSession(_ session: DetectedCallSession, endedAt: Date) {
        // A disabled auto-detect toggle empties the signals artificially —
        // neither the funnel event nor the nudge should fire off the back of
        // the user turning detection off.
        guard isMicInputPromptEnabled?() != false else { return }

        let duration = endedAt.timeIntervalSince(session.startedAt)
        let provider = session.providers.sorted { $0.rawValue < $1.rawValue }.first ?? .googleMeet

        if duration >= MeetingPromptCallTelemetry.minimumReportableCallDuration {
            onDetectedCallEnded?(
                MeetingPromptDetectedCallSummary(
                    provider: provider,
                    duration: duration,
                    wasRecorded: session.sawMeetingRecording,
                    promptOutcome: MeetingPromptCallTelemetry.promptOutcome(
                        promptShown: session.promptShown,
                        wasRecorded: session.sawMeetingRecording,
                        userDeclined: session.userDeclined
                    ),
                    signalKinds: MeetingPromptCallTelemetry.signalKinds(
                        micSeen: session.seenReasons.contains(.micInput),
                        speakerSeen: session.seenReasons.contains(.audioOutput),
                        cameraSeen: session.seenReasons.contains(.cameraInput)
                    )
                )
            )
        }

        guard MissedCallNudgePolicy.shouldNudge(
            duration: duration,
            sawMeetingRecording: session.sawMeetingRecording,
            userDeclined: session.userDeclined,
            lastNudgeAt: lastMissedCallNudgeAt,
            now: endedAt
        ) else { return }

        lastMissedCallNudgeAt = endedAt
        onUnrecordedCallEnded?(MeetingPromptUnrecordedCall(provider: provider, duration: duration))
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

    /// Ad-hoc call signals, tiered by attribution strength: the mic is the
    /// primary signal; native-app audio output is the standalone fallback when
    /// nothing holds the mic (the listen-only / hard-muted join, with real
    /// process attribution); the camera is the last standalone signal, so a
    /// normal mic-and-camera call is a single mic prompt and the camera's
    /// frontmost-based attribution never overrides or duplicates a stronger
    /// signal. Mirrors `MeetingPromptSyntheticEvaluator.callSignals` — keep both
    /// in lockstep.
    private func callSignals(
        frontmostBundleID: String?
    ) -> [(provider: MeetingPromptProvider, reason: MeetingPromptReason)] {
        let micProviders = micInputProviders()
        if !micProviders.isEmpty {
            return micProviders.map { ($0, .micInput) }
        }

        let outputProviders = audioOutputProviders()
        if !outputProviders.isEmpty {
            return outputProviders.map { ($0, .audioOutput) }
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

    private func audioOutputProviders() -> [MeetingPromptProvider] {
        Set(audioOutputActiveBundleIDs.compactMap(MeetingPromptProvider.audioOutputProvider(forBundleID:)))
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
        promptExpiryHistory = promptExpiryHistory.filter {
            now.timeIntervalSince($0.value.lastExpiredAt) <= MeetingPromptHeuristics.promptExpiryStreakResetInterval
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
