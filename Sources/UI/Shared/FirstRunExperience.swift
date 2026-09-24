import Foundation

struct FirstRunModelCardState: Equatable {
    enum Tone: Equatable {
        case ready
        case working
        case failed
    }

    let title: String
    let detail: String
    let status: String
    let progress: Double?
    let tone: Tone
}

enum FirstRunOnboardingPolishContract {
    static let minimumHitTarget: Double = 44
    static let minimumCompactButtonHeight: Double = 40
    static let modelProgressLabelMinimumWidth: Double = 104
    static let selectedStateStrokeWidth: Double = 2
    static let bodyCopyLineLimit = 3
}

struct MenuBarPrimaryActionState: Equatable {
    let title: String
    let symbolName: String
    let isEnabled: Bool
    let subtitle: String

    init(
        title: String,
        symbolName: String,
        isEnabled: Bool,
        subtitle: String
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.subtitle = subtitle
    }
}

enum FirstRunCompletionPath: String, Equatable {
    case meetings
    case dictation
}

enum FirstRunExperience {
    private static let failedModelSetupDetail = "Local voice setup needs another try. Retry Download will try the same one-time local model setup again."

    static func modelPersistenceDetail(for model: TranscriptionModelChoice) -> String {
        "One-time \(model.approximateDownloadSize) download. The model is saved on this Mac outside the app bundle, so normal Transcripted updates do not download it again."
    }

    static func hasRequiredDictationSetup(
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        microphoneGranted && accessibilityGranted
    }

    static func hasRequiredMeetingSetup(
        microphoneGranted: Bool
    ) -> Bool {
        microphoneGranted
    }

    static func onboardingCompletionAnalyticsProperties(
        completionPath: FirstRunCompletionPath,
        systemAudioGranted: Bool,
        calendarGranted: Bool,
        meetingPromptsEnabled: Bool,
        firstDictationSaved: Bool,
        anonymousUsageEnabled: Bool,
        crashReportingEnabled: Bool,
        elapsedSeconds: Double?
    ) -> [String: String] {
        var properties: [String: String] = [
            "anonymous_usage_enabled": booleanString(anonymousUsageEnabled),
            "calendar_status": calendarStatus(
                calendarGranted: calendarGranted,
                meetingPromptsEnabled: meetingPromptsEnabled
            ),
            "completion_flow": completionPath.rawValue,
            "crash_reporting_enabled": booleanString(crashReportingEnabled),
            "first_dictation_saved": booleanString(firstDictationSaved),
            "meeting_recording_ready": booleanString(systemAudioGranted),
            "step_id": "done",
        ]

        if let elapsedSeconds {
            properties["flow_elapsed_bucket"] = AnalyticsReporter.durationBucket(seconds: elapsedSeconds)
        }

        return properties
    }

    private static func booleanString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func calendarStatus(
        calendarGranted: Bool,
        meetingPromptsEnabled: Bool
    ) -> String {
        guard meetingPromptsEnabled else { return "disabled" }
        return calendarGranted ? "granted" : "not_granted"
    }

    static func modelCard(
        for modelState: ParakeetModelState,
        model: TranscriptionModelChoice = .parakeetTDTv3
    ) -> FirstRunModelCardState {
        switch modelState {
        case .notLoaded:
            return FirstRunModelCardState(
                title: "\(model.title) starts on first use",
                detail: "The voice model isn't on this Mac yet. \(modelPersistenceDetail(for: model)) It downloads the first time you dictate, record, or import, or use Download Now to get it ready.",
                status: "On demand",
                progress: nil,
                tone: .working
            )
        case .downloading(let progress):
            let percentage = max(0, min(100, Int(progress * 100)))
            return FirstRunModelCardState(
                title: "Downloading \(model.title)",
                detail: "\(modelPersistenceDetail(for: model)) Downloading from huggingface.co. Keep Transcripted open; if the download fails, use Retry Download.",
                status: progress > 0 ? "\(percentage)% complete" : "Starting download",
                progress: max(0.12, min(0.84, 0.12 + progress * 0.72)),
                tone: .working
            )
        case .cached:
            return FirstRunModelCardState(
                title: "\(model.title) cached on device",
                detail: "Downloaded to this Mac. It loads into memory when you dictate, record, or import.",
                status: "Cached",
                progress: nil,
                tone: .ready
            )
        case .loading:
            return FirstRunModelCardState(
                title: "Loading \(model.title)",
                detail: "Transcripted has the model files on this Mac and is loading them into memory.",
                status: "Almost ready",
                progress: 0.92,
                tone: .working
            )
        case .ready:
            return FirstRunModelCardState(
                title: "\(model.title) ready on device",
                detail: "Saved on this Mac, so app updates don't download it again.",
                status: "Ready",
                // No progress: a finished model has nothing to report, and a
                // 1.0 bar kept the Settings card on screen forever.
                progress: nil,
                tone: .ready
            )
        case .failed:
            return FirstRunModelCardState(
                title: "Couldn't load \(model.title)",
                detail: failedModelSetupDetail,
                status: "Retry needed",
                progress: nil,
                tone: .failed
            )
        }
    }

    static func dictationAction(
        for modelState: ParakeetModelState,
        isDictating: Bool = false
    ) -> MenuBarPrimaryActionState {
        if isDictating {
            // Clicking "Start Dictation" mid-dictation did nothing; the
            // right-click menu already offered Stop here.
            return MenuBarPrimaryActionState(
                title: "Stop Dictation",
                symbolName: "stop.circle.fill",
                isEnabled: true,
                subtitle: ""
            )
        }

        // Steady states stay quiet: subtitles only carry setup/failure state,
        // so the everyday popover reads as clean single-line actions.
        let subtitle: String
        switch modelState {
        case .ready:
            subtitle = ""
        case .failed:
            subtitle = "Voice setup failed. Try again"
        case .notLoaded:
            subtitle = "Starts local voice setup on first use"
        case .downloading:
            subtitle = "Downloads once, then starts automatically"
        case .cached:
            subtitle = "Downloaded. Loads when you start"
        case .loading:
            subtitle = "Finishing local voice setup"
        }

        return MenuBarPrimaryActionState(
            title: "Start Dictation",
            symbolName: "mic.fill",
            isEnabled: true,
            subtitle: subtitle
        )
    }

    static func meetingAction(
        dictationReady: Bool,
        meetingsStatus: String,
        isRecording: Bool = false
    ) -> MenuBarPrimaryActionState {
        if isRecording {
            // The red row tone and elapsed timer already say "recording";
            // a subtitle would repeat them.
            return MenuBarPrimaryActionState(
                title: "Stop Meeting",
                symbolName: "stop.circle.fill",
                isEnabled: true,
                subtitle: ""
            )
        }

        let subtitle: String
        switch meetingsStatus {
        case "Ready":
            subtitle = ""
        case "Failed":
            subtitle = "Try again to reload meeting tools"
        default:
            subtitle = dictationReady
                ? "Meeting tools are still loading in the background"
                : "Starts local meeting setup on first use"
        }

        return MenuBarPrimaryActionState(
            title: "Record Meeting",
            symbolName: "record.circle.fill",
            isEnabled: true,
            subtitle: subtitle
        )
    }
}
