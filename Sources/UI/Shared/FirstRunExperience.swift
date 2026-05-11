import Foundation

enum FirstRunLocalModelState: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case cached
    case loading
    case ready
    case failed(String)
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

enum FirstRunOnboardingStep: Int, CaseIterable, Identifiable, Equatable {
    case hero
    case value
    case dictationSetup
    case testDictation
    case dictationResult
    case meetingsIntro
    case meetingSetup
    case agentPayoff

    var id: Int { rawValue }

    var progressTitle: String {
        switch self {
        case .hero:
            return "Welcome"
        case .value:
            return "What it does"
        case .dictationSetup:
            return "Dictation setup"
        case .testDictation:
            return "First dictation"
        case .dictationResult:
            return "Result"
        case .meetingsIntro:
            return "Meetings"
        case .meetingSetup:
            return "Meeting setup"
        case .agentPayoff:
            return "Agent"
        }
    }

    var screenTitle: String {
        switch self {
        case .hero:
            return "Speak and get clean local Markdown your agents can use."
        case .value:
            return "What Transcripted does"
        case .dictationSetup:
            return "Set up dictation"
        case .testDictation:
            return "Try your first dictation"
        case .dictationResult:
            return "Here's your first dictation"
        case .meetingsIntro:
            return "Transcripted also records meetings"
        case .meetingSetup:
            return "Set up meeting recording"
        case .agentPayoff:
            return "Use your audio context with an agent"
        }
    }
}

struct FirstRunOnboardingActionState: Equatable {
    let primaryTitle: String
    let secondaryTitle: String?
    let detail: String
    let isPrimaryEnabled: Bool
}

struct FirstRunOnboardingCopy {
    static let heroDetail = "Dictations and meetings become private Markdown files on this Mac, ready for search, notes, and agent context."
    static let valueFooter = "Your spoken context is saved as clean local Markdown."
    static let dictationPrompt = "Say one sentence you want saved for later."
    static let savedAsMarkdown = "Saved as local Markdown"
    static let agentDictationNote = "Your dictations can be searched later to understand what you're thinking and working on."
    static let meetingsDetail = "Record conversations into notes, then keep them alongside your dictations."
    static let agentDetail = "Dictations and meetings become local Markdown files your agent can search, summarize, and reference."
}

enum FirstRunExperience {
    static func modelPersistenceDetail(for model: TranscriptionModelChoice) -> String {
        "One-time \(model.approximateDownloadSize) download. The model is saved on this Mac outside the app bundle, so normal Transcripted updates do not download it again."
    }

    static func onboardingSteps() -> [FirstRunOnboardingStep] {
        FirstRunOnboardingStep.allCases
    }

    static func nextStep(after step: FirstRunOnboardingStep) -> FirstRunOnboardingStep? {
        FirstRunOnboardingStep(rawValue: step.rawValue + 1)
    }

    static func previousStep(before step: FirstRunOnboardingStep) -> FirstRunOnboardingStep? {
        FirstRunOnboardingStep(rawValue: step.rawValue - 1)
    }

    static func hasRequiredDictationSetup(
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        microphoneGranted && accessibilityGranted
    }

    static func onboardingAction(
        for step: FirstRunOnboardingStep,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        hasFirstDictation: Bool
    ) -> FirstRunOnboardingActionState {
        switch step {
        case .hero:
            return FirstRunOnboardingActionState(
                primaryTitle: "Continue",
                secondaryTitle: nil,
                detail: FirstRunOnboardingCopy.heroDetail,
                isPrimaryEnabled: true
            )
        case .value:
            return FirstRunOnboardingActionState(
                primaryTitle: "Continue",
                secondaryTitle: nil,
                detail: FirstRunOnboardingCopy.valueFooter,
                isPrimaryEnabled: true
            )
        case .dictationSetup:
            let ready = hasRequiredDictationSetup(
                microphoneGranted: microphoneGranted,
                accessibilityGranted: accessibilityGranted
            )
            return FirstRunOnboardingActionState(
                primaryTitle: ready ? "Continue" : "Turn on Microphone and Paste-back",
                secondaryTitle: nil,
                detail: ready
                    ? "Dictation is ready. Next, try one short capture."
                    : "Microphone lets Transcripted listen. Paste-back lets it put the result where you were typing.",
                isPrimaryEnabled: ready
            )
        case .testDictation:
            let ready = hasRequiredDictationSetup(
                microphoneGranted: microphoneGranted,
                accessibilityGranted: accessibilityGranted
            )
            return FirstRunOnboardingActionState(
                primaryTitle: "Start Dictation",
                secondaryTitle: nil,
                detail: ready
                    ? "Transcripted will listen, paste back, and save a local Markdown copy."
                    : "Finish dictation setup first so this test can paste back.",
                isPrimaryEnabled: ready
            )
        case .dictationResult:
            return FirstRunOnboardingActionState(
                primaryTitle: hasFirstDictation ? "Continue" : "Try Again",
                secondaryTitle: nil,
                detail: hasFirstDictation
                    ? "This is the first useful moment: spoken work became a saved dictation."
                    : "No dictation has been saved yet. Try again with one clear sentence.",
                isPrimaryEnabled: true
            )
        case .meetingsIntro:
            return FirstRunOnboardingActionState(
                primaryTitle: "Set up meetings",
                secondaryTitle: "Skip for now",
                detail: FirstRunOnboardingCopy.meetingsDetail,
                isPrimaryEnabled: true
            )
        case .meetingSetup:
            return FirstRunOnboardingActionState(
                primaryTitle: "Continue",
                secondaryTitle: "Skip for now",
                detail: "System Audio Recording captures the other side of calls. Calendar stays optional.",
                isPrimaryEnabled: true
            )
        case .agentPayoff:
            return FirstRunOnboardingActionState(
                primaryTitle: "Open Transcripted",
                secondaryTitle: nil,
                detail: FirstRunOnboardingCopy.agentDetail,
                isPrimaryEnabled: true
            )
        }
    }

    static func onboardingRequiredPermissions() -> [TranscriptedPermissionKind] {
        [.microphone, .accessibility]
    }

    static func onboardingOptionalPermissions() -> [TranscriptedPermissionKind] {
        [.systemAudioRecording, .calendar]
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
            return FirstRunModelCardState(
                title: "Downloading \(model.title)",
                detail: "\(modelPersistenceDetail(for: model)) Downloading from huggingface.co. Keep Transcripted open; if the download fails, use Retry Download.",
                status: progress > 0 ? "\(Int(progress * 100))% complete" : "Starting download",
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
        case .failed(let message):
            return FirstRunModelCardState(
                title: "Couldn't load \(model.title)",
                detail: "\(message) Retry Download will try the same one-time local model setup again.",
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
