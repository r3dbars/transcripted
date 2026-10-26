import Foundation

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
    /// Bundle IDs of native conferencing apps confirmed to be playing audio
    /// output (MicActivityMonitor's output side). Catches the listen-only /
    /// hard-muted join where nothing holds the mic and the camera stays off.
    let audioOutputActiveBundleIDs: Set<String>
    let isOwnCaptureActive: Bool
    let isMicInputPromptEnabled: Bool

    init(
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?,
        recentNativeActivity: [MeetingPromptProvider: Date],
        runtimeSuppressedUntil: [MeetingPromptProvider: Date],
        micActiveBundleIDs: Set<String> = [],
        cameraInUse: Bool = false,
        audioOutputActiveBundleIDs: Set<String> = [],
        isOwnCaptureActive: Bool = false,
        isMicInputPromptEnabled: Bool = true
    ) {
        self.runningBundleIDs = runningBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.recentNativeActivity = recentNativeActivity
        self.runtimeSuppressedUntil = runtimeSuppressedUntil
        self.micActiveBundleIDs = micActiveBundleIDs
        self.cameraInUse = cameraInUse
        self.audioOutputActiveBundleIDs = audioOutputActiveBundleIDs
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
    /// Whether a browser (not a native app) is the call surface. A browser
    /// call named by its tab title keeps its real provider (a Teams tab is
    /// `.teams`), so the provider alone no longer says "browser"; candidates
    /// built without evidence keep the old `.googleMeet`-means-browser rule.
    var isBrowserCall: Bool {
        switch callEvidence {
        case .none, .nonCallSite:
            return provider == .googleMeet
        default:
            return callEvidence.isBrowserCall
        }
    }

    /// A browser call we could not name: the generic "Call detected in your
    /// browser" prompt. It could be Meet, Zoom web, or Teams web, so it must
    /// not borrow a calendar event's title for one of them.
    var isGenericBrowserCall: Bool {
        isBrowserCall && callEvidence != .tabTitle
    }

    /// Coarse learning bucket for `MeetingPromptLearnedBackoff`, or `nil` for
    /// calendar and runtime-app prompts, which keep their own backoff.
    var learnedBackoffKind: String? {
        guard reason.isAdHocCallSignal else { return nil }
        switch callEvidence {
        case .tabTitle:
            return MeetingPromptLearnedBackoff.verifiedBrowserKind
        case .callSite:
            return MeetingPromptLearnedBackoff.callSiteBrowserKind
        case .camera:
            return MeetingPromptLearnedBackoff.cameraBrowserKind
        case .micAndOutput, .micOnly:
            return MeetingPromptLearnedBackoff.unverifiedBrowserKind
        case .nonCallSite:
            return nil
        case .nativeApp:
            return MeetingPromptLearnedBackoff.nativeKind(for: provider)
        case .none:
            return provider == .googleMeet
                ? MeetingPromptLearnedBackoff.unverifiedBrowserKind
                : MeetingPromptLearnedBackoff.nativeKind(for: provider)
        }
    }

    var analyticsCalendarConfidence: String {
        switch reason {
        case .calendarPlusRuntimeMatch:
            return "linked_event_runtime_match"
        case .calendarNearby:
            return "linked_event"
        case .micInput, .cameraInput, .audioOutput, .runtimeOnly:
            return "none"
        }
    }

    var analyticsCallState: String {
        switch reason {
        case .micInput:
            return "mic_active"
        case .cameraInput:
            return "camera_active"
        case .audioOutput:
            return "output_active"
        case .calendarPlusRuntimeMatch, .runtimeOnly:
            return "app_active"
        case .calendarNearby:
            return "scheduled"
        }
    }

    var analyticsAppSignal: String {
        switch reason {
        case .micInput:
            return isBrowserCall ? "browser_mic" : "native_mic"
        case .cameraInput:
            return isBrowserCall ? "browser_camera" : "native_camera"
        case .audioOutput:
            // Output attribution is native-only by construction.
            return "native_output"
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
        case .idle, .ready, .transcribing, .error:
            return true
        case .loadingModels, .recording:
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
