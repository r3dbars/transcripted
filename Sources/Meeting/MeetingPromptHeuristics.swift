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

    /// Attributes a "camera is on, nothing is holding the mic" signal to a meeting
    /// provider using only the *frontmost* app, or `nil` if the frontmost app is
    /// not a known call surface.
    ///
    /// The camera boolean carries no process attribution (CoreMediaIO exposes no
    /// per-process camera API), so this is the conservative sanity gate that
    /// distinguishes a camera-on call from a Photo Booth selfie: we attribute a
    /// camera-only signal only when the user is actually looking at a browser or a
    /// native conferencing app. A frontmost browser → `.googleMeet` (the generic
    /// browser call); a frontmost native conferencing app → that provider; a
    /// frontmost Photo Booth / QuickTime / anything else → `nil` (no prompt).
    static func cameraCallProvider(forFrontmostBundleID frontmostBundleID: String?) -> MeetingPromptProvider? {
        guard let frontmostBundleID else { return nil }
        if let native = allCases.first(where: { provider in
            provider.activeBundleIdentifiers.contains { frontmostBundleID.matchesBundleFamily($0) }
        }) {
            return native
        }
        if isBrowserBundleID(frontmostBundleID) {
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
    // A camera turned on while a call app was frontmost and nothing was holding
    // the mic (e.g. a camera-on, mic-muted Meet join). Same prompt + backoff as
    // `.micInput`; distinct only so analytics can tell the camera-led signal
    // apart. When the mic is also active the mic candidate wins, so this reason
    // marks the camera-only case.
    case cameraInput = "camera_input"

    /// Mic- or camera-driven ad-hoc call detection (as opposed to calendar- or
    /// runtime-app-driven). Both feed the same prompt and the same browser-call
    /// vs calendar preference logic.
    var isAdHocCallSignal: Bool {
        self == .micInput || self == .cameraInput
    }
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

enum MeetingPromptSuppressionReason: String, Equatable {
    case ownCaptureActive = "own_capture_active"
    case micInputDisabled = "mic_input_disabled"
    case runtimeSuppressed = "runtime_suppressed"
    case snoozedCandidate = "snoozed_candidate"
    case pendingCandidate = "pending_candidate"
    case presentationBlocked = "presentation_blocked"
}

enum MeetingPromptOwnCaptureActivity: String, Equatable {
    case none
    case meetingRecording = "meeting_recording"
    case dictation
    case unknown
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
    let micActiveBundleIDs: Set<String>
    /// Whether a camera has been confirmed in use (CameraActivityMonitor). Boolean
    /// only — CoreMediaIO gives no process attribution — so it is attributed to a
    /// provider via the frontmost app when nothing holds the mic.
    let cameraInUse: Bool
    let isOwnCaptureActive: Bool
    let isMicInputPromptEnabled: Bool

    init(
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?,
        recentNativeActivity: [MeetingPromptProvider: Date],
        runtimeSuppressedUntil: [MeetingPromptProvider: Date],
        micActiveBundleIDs: Set<String> = [],
        cameraInUse: Bool = false,
        isOwnCaptureActive: Bool = false,
        isMicInputPromptEnabled: Bool = true
    ) {
        self.runningBundleIDs = runningBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.recentNativeActivity = recentNativeActivity
        self.runtimeSuppressedUntil = runtimeSuppressedUntil
        self.micActiveBundleIDs = micActiveBundleIDs
        self.cameraInUse = cameraInUse
        self.isOwnCaptureActive = isOwnCaptureActive
        self.isMicInputPromptEnabled = isMicInputPromptEnabled
    }

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

@available(macOS 14.0, *)
struct MeetingPromptSuppression: Equatable {
    let candidate: MeetingPromptDetector.Candidate
    let reason: MeetingPromptSuppressionReason
    let cooldownReason: String?
    let captureActivity: MeetingPromptOwnCaptureActivity?
}

@available(macOS 14.0, *)
extension MeetingPromptDetector.Candidate {
    var analyticsCalendarConfidence: String {
        switch reason {
        case .calendarPlusRuntimeMatch:
            return "linked_event_runtime_match"
        case .calendarNearby:
            return "linked_event"
        case .micInput, .cameraInput, .runtimeOnly:
            return "none"
        }
    }

    var analyticsCallState: String {
        switch reason {
        case .micInput:
            return "mic_active"
        case .cameraInput:
            return "camera_active"
        case .calendarPlusRuntimeMatch, .runtimeOnly:
            return "app_active"
        case .calendarNearby:
            return "scheduled"
        }
    }

    var analyticsAppSignal: String {
        switch reason {
        case .micInput:
            return provider == .googleMeet ? "browser_mic" : "native_mic"
        case .cameraInput:
            return provider == .googleMeet ? "browser_camera" : "native_camera"
        case .runtimeOnly:
            return "native_runtime"
        case .calendarPlusRuntimeMatch:
            return provider.browserHosted ? "browser_runtime" : "native_runtime"
        case .calendarNearby:
            return "none"
        }
    }
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
    case ownCaptureActive = "own_capture_active"
    case micInputDisabled = "mic_input_disabled"
    case runtimeSuppressed = "runtime_suppressed"
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
        let micSuppression = micInputSuppression(from: runtimeSnapshot, now: now)
        candidates.append(contentsOf: micInputCandidates(from: runtimeSnapshot, now: now))

        let sortedCandidates = candidates.sorted(by: sortCandidates)
        guard let match = preferredCandidate(
            from: sortedCandidates,
            snoozedUntil: snoozedUntil,
            pendingUntil: pendingUntil,
            now: now
        ) else {
            return MeetingPromptSyntheticEvaluation(
                candidate: nil,
                suppressionReason: micSuppression ?? .noCandidate
            )
        }

        if let until = snoozedUntil[match.candidate.id], until > now {
            return MeetingPromptSyntheticEvaluation(candidate: nil, suppressionReason: .snoozedCandidate)
        }

        if let until = pendingUntil[match.candidate.id], until > now {
            return MeetingPromptSyntheticEvaluation(candidate: nil, suppressionReason: .pendingCandidate)
        }

        return MeetingPromptSyntheticEvaluation(candidate: match.candidate, suppressionReason: nil)
    }

    static func micInputCandidates(
        from snapshot: MeetingPromptRuntimeSnapshot,
        now: Date
    ) -> [MeetingPromptScoredCandidate] {
        guard micInputSuppression(from: snapshot, now: now) == nil else { return [] }

        return callSignals(from: snapshot).compactMap { signal in
            if let suppressedUntil = snapshot.runtimeSuppressedUntil[signal.provider], suppressedUntil > now {
                return nil
            }
            return micInputCandidate(for: signal.provider, reason: signal.reason, now: now)
        }
    }

    /// The ad-hoc call signals from this snapshot, de-duped to one entry per
    /// provider so mic-and-camera on the same call surface a single prompt. Mic
    /// activity is the primary signal (`.micInput`). The camera is only a
    /// *standalone* signal when **nothing holds the mic** — the camera-on,
    /// mic-muted join — because the camera boolean has no process attribution, so
    /// attributing it to the frontmost app while the mic already identifies a call
    /// could point at a different (wrong) app or double-prompt. When the mic is
    /// active it already names the call and the camera adds nothing.
    static func callSignals(
        from snapshot: MeetingPromptRuntimeSnapshot
    ) -> [(provider: MeetingPromptProvider, reason: MeetingPromptReason)] {
        let micProviders = micInputProviders(from: snapshot)
        if !micProviders.isEmpty {
            return micProviders.map { ($0, .micInput) }
        }

        if snapshot.cameraInUse,
           let provider = MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID: snapshot.frontmostBundleID) {
            return [(provider, .cameraInput)]
        }

        return []
    }

    private static func micInputProviders(
        from snapshot: MeetingPromptRuntimeSnapshot
    ) -> [MeetingPromptProvider] {
        Set(snapshot.micActiveBundleIDs.compactMap(MeetingPromptProvider.micInputProvider(forBundleID:)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private static func micInputSuppression(
        from snapshot: MeetingPromptRuntimeSnapshot,
        now: Date
    ) -> MeetingPromptSyntheticSuppressionReason? {
        let providers = callSignals(from: snapshot).map(\.provider)
        guard !providers.isEmpty else { return nil }

        if !snapshot.isMicInputPromptEnabled {
            return .micInputDisabled
        }
        if snapshot.isOwnCaptureActive {
            return .ownCaptureActive
        }
        if providers.allSatisfy({ provider in
            (snapshot.runtimeSuppressedUntil[provider] ?? .distantPast) > now
        }) {
            return .runtimeSuppressed
        }

        return nil
    }

    private static func micInputCandidate(
        for provider: MeetingPromptProvider,
        reason: MeetingPromptReason,
        now: Date
    ) -> MeetingPromptScoredCandidate {
        let title = provider == .googleMeet
            ? "Call detected in your browser"
            : "\(provider.displayName) call detected"
        let presentation = MeetingPromptHeuristics.micInputPresentation(title: title)

        return MeetingPromptScoredCandidate(
            candidate: MeetingPromptDetector.Candidate(
                id: "mic:\(provider.rawValue)",
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

    private static func preferredCandidate(
        from sortedCandidates: [MeetingPromptScoredCandidate],
        snoozedUntil: [String: Date],
        pendingUntil: [String: Date],
        now: Date
    ) -> MeetingPromptScoredCandidate? {
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
                hasActiveCooldown(
                    for: $0.candidate.id,
                    snoozedUntil: snoozedUntil,
                    pendingUntil: pendingUntil,
                    now: now
                )
        } ?? first
    }

    private static func hasActiveCooldown(
        for candidateID: String,
        snoozedUntil: [String: Date],
        pendingUntil: [String: Date],
        now: Date
    ) -> Bool {
        if let until = pendingUntil[candidateID], until > now {
            return true
        }
        if let until = snoozedUntil[candidateID], until > now {
            return true
        }
        return false
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
