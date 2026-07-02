import Foundation

enum FirstRunLocalModelState: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case cached
    case loading
    case ready
    case failed(String)

    /// Coarse analytics value; never includes the failure message.
    var analyticsValue: String {
        switch self {
        case .notLoaded:
            return "not_loaded"
        case .downloading:
            return "downloading"
        case .cached:
            return "cached"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }
}

/// One-line local-model status shown inside the onboarding flow so the first
/// dictation or meeting does not hit a surprise cold download.
struct FirstRunModelStatusLine: Equatable {
    enum Tone: Equatable {
        case ready
        case working
        case failed
    }

    let text: String
    let tone: Tone
    let showsRetry: Bool
}

struct FirstRunPrimaryActionState: Equatable {
    let title: String
    let detail: String
    let isEnabled: Bool
    let shouldStartDictation: Bool
}

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

    /// Status line for the model prefetch that onboarding starts in the
    /// background, shown on the try-dictation and final steps so the first
    /// real capture does not stall on a surprise download.
    static func onboardingModelStatusLine(for state: FirstRunLocalModelState) -> FirstRunModelStatusLine {
        switch state {
        case .notLoaded:
            return FirstRunModelStatusLine(
                text: "Getting the voice model ready in the background.",
                tone: .working,
                showsRetry: false
            )
        case .downloading(let progress):
            let percentage = max(0, min(100, Int(progress * 100)))
            return FirstRunModelStatusLine(
                text: percentage > 0
                    ? "Downloading the voice model — \(percentage)%."
                    : "Downloading the voice model.",
                tone: .working,
                showsRetry: false
            )
        case .cached:
            return FirstRunModelStatusLine(
                text: "Voice model downloaded. It loads when you start.",
                tone: .ready,
                showsRetry: false
            )
        case .loading:
            return FirstRunModelStatusLine(
                text: "Loading the voice model.",
                tone: .working,
                showsRetry: false
            )
        case .ready:
            return FirstRunModelStatusLine(
                text: "Voice model ready.",
                tone: .ready,
                showsRetry: false
            )
        case .failed:
            return FirstRunModelStatusLine(
                text: "The voice model download needs another try.",
                tone: .failed,
                showsRetry: true
            )
        }
    }

    static func onboardingCompletionAnalyticsProperties(
        completionPath: FirstRunCompletionPath,
        systemAudioGranted: Bool,
        calendarGranted: Bool,
        meetingPromptsEnabled: Bool,
        firstDictationSaved: Bool,
        anonymousUsageEnabled: Bool,
        crashReportingEnabled: Bool,
        modelState: String? = nil,
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

        if let modelState {
            properties["model_state"] = modelState
        }

        if let elapsedSeconds {
            properties["flow_elapsed_bucket"] = AnalyticsReporter.durationBucket(seconds: elapsedSeconds)
        }

        return properties
    }

    static func primaryAction(
        hasRequiredPermissions: Bool,
        hasPasteTarget: Bool,
        modelState: FirstRunLocalModelState
    ) -> FirstRunPrimaryActionState {
        guard hasRequiredPermissions else {
            return FirstRunPrimaryActionState(
                title: "Turn on the required permissions",
                detail: "Turn on Microphone and Accessibility first so dictation can start. System Audio Recording and Calendar can wait until later.",
                isEnabled: false,
                shouldStartDictation: false
            )
        }

        if hasPasteTarget {
            let detail: String
            switch modelState {
            case .ready:
                detail = "Start with a short dictation. Transcripted will paste it back into the app you were just using."
            case .failed:
                detail = "Start again to retry the local voice model. Transcripted will begin listening as soon as it's ready."
            case .notLoaded, .downloading, .cached, .loading:
                detail = "Start now. Transcripted will begin listening as soon as the local voice model finishes getting ready."
            }

            return FirstRunPrimaryActionState(
                title: "Start first dictation",
                detail: detail,
                isEnabled: true,
                shouldStartDictation: true
            )
        }

        let detail: String
        switch modelState {
        case .ready:
            detail = "Setup is done. Click back into any text field, then use Dictation from the Transcripted menu."
        case .failed:
            detail = "Setup is done, but the local voice model needs another try. Start Dictation from the menu to retry it."
        case .notLoaded, .downloading, .loading:
            detail = "Setup is done. Transcripted is still getting the local voice model ready in the background. When it's ready, click back into any text field and use Dictation from the menu."
        case .cached:
            detail = "Setup is done. The local voice model files are cached; dictation will load them into memory when you start."
        }

        return FirstRunPrimaryActionState(
            title: "Continue to Transcripted",
            detail: detail,
            isEnabled: true,
            shouldStartDictation: false
        )
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
        for modelState: FirstRunLocalModelState,
        model: TranscriptionModelChoice = .parakeetTDTv3
    ) -> FirstRunModelCardState {
        switch modelState {
        case .notLoaded:
            return FirstRunModelCardState(
                title: "\(model.title) starts on first use",
                detail: "Transcripted keeps the local voice model out of memory until you use it. \(modelPersistenceDetail(for: model)) Start dictation, a meeting, an import, or use Download now to set it up before you need it.",
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
                detail: "The model files are saved outside app updates. Transcripted will load them into memory when dictation, a meeting, or an import starts.",
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
                detail: "The model is cached outside app updates. Future Transcripted updates should stay around the app size, not the model size.",
                status: "Ready",
                progress: 1.0,
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

    static func dictationAction(for modelState: FirstRunLocalModelState) -> MenuBarPrimaryActionState {
        let subtitle: String
        switch modelState {
        case .ready:
            subtitle = "Paste spoken text anywhere"
        case .failed:
            subtitle = "Try again to retry local voice setup"
        case .notLoaded:
            subtitle = "Starts local voice setup on first use"
        case .downloading:
            subtitle = "Downloads once, then starts automatically"
        case .cached:
            subtitle = "Cached; loads when started"
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
            return MenuBarPrimaryActionState(
                title: "Stop Meeting",
                symbolName: "stop.circle.fill",
                isEnabled: true,
                subtitle: "Recording now"
            )
        }

        let subtitle: String
        switch meetingsStatus {
        case "Ready":
            subtitle = "Capture mic and system audio"
        case "Failed":
            subtitle = "Try again to reload meeting tools"
        default:
            subtitle = dictationReady
                ? "Meeting tools are still loading in the background"
                : "Starts local meeting setup on first use"
        }

        return MenuBarPrimaryActionState(
            title: "Start Meeting",
            symbolName: "record.circle.fill",
            isEnabled: true,
            subtitle: subtitle
        )
    }
}
