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
        /// What convinced us this is a call. Set on ad-hoc (mic / camera /
        /// output) candidates; `.none` for calendar and runtime prompts.
        var callEvidence: MeetingPromptCallEvidence = .none
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
    /// Injectable frontmost-app lookup. Unit tests override this with a fixed
    /// value so attribution never depends on which real app happens to be
    /// frontmost on the machine running the suite.
    var frontmostBundleIDProvider: () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    /// Returns false when the Settings toggle is off. This keeps late monitor
    /// callbacks quiet after the user disables auto call detection.
    var isMicInputPromptEnabled: (() -> Bool)?
    /// Window titles of the running browsers in the given bundle families,
    /// used only to classify a browser mic as a call or not. Defaults to the
    /// Accessibility reader; unit tests inject fixed titles.
    var browserWindowTitlesProvider: (Set<String>) async -> [BrowserWindowTitle] = { families in
        await BrowserWindowTitleReader.titles(forBrowserFamilies: families)
    }
    /// How long an unrecognized browser has to hold the mic before it prompts.
    /// Tests shrink these.
    var browserEvidenceTiming: BrowserCallEvidence.Timing = .standard

    private let calendarReader = MeetingPromptCalendarReader()
    private let calendarAccessGranted: () -> Bool
    private let fetchCalendarEventSnapshots: (Date, Date) async -> [MeetingPromptCalendarEventSnapshot]
    private let refreshesCalendarEventSnapshots: Bool
    // Cache of upcoming meeting-link events refreshed off-main on a TTL or
    // EventKit invalidation. The 20s prompt loop should stay in-memory while idle.
    // Dismiss/markAccepted/title paths must stay synchronous (overlay callbacks and
    // the recording-start title closure), so they read this cache instead of querying
    // EKEventStore on the main actor.
    private var calendarEventSnapshots: [MeetingPromptCalendarEventSnapshot] = []
    private var lastCalendarSnapshotRefreshAt: Date?
    private var lastCalendarAccessGranted: Bool?
    private var calendarSnapshotsNeedRefresh = true
    // Guards against redundant concurrent EKEventStore queries: evaluate() is invoked
    // from several independent, unstructured Task{} sources (poll loop, workspace
    // notifications, mic/camera/audio signal changes, .EKEventStoreChanged). Two of
    // those firing close together while a fetch is already in flight would otherwise
    // both pass the guard below (the need-refresh flags only clear after the await),
    // issuing a second redundant query. Callers don't need synchronously up-to-date
    // state on return — the same assumption the existing TTL-based skip already relies on.
    private var isFetchingCalendarSnapshots = false
    private var pollingTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var calendarStoreObserver: NSObjectProtocol?
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
    // Browser processes playing audio while a browser holds the mic, pushed by
    // MicActivityMonitor. Corroborates an unrecognized browser mic as a call.
    private var browserOutputActiveBundleIDs: Set<String> = []
    // When a browser first held the mic in the current browser mic session;
    // the unrecognized-site wait counts from here. Cleared once no browser has
    // held the mic for `micReleaseGrace`.
    private var browserMicSince: Date?
    private var browserMicEndTask: Task<Void, Never>?
    // When the camera came on, for a camera-only browser call (camera on, a
    // browser frontmost, nothing holding the mic). Same wait as the mic, but
    // counted from the later of the camera coming on and that browser coming
    // to the front, so a camera already on for another app does not skip it.
    private var cameraOnSince: Date?
    private var cameraEvidenceFamilies: Set<String> = []
    private var cameraEvidenceSince: Date?
    // What the window titles said during the current browser session (see
    // `BrowserTitleSession`).
    private var browserTitles: BrowserTitleSession?
    private var browserEvidenceRecheckTask: Task<Void, Never>?
    private var browserEvidenceRecheckAt: Date?
    // Persisted per-kind "Not now" learning (see MeetingPromptLearnedBackoff).
    private let learnedBackoff: MeetingPromptLearnedBackoff
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
        // Learning kinds the user said Not now to during this call, and when,
        // so the same call is not asked about again after the quiet window
        // ends (capped by `declinedThisCallLimit`).
        var declinedKinds: [String: Date] = [:]
        // Learning kinds this call actually produced a candidate for. Only
        // these count as a "yes" when the user records during the call.
        var candidateKinds: Set<String> = []
        // The provider a call-only tab title named, for the funnel event and
        // the nudge (the signal itself only says "some browser").
        var namedBrowserProvider: MeetingPromptProvider?
        // The prompt was held back by earlier Not nows. The user taught it to
        // stop, so the missed-call nudge stays quiet too.
        var learnedQuietSeen = false
        // Browser title verdicts seen during the call. A browser mic that was
        // only ever a known non-call site (ChatGPT voice) is not a call, so it
        // must not feed the funnel event or the missed-call nudge.
        var sawBrowserCallTitle = false
        var sawBrowserNonCallSite = false
        // Whether a meeting recording during this call already counted as a
        // "yes" for the learning.
        var countedRecordingForLearning = false
    }

    private var detectedCallSession: DetectedCallSession?
    private var lastMissedCallNudgeAt: Date?
    // Consecutive explicit dismissals per provider since the last accepted
    // recording — the "keeps hitting Not now" telemetry signal.
    private var dismissStreaks: [MeetingPromptProvider: Int] = [:]

    private let defaultSnoozeInterval: TimeInterval = 30 * 60
    // A Not now covers the rest of that call, but not forever: a signal that
    // never drops (a camera left on, a native app idling on output) must not
    // keep the next call of the same kind silent.
    private let declinedThisCallLimit: TimeInterval = 8 * 60 * 60
    private let pendingCooldown: TimeInterval = 90
    // One suppression event per candidate + reason per window. It was 90s,
    // which re-sent the same "still snoozed" event every poll for the whole
    // call and made suppressions most of the prompt event volume.
    private let suppressionTelemetryCooldown: TimeInterval = 15 * 60
    // Every state change that can *newly* justify a prompt already re-evaluates
    // immediately via an observer: workspace app activate/launch, EKEventStoreChanged,
    // and the mic/camera/audio-output push methods below. What none of those can
    // catch is a pure wall-clock threshold crossing — the calendar lead-time window
    // opening (`calendarReminderLeadTime`), a snooze/pending cooldown expiring, or a
    // runtime-dismiss resume date arriving — because nothing "happens" at that
    // instant except time passing. The poll exists solely to catch those, so it's
    // demoted to a slow safety net rather than removed: the widest of those windows
    // (calendarReminderPostStartGrace, 5 min) comfortably absorbs a 120s cadence
    // without missing a prompt window, at the cost of the poll-caught transitions
    // landing up to ~100s later than the old 20s cadence.
    private let pollIntervalNanoseconds: UInt64 = 120_000_000_000
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
        refreshesCalendarEventSnapshots: Bool = true,
        fetchCalendarEventSnapshots: ((Date, Date) async -> [MeetingPromptCalendarEventSnapshot])? = nil,
        learnedBackoffDefaults: UserDefaults? = nil
    ) {
        self.learnedBackoff = MeetingPromptLearnedBackoff(userDefaults: learnedBackoffDefaults)
        self.calendarAccessGranted = calendarAccessGranted
        self.calendarEventSnapshots = calendarEventSnapshots
        self.refreshesCalendarEventSnapshots = refreshesCalendarEventSnapshots
        self.fetchCalendarEventSnapshots = fetchCalendarEventSnapshots ?? { [calendarReader] start, end in
            await calendarReader.fetchMeetingEventSnapshots(start: start, end: end)
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        installWorkspaceObservers()
        installCalendarStoreObserver()

        pollingTask = Task { [weak self] in
            guard let self else { return }

            await evaluate(forceCalendarRefresh: true)

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
        browserEvidenceRecheckTask?.cancel()
        browserEvidenceRecheckTask = nil
        browserEvidenceRecheckAt = nil
        browserMicEndTask?.cancel()
        browserMicEndTask = nil
        browserTitles?.readTask?.cancel()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let calendarStoreObserver {
            NotificationCenter.default.removeObserver(calendarStoreObserver)
            self.calendarStoreObserver = nil
        }
    }

    /// Re-run prompt evaluation after a gate that was blocking prompts
    /// clears (own-capture ending). Workspace / sensor observers already
    /// re-evaluate on their own edges; this covers the case where a call
    /// started during dictation and would otherwise wait for the poll.
    func requestEvaluation() {
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    @discardableResult
    func dismiss(candidate: Candidate) -> MeetingPromptBackoffDecision {
        // An explicit dismissal during a live call means the user chose not to
        // record it — the missed-call nudge must respect that and stay quiet.
        detectedCallSession?.userDeclined = true
        dismissStreaks[candidate.provider, default: 0] += 1
        let decision = dismiss(candidate: candidate, interval: nil)
        return applyLearnedDismissal(candidate: candidate, decision: decision)
    }

    /// Feeds an explicit Not now on an ad-hoc prompt into the persisted
    /// learning: the same call is not asked about again, and consecutive Not
    /// nows for the same kind of call stay quiet longer. Returns the longer of
    /// the normal backoff and the learned one.
    private func applyLearnedDismissal(
        candidate: Candidate,
        decision: MeetingPromptBackoffDecision
    ) -> MeetingPromptBackoffDecision {
        guard let kind = candidate.learnedBackoffKind else { return decision }
        let now = Date()
        // A Not now to any browser prompt covers the whole browser call: the
        // user focusing the Meet tab a minute later must not re-ask it under
        // its real name.
        let declined = MeetingPromptLearnedBackoff.browserKinds.contains(kind)
            ? MeetingPromptLearnedBackoff.browserKinds
            : [kind]
        for declinedKind in declined {
            detectedCallSession?.declinedKinds[declinedKind] = now
        }
        let learnedUntil = learnedBackoff.recordDismissal(kind: kind, now: now)
        // A first Not now learns the same 30 minutes the normal backoff
        // already gives; only a longer learned window replaces the decision
        // (the slack absorbs the two clock reads being a moment apart).
        guard learnedUntil.timeIntervalSince(decision.until) > 60 else { return decision }

        let learned = MeetingPromptBackoffDecision(kind: .learnedQuiet, until: learnedUntil)
        snoozedUntil[candidate.id] = learnedUntil
        pendingUntil[candidate.id] = learnedUntil
        cooldownReasons[candidate.id] = learned.kind.rawValue
        if candidate.callEvidence.quietsProviderOnDismiss {
            suppressRuntimePrompts(for: candidate.provider, until: learnedUntil, reason: learned.kind.rawValue)
        }
        return learned
    }

    /// Forgets every learned Not now. Called when the user turns auto call
    /// detection back on, which is the reset for a prompt learned off.
    func resetLearnedBackoff() {
        learnedBackoff.reset()
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
    /// past the cap the candidate gets the same quiet backoff as `dismiss`,
    /// but is not marked `userDeclined` and does not increment the dismiss
    /// streak. An ignored call goes quiet without being recorded as an
    /// explicit no, so a missed-call nudge can still fire.
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
            // Quiet suppress only. The public `dismiss(candidate:)` path is
            // the user's Not now tap — it sets userDeclined and grows the
            // streak. An unattended countdown past the cap must not.
            return dismiss(candidate: candidate, interval: nil)
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
            // A browser prompt that could not name its call (a guess from
            // time on the mic, the camera, or a call site in front) backs off
            // on its own candidate id only. Silencing the whole provider would
            // also hide a real Meet tab that shows up a few minutes after a
            // Not now to ChatGPT voice, or native Teams after a Teams chat tab.
            if candidate.callEvidence.quietsProviderOnDismiss {
                suppressRuntimePrompts(for: candidate.provider, until: until, reason: decision.kind.rawValue)
            }
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
        if let kind = candidate.learnedBackoffKind {
            learnedBackoff.recordAccepted(kind: kind, now: now)
            detectedCallSession?.countedRecordingForLearning = true
        }
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

    private func evaluate(forceCalendarRefresh: Bool = false) async {
        await refreshCalendarEventSnapshots(force: forceCalendarRefresh)

        let now = Date()
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))
        let frontmostBundleID = frontmostBundleIDProvider()
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

    private func refreshCalendarEventSnapshots(force: Bool = false) async {
        guard refreshesCalendarEventSnapshots else { return }
        let accessGranted = calendarAccessGranted()
        let accessChanged = lastCalendarAccessGranted.map { $0 != accessGranted } ?? true
        lastCalendarAccessGranted = accessGranted

        guard accessGranted else {
            calendarEventSnapshots = []
            lastCalendarSnapshotRefreshAt = Date()
            calendarSnapshotsNeedRefresh = false
            return
        }

        let now = Date()
        let refreshExpired = lastCalendarSnapshotRefreshAt.map {
            now.timeIntervalSince($0) >= calendarSnapshotRefreshInterval
        } ?? true
        guard !isFetchingCalendarSnapshots,
              force || accessChanged || calendarSnapshotsNeedRefresh || refreshExpired
        else { return }

        isFetchingCalendarSnapshots = true
        calendarEventSnapshots = await fetchCalendarEventSnapshots(
            now.addingTimeInterval(-MeetingPromptHeuristics.calendarReminderPostStartGrace),
            now.addingTimeInterval(calendarLookaheadInterval)
        )
        lastCalendarSnapshotRefreshAt = now
        calendarSnapshotsNeedRefresh = false
        isFetchingCalendarSnapshots = false
    }

    private func installCalendarStoreObserver() {
        guard calendarStoreObserver == nil else { return }
        calendarStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.calendarSnapshotsNeedRefresh = true
                await self?.evaluate(forceCalendarRefresh: true)
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
        if bundleIDs.contains(where: MeetingPromptProvider.isBrowserBundleID) {
            browserMicEndTask?.cancel()
            browserMicEndTask = nil
            if browserMicSince == nil {
                browserMicSince = Date()
            }
        } else if browserMicSince != nil, browserMicEndTask == nil {
            scheduleBrowserMicSessionEnd()
        }
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    /// Pushed by `MicActivityMonitor` with the browser processes playing audio
    /// while a browser holds the mic. Someone talking back makes an
    /// unrecognized browser mic look like a call, so the prompt comes sooner.
    func updateBrowserOutputUsers(_ bundleIDs: Set<String>) {
        guard bundleIDs != browserOutputActiveBundleIDs else { return }
        browserOutputActiveBundleIDs = bundleIDs
        guard browserMicSince != nil else { return }
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
        cameraOnSince = inUse ? Date() : nil
        cameraEvidenceFamilies = []
        cameraEvidenceSince = nil
        if !inUse, browserMicSince == nil {
            // A camera-only browser call just ended; forget its title verdict.
            endBrowserMicSession()
        }
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
            if isMeetingRecording, !session.countedRecordingForLearning {
                // The user started a meeting (from the menu, the hotkey, or a
                // prompt) while this call was going on: a "yes" for the kinds
                // of prompt this call raised (or held back), which clears
                // their learned quiet. A recording started before any prompt
                // was considered (⌥M, then join) teaches nothing.
                let kinds = session.candidateKinds.union(session.declinedKinds.keys)
                if !kinds.isEmpty {
                    session.countedRecordingForLearning = true
                    for kind in kinds {
                        learnedBackoff.recordAccepted(kind: kind, now: now)
                    }
                }
            }
            detectedCallSession = session
        }
    }

    private func finishDetectedCallSession(_ session: DetectedCallSession, endedAt: Date) {
        // A disabled auto-detect toggle empties the signals artificially —
        // neither the funnel event nor the nudge should fire off the back of
        // the user turning detection off.
        guard isMicInputPromptEnabled?() != false else { return }
        // Browser mic use that only ever showed a known non-call site (ChatGPT
        // voice, Loom) was not a call: no funnel event, no missed-call nudge.
        // Unless the user treated it as one (a prompt showed, or they
        // recorded), which the funnel must still count.
        if session.providers == [.googleMeet], session.sawBrowserNonCallSite, !session.sawBrowserCallTitle,
           !session.sawMeetingRecording, !session.promptShown {
            return
        }

        let duration = endedAt.timeIntervalSince(session.startedAt)
        let provider: MeetingPromptProvider
        if session.providers == [.googleMeet], let named = session.namedBrowserProvider {
            provider = named
        } else {
            provider = session.providers.sorted { $0.rawValue < $1.rawValue }.first ?? .googleMeet
        }

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

        // The user taught the prompt to stay quiet for this kind of call; a
        // "you didn't record that" nudge afterwards would undo that.
        guard !session.learnedQuietSeen else { return }

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
                    candidate: micInputCandidate(for: $0.provider, reason: $0.reason, evidence: .none, now: now).candidate,
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
                    candidate: micInputCandidate(for: $0.provider, reason: $0.reason, evidence: .none, now: now).candidate,
                    reason: .ownCaptureActive,
                    now: now,
                    captureActivity: captureActivity
                )
            }
            return []
        }

        var candidates: [ScoredCandidate] = []
        for signal in signals {
            guard let scored = adHocCandidate(for: signal, frontmostBundleID: frontmostBundleID, now: now) else {
                continue
            }
            let candidate = scored.candidate
            if let kind = candidate.learnedBackoffKind {
                detectedCallSession?.candidateKinds.insert(kind)
            }
            if candidate.isBrowserCall {
                // Decided for this browser session: a prompt now, or held back
                // by the user's own earlier answers. No more title re-reads.
                cancelBrowserEvidenceRecheck()
            }

            if let suppressedUntil = runtimeSuppressedUntil[candidate.provider], suppressedUntil > now {
                recordSuppression(
                    candidate: candidate,
                    reason: .runtimeSuppressed,
                    now: now,
                    cooldownReason: runtimeSuppressionReasons[candidate.provider]
                )
                continue
            }

            if let learned = learnedSuppression(for: candidate, now: now) {
                detectedCallSession?.learnedQuietSeen = true
                recordSuppression(
                    candidate: candidate,
                    reason: learned.reason,
                    now: now,
                    cooldownReason: learned.cooldownReason
                )
                continue
            }

            // The browser prompts have different ids (generic, call site, and
            // one per named provider) so a Not now to one does not snooze the
            // others. They are still one call on screen, so a prompt already
            // showing for any of them keeps the rest back.
            if candidate.isBrowserCall,
               browserCandidateIDs(besides: candidate.id).contains(where: { isPromptShowing(candidateID: $0, now: now) }) {
                recordSuppression(
                    candidate: candidate,
                    reason: .pendingCandidate,
                    now: now,
                    cooldownReason: "prompt_pending"
                )
                continue
            }

            candidates.append(scored)
        }
        return candidates
    }

    // MARK: - Browser call evidence

    /// What the window titles said during one browser session (a browser mic
    /// session, or a camera-only browser call).
    private struct BrowserTitleSession {
        var families: Set<String>
        /// The latest read's verdict; `nil` until the first read lands.
        var latest: BrowserCallTitleVerdict?
        var readAt: Date?
        /// The latest read returned any titles. False without Accessibility,
        /// when a real call and ChatGPT voice look the same.
        var titlesReadable = false
        /// A call-only title was seen. Sticky: switching away from the Meet
        /// tab mid-call must not demote it.
        var namedCall: MeetingPromptProvider?
        /// A known non-call site was focused. Sticky too, so ChatGPT voice
        /// does not prompt when the user clicks to another tab; only a
        /// call-only title can still win.
        var sawNonCallSite = false
        var readTask: Task<Void, Never>?
        var readToken = 0

        var verdict: BrowserCallTitleVerdict? {
            if let namedCall { return .call(provider: namedCall) }
            if sawNonCallSite { return .notCall }
            return latest
        }
    }

    private var browserTitleReadCounter = 0

    /// Turns one ad-hoc signal into a candidate. Native apps pass straight
    /// through. A browser has to show it is in a call first (see
    /// `BrowserCallEvidence`); until then this returns `nil`, schedules a
    /// re-check, and reports why the prompt is held back.
    private func adHocCandidate(
        for signal: (provider: MeetingPromptProvider, reason: MeetingPromptReason),
        frontmostBundleID: String?,
        now: Date
    ) -> ScoredCandidate? {
        // `.googleMeet` from the signal mapping always means "some browser";
        // native apps never map to it.
        guard signal.provider == .googleMeet else {
            return micInputCandidate(for: signal.provider, reason: signal.reason, evidence: .nativeApp, now: now)
        }

        let families = browserFamiliesForEvidence(reason: signal.reason, frontmostBundleID: frontmostBundleID)
        let since = browserEvidenceStart(reason: signal.reason, families: families, now: now)
        let playingAudio = browserIsPlayingAudio(families: families)

        guard let verdict = currentBrowserTitleVerdict(families: families, now: now) else {
            // The first title read of this session is still running (well
            // under a second); it re-evaluates when it lands. Too brief to be
            // worth a suppression event.
            return nil
        }

        switch verdict {
        case .call(let provider):
            detectedCallSession?.sawBrowserCallTitle = true
            detectedCallSession?.namedBrowserProvider = provider
        case .notCall:
            detectedCallSession?.sawBrowserNonCallSite = true
        case .callSite, .unknown:
            break
        }

        let decision = BrowserCallEvidence.decide(
            verdict: verdict,
            cameraInUse: cameraInUse,
            browserPlayingAudio: playingAudio,
            micSince: since,
            now: now,
            timing: browserEvidenceTiming
        )

        switch decision {
        case .prompt(let provider, let evidence):
            return micInputCandidate(
                for: provider ?? .googleMeet,
                reason: signal.reason,
                evidence: evidence,
                now: now
            )
        case .wait(let recheckAt):
            // Keep looking: the user may switch to the Meet tab, or the wait
            // may run out.
            scheduleBrowserEvidenceRecheck(at: recheckAt, now: now)
            recordSuppression(
                candidate: micInputCandidate(
                    for: .googleMeet,
                    reason: signal.reason,
                    evidence: pendingBrowserEvidence(verdict: verdict, playingAudio: playingAudio),
                    now: now
                ).candidate,
                reason: .awaitingCallEvidence,
                now: now
            )
            return nil
        case .notACall:
            // Only a call-only title can still change this, so look again
            // now and then rather than on the fast cadence.
            scheduleBrowserEvidenceRecheck(
                at: now.addingTimeInterval(browserEvidenceTiming.nonCallSiteRecheckInterval),
                now: now
            )
            recordSuppression(
                candidate: micInputCandidate(for: .googleMeet, reason: signal.reason, evidence: .nonCallSite, now: now).candidate,
                reason: .notACall,
                now: now
            )
            return nil
        }
    }

    /// The evidence a held-back browser prompt would carry, for telemetry.
    private func pendingBrowserEvidence(
        verdict: BrowserCallTitleVerdict,
        playingAudio: Bool
    ) -> MeetingPromptCallEvidence {
        if case .callSite = verdict { return .callSite }
        if playingAudio { return .micAndOutput }
        if cameraInUse { return .camera }
        return .micOnly
    }

    /// Browser families whose windows can name the call: the ones holding the
    /// mic, or for a camera-only signal the frontmost browser.
    private func browserFamiliesForEvidence(reason: MeetingPromptReason, frontmostBundleID: String?) -> Set<String> {
        if reason == .cameraInput {
            return Set([frontmostBundleID].compactMap { $0 }.compactMap(MeetingPromptProvider.browserFamily(forBundleID:)))
        }
        return Set(micActiveBundleIDs.compactMap(MeetingPromptProvider.browserFamily(forBundleID:)))
    }

    /// When the wait for this browser signal started. For the mic, when a
    /// browser first held it. For the camera, the later of the camera coming
    /// on and this browser being the one in front, so a camera already on
    /// for another app does not let a browser skip the wait.
    private func browserEvidenceStart(reason: MeetingPromptReason, families: Set<String>, now: Date) -> Date {
        guard reason == .cameraInput else {
            return browserMicSince ?? now
        }
        if cameraEvidenceSince == nil || cameraEvidenceFamilies != families {
            cameraEvidenceFamilies = families
            cameraEvidenceSince = now
        }
        return max(cameraOnSince ?? now, cameraEvidenceSince ?? now)
    }

    private func browserIsPlayingAudio(families: Set<String>) -> Bool {
        let outputFamilies = Set(browserOutputActiveBundleIDs.compactMap(MeetingPromptProvider.browserFamily(forBundleID:)))
        return !families.isDisjoint(with: outputFamilies)
    }

    /// What the window titles say for this browser session, with the sticky
    /// rules applied, or `nil` while the session's first read is running.
    /// Starts a background read when the last one is old enough; its result
    /// re-evaluates.
    private func currentBrowserTitleVerdict(families: Set<String>, now: Date) -> BrowserCallTitleVerdict? {
        guard !families.isEmpty else { return .unknown }
        if var session = browserTitles, !session.families.isDisjoint(with: families) {
            // Same browser (another one may have joined or left): keep what
            // its titles already said.
            session.families = families
            browserTitles = session
        } else {
            // A different browser: its own titles, its own verdict.
            browserTitles?.readTask?.cancel()
            browserTitles = BrowserTitleSession(families: families)
        }
        guard let session = browserTitles else { return nil }
        let readIsStale = session.readAt.map { now.timeIntervalSince($0) >= browserEvidenceTiming.titleReadSpacing } ?? true
        if session.namedCall == nil, session.readTask == nil, readIsStale {
            startBrowserTitleRead(families: families)
        }
        return session.verdict
    }

    private func startBrowserTitleRead(families: Set<String>) {
        browserTitleReadCounter += 1
        let token = browserTitleReadCounter
        let provider = browserWindowTitlesProvider
        browserTitles?.readToken = token
        browserTitles?.readTask = Task { @MainActor [weak self] in
            let titles = await provider(families)
            guard !Task.isCancelled, let self, self.browserTitles?.readToken == token else { return }
            self.applyBrowserTitles(titles, now: Date())
            await self.evaluate()
        }
    }

    private func applyBrowserTitles(_ titles: [BrowserWindowTitle], now: Date) {
        guard var session = browserTitles else { return }
        let verdict = BrowserCallEvidence.classify(titles)
        session.readTask = nil
        session.readAt = now
        session.latest = verdict
        session.titlesReadable = !titles.isEmpty
        switch verdict {
        case .call(let provider):
            session.namedCall = provider
        case .notCall:
            session.sawNonCallSite = true
        case .callSite, .unknown:
            break
        }
        browserTitles = session
    }

    private func scheduleBrowserEvidenceRecheck(at date: Date, now: Date) {
        if let pending = browserEvidenceRecheckAt, pending > now, pending <= date {
            return
        }
        browserEvidenceRecheckTask?.cancel()
        browserEvidenceRecheckAt = date
        let delay = max(0.05, date.timeIntervalSince(now))
        browserEvidenceRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browserEvidenceRecheckAt = nil
            self.browserEvidenceRecheckTask = nil
            await self.evaluate()
        }
    }

    private func cancelBrowserEvidenceRecheck() {
        browserEvidenceRecheckTask?.cancel()
        browserEvidenceRecheckTask = nil
        browserEvidenceRecheckAt = nil
    }

    /// No browser holds the mic. Keep the session for `micReleaseGrace` in
    /// case it comes straight back (Safari lets go of the mic while muted).
    private func scheduleBrowserMicSessionEnd() {
        let grace = browserEvidenceTiming.micReleaseGrace
        guard grace > 0 else {
            endBrowserMicSession()
            return
        }
        browserMicEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browserMicEndTask = nil
            guard !self.micActiveBundleIDs.contains(where: MeetingPromptProvider.isBrowserBundleID) else { return }
            self.endBrowserMicSession()
        }
    }

    /// The browser session is over: forget the title verdict and stop
    /// re-checking. The next browser mic use starts its own wait.
    private func endBrowserMicSession() {
        browserMicSince = nil
        browserMicEndTask?.cancel()
        browserMicEndTask = nil
        browserTitles?.readTask?.cancel()
        browserTitles = nil
        cancelBrowserEvidenceRecheck()
    }

    /// Providers a browser tab can be named after (see
    /// `BrowserCallEvidence.inCallProvider`).
    private static let browserNamedProviders: [MeetingPromptProvider] = [.googleMeet, .teams, .zoom]

    private func browserCandidateIDs(besides id: String) -> [String] {
        (Self.browserNamedProviders.map { micCandidateID(for: $0) }
            + [Self.unverifiedBrowserCandidateID, Self.browserCallSiteCandidateID])
            .filter { $0 != id }
    }

    /// A prompt for `candidateID` was presented within the pending window and
    /// has not been answered. A dismissal also writes `pendingUntil` (for its
    /// whole backoff), so the cooldown reason tells the two apart.
    private func isPromptShowing(candidateID: String, now: Date) -> Bool {
        guard let until = pendingUntil[candidateID], until > now else { return false }
        return cooldownReasons[candidateID] == "prompt_pending"
    }

    /// Why the persisted learning keeps this ad-hoc candidate quiet, or `nil`.
    private func learnedSuppression(
        for candidate: Candidate,
        now: Date
    ) -> (reason: MeetingPromptSuppressionReason, cooldownReason: String)? {
        guard let kind = candidate.learnedBackoffKind else { return nil }
        if let declinedAt = detectedCallSession?.declinedKinds[kind],
           now.timeIntervalSince(declinedAt) < declinedThisCallLimit {
            return (.declinedThisCall, MeetingPromptSuppressionReason.declinedThisCall.rawValue)
        }
        // Turning a kind off for good needs the titles: without them a real
        // Meet call is just as "unrecognized" as ChatGPT voice.
        if browserTitles?.titlesReadable == true, learnedBackoff.isLearnedOff(kind: kind, now: now) {
            return (.learnedQuiet, "learned_off")
        }
        if learnedBackoff.quietUntil(for: kind, now: now) != nil {
            return (.learnedQuiet, MeetingPromptBackoffKind.learnedQuiet.rawValue)
        }
        return nil
    }

    /// Ad-hoc call signals, tiered by attribution strength: the mic is the
    /// primary signal; native-app audio output is the standalone fallback when
    /// nothing holds the mic (the listen-only / hard-muted join, with real
    /// process attribution); the camera is the last standalone signal, so a
    /// normal mic-and-camera call is a single mic prompt and the camera's
    /// frontmost-based attribution never overrides or duplicates a stronger
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
        evidence: MeetingPromptCallEvidence,
        now: Date
    ) -> ScoredCandidate {
        // A browser call we could not name (a guess from time on the mic, the
        // camera, or a call site in front) keeps the neutral title: it could
        // be Meet, Zoom web, or Teams web. A call-only tab title gets the
        // real name.
        let isGenericBrowserCall: Bool
        let id: String
        switch evidence {
        case .tabTitle, .nativeApp:
            isGenericBrowserCall = false
            id = micCandidateID(for: provider)
        case .none:
            isGenericBrowserCall = provider == .googleMeet
            id = micCandidateID(for: provider)
        case .callSite:
            isGenericBrowserCall = true
            id = Self.browserCallSiteCandidateID
        case .camera, .micAndOutput, .micOnly, .nonCallSite:
            isGenericBrowserCall = true
            id = Self.unverifiedBrowserCandidateID
        }
        let title = isGenericBrowserCall
            ? "Call detected in your browser"
            : "\(provider.displayName) call detected"
        let presentation = MeetingPromptHeuristics.micInputPresentation(title: title)

        return ScoredCandidate(
            candidate: Candidate(
                id: id,
                title: presentation.title,
                detail: presentation.detail,
                provider: provider,
                reason: reason,
                source: .runtimeApp,
                startDate: now,
                endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
                meetingURL: nil,
                suggestedTranscriptTitle: nil,
                callEvidence: evidence
            ),
            score: presentation.score
        )
    }

    private func micCandidateID(for provider: MeetingPromptProvider) -> String {
        "mic:\(provider.rawValue)"
    }

    /// The generic browser prompt with no call title behind it. Kept apart
    /// from `mic:googleMeet` so a Not now to it only snoozes itself.
    static let unverifiedBrowserCandidateID = "mic:browser"
    /// The generic browser prompt with a call app or site in front (Teams
    /// chat, a Slack huddle). Its own id for the same reason.
    static let browserCallSiteCandidateID = "mic:browser-call"

    private func preferredCandidate(from sortedCandidates: [ScoredCandidate]) -> ScoredCandidate? {
        guard let first = sortedCandidates.first else { return nil }
        guard first.candidate.reason.isAdHocCallSignal else { return first }
        let calendarCandidate = sortedCandidates.first {
            $0.candidate.source == .calendarEvent &&
                $0.candidate.provider == first.candidate.provider
        }
        // A native app, or a browser tab whose title named the provider, can
        // take the matching calendar event's title. A generic browser call
        // could be any provider, so it only defers to a calendar prompt that
        // is already showing or snoozed.
        guard first.candidate.isGenericBrowserCall else {
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

        return MeetingPromptCalendarScoring.calendarCandidates(
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
