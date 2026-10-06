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

    struct ScoredCandidate {
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
    /// frontmost on the machine running the suite. The bundle ID is read off
    /// the main thread, like `runningBundleIDsProvider`.
    var frontmostBundleIDProvider: @MainActor () async -> String? = {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return await RunningApplicationsReader.bundleIdentifier(of: app)
    }
    /// Returns false when the Settings toggle is off. This keeps late monitor
    /// callbacks quiet after the user disables auto call detection.
    var isMicInputPromptEnabled: (() -> Bool)?
    /// Bundle IDs of the running apps. Reads off the main thread, because a
    /// slow LaunchServices reply here froze the app for 5+ seconds in 1.1.66.
    var runningBundleIDsProvider: () async -> Set<String> = {
        await RunningApplicationsReader.bundleIdentifiers()
    }
    /// Window titles of the running browsers in the given bundle families,
    /// used only to classify a browser mic as a call or not. Defaults to the
    /// Accessibility reader; unit tests inject fixed titles.
    var browserWindowTitlesProvider: (Set<String>) async -> [BrowserWindowTitle] = { families in
        await BrowserWindowTitleReader.titles(forBrowserFamilies: families)
    }
    /// How long an unrecognized browser has to hold the mic before it prompts.
    /// Tests shrink these.
    var browserEvidenceTiming: BrowserCallEvidence.Timing = .standard

    // State below that isn't `private` is only internal because the
    // MeetingPromptDetector+*.swift extensions use it. Treat it as private
    // to the type.
    let calendarAccessGranted: () -> Bool
    private let fetchCalendarEventSnapshots: (Date, Date) async -> [MeetingPromptCalendarEventSnapshot]
    private let refreshesCalendarEventSnapshots: Bool
    // Cache of upcoming meeting-link events refreshed off-main on a TTL or
    // EventKit invalidation. The 20s prompt loop should stay in-memory while idle.
    // Dismiss/markAccepted/title paths must stay synchronous (overlay callbacks and
    // the recording-start title closure), so they read this cache instead of querying
    // EKEventStore on the main actor.
    private(set) var calendarEventSnapshots: [MeetingPromptCalendarEventSnapshot] = []
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
    // Evaluation passes that have been started and not finished yet, counting
    // the title reads that re-run evaluate when they land. Lets callers wait
    // for the detector to settle instead of guessing how long it takes.
    var evaluationsInFlight = 0
    private var settledWaiters: [CheckedContinuation<Void, Never>] = []
    var workspaceObservers: [NSObjectProtocol] = []
    private var calendarStoreObserver: NSObjectProtocol?
    var snoozedUntil: [String: Date] = [:]
    var pendingUntil: [String: Date] = [:]
    var recentNativeActivity: [MeetingPromptProvider: Date] = [:]
    var runtimeSuppressedUntil: [MeetingPromptProvider: Date] = [:]
    var cooldownReasons: [String: String] = [:]
    var runtimeSuppressionReasons: [MeetingPromptProvider: String] = [:]
    private var suppressionTelemetryUntil: [String: Date] = [:]
    // Bundle IDs currently holding the mic input, pushed by MicActivityMonitor.
    var micActiveBundleIDs: Set<String> = []
    // Whether a camera is confirmed in use, pushed by CameraActivityMonitor.
    var cameraInUse = false
    // Native conferencing bundle IDs confirmed playing audio output, pushed by
    // MicActivityMonitor's output side (listen-only / hard-muted call detection).
    var audioOutputActiveBundleIDs: Set<String> = []
    // Browser processes playing audio while a browser holds the mic, pushed by
    // MicActivityMonitor. Corroborates an unrecognized browser mic as a call.
    var browserOutputActiveBundleIDs: Set<String> = []
    // When a browser first held the mic in the current browser mic session;
    // the unrecognized-site wait counts from here. Cleared once no browser has
    // held the mic for `micReleaseGrace`.
    var browserMicSince: Date?
    var browserMicEndTask: Task<Void, Never>?
    // When the camera came on, for a camera-only browser call (camera on, a
    // browser frontmost, nothing holding the mic). Same wait as the mic, but
    // counted from the later of the camera coming on and that browser coming
    // to the front, so a camera already on for another app does not skip it.
    var cameraOnSince: Date?
    var cameraEvidenceFamilies: Set<String> = []
    var cameraEvidenceSince: Date?
    // What the window titles said during the current browser session (see
    // `BrowserTitleSession`).
    var browserTitles: BrowserTitleSession?
    var browserEvidenceRecheckTask: Task<Void, Never>?
    var browserEvidenceRecheckAt: Date?
    // Persisted per-kind "Not now" learning (see MeetingPromptLearnedBackoff).
    let learnedBackoff: MeetingPromptLearnedBackoff
    // Consecutive unattended-countdown expiries per candidate id, so an ignored
    // prompt re-offers a couple of times before inheriting the full dismissal.
    var promptExpiryHistory: [String: (count: Int, lastExpiredAt: Date)] = [:]
    var browserTitleReadCounter = 0
    // Set by `adHocCandidate` during one evaluate pass when a browser session's
    // first title read has not landed yet.
    var browserFirstTitleReadPending = false

    var detectedCallSession: DetectedCallSession?
    var lastMissedCallNudgeAt: Date?
    // Consecutive explicit dismissals per provider since the last accepted
    // recording — the "keeps hitting Not now" telemetry signal.
    var dismissStreaks: [MeetingPromptProvider: Int] = [:]

    let defaultSnoozeInterval: TimeInterval = 30 * 60
    // A Not now covers the rest of that call, but not forever: a signal that
    // never drops (a camera left on, a native app idling on output) must not
    // keep the next call of the same kind silent.
    let declinedThisCallLimit: TimeInterval = 8 * 60 * 60
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
    // landing up to ~100s later than the old 20s cadence. The 15 s tolerance
    // lets macOS batch this wake with others; it stays far inside that window.
    // The suspending clock keeps the old Task.sleep(nanoseconds:) behavior of
    // not counting time the Mac spent asleep.
    private let pollInterval: Duration = .seconds(120)
    private let pollTolerance: Duration = .seconds(15)
    // Single fetch window covering both the near-term prompt window and the
    // farthest lookahead used for runtime-dismiss resume dates.
    private let calendarLookaheadInterval: TimeInterval = 12 * 60 * 60
    // Calendar queries are synchronous XPC work behind EventKit. Keep the 20s
    // prompt loop in-memory most of the time and refresh the EventKit snapshot
    // on a minutes-scale TTL or when EventKit tells us the calendar changed.
    private let calendarSnapshotRefreshInterval: TimeInterval = 5 * 60

    /// The user's current meeting shortcut as the menu bar shows it, read
    /// each time a prompt is built so a rebound shortcut shows up at once.
    let meetingShortcutDisplay: () -> String

    init(
        calendarAccessGranted: @escaping () -> Bool = { TranscriptedPermissionAccess.calendarAccessGranted() },
        calendarEventSnapshots: [MeetingPromptCalendarEventSnapshot] = [],
        refreshesCalendarEventSnapshots: Bool = true,
        fetchCalendarEventSnapshots: ((Date, Date) async -> [MeetingPromptCalendarEventSnapshot])? = nil,
        learnedBackoffDefaults: UserDefaults? = nil,
        meetingShortcutDisplay: @escaping () -> String = {
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.meetingBinding())
        }
    ) {
        self.learnedBackoff = MeetingPromptLearnedBackoff(userDefaults: learnedBackoffDefaults)
        self.meetingShortcutDisplay = meetingShortcutDisplay
        self.calendarAccessGranted = calendarAccessGranted
        self.calendarEventSnapshots = calendarEventSnapshots
        self.refreshesCalendarEventSnapshots = refreshesCalendarEventSnapshots
        if let fetchCalendarEventSnapshots {
            self.fetchCalendarEventSnapshots = fetchCalendarEventSnapshots
        } else {
            // Only the real reader opens an EKEventStore, so a detector given
            // its own fetch (the unit tests) never touches EventKit.
            let calendarReader = MeetingPromptCalendarReader()
            self.fetchCalendarEventSnapshots = { start, end in
                await calendarReader.fetchMeetingEventSnapshots(start: start, end: end)
            }
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        installWorkspaceObservers()
        installCalendarStoreObserver()

        evaluationsInFlight += 1
        pollingTask = Task { [weak self] in
            guard let self else { return }

            await evaluate(forceCalendarRefresh: true)
            finishEvaluation()

            // Later poll passes aren't counted as in flight: they are the
            // slow safety net, not something a caller is waiting on.
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval, tolerance: pollTolerance, clock: .suspending)
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
        endBrowserMicSession()
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
        scheduleEvaluation()
    }

    /// Returns once every evaluation already started (and any title read or
    /// evaluation those start in turn) has finished. Timed re-checks that are
    /// still sleeping don't count.
    func waitUntilEvaluationsSettle() async {
        while evaluationsInFlight > 0 {
            await withCheckedContinuation { settledWaiters.append($0) }
        }
    }

    func scheduleEvaluation(forceCalendarRefresh: Bool = false) {
        evaluationsInFlight += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.evaluate(forceCalendarRefresh: forceCalendarRefresh)
            self.finishEvaluation()
        }
    }

    func finishEvaluation() {
        evaluationsInFlight -= 1
        guard evaluationsInFlight == 0 else { return }
        let waiters = settledWaiters
        settledWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func evaluate(forceCalendarRefresh: Bool = false) async {
        await refreshCalendarEventSnapshots(force: forceCalendarRefresh)

        // Off the main thread: reading bundle IDs can block on LaunchServices.
        let runningBundleIDs = await runningBundleIDsProvider()
        let frontmostBundleID = await frontmostBundleIDProvider()
        let now = Date()
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
        browserFirstTitleReadPending = false
        candidates.append(contentsOf: micInputCandidates(now: now, frontmostBundleID: frontmostBundleID))
        // A browser's first title read is still running: it decides whether
        // that browser is the call, so present nothing until it lands (it
        // re-runs this). Otherwise a calendar or runtime prompt could win
        // this pass over the call that is actually happening.
        if browserFirstTitleReadPending { return }

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

    func sortCandidates(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.candidate.startDate < rhs.candidate.startDate
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

    // MARK: Calendar snapshot cache

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
            MainActor.assumeIsolated {
                self?.calendarSnapshotsNeedRefresh = true
                self?.scheduleEvaluation(forceCalendarRefresh: true)
            }
        }
    }

    func currentOwnCaptureActivity() -> MeetingPromptOwnCaptureActivity {
        if let activity = ownCaptureActivity?(), activity != .none {
            return activity
        }
        return isOwnCaptureActive?() == true ? .unknown : .none
    }

    func recordSuppression(
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
