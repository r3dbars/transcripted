import Foundation

enum FirstRunLocalModelState: Equatable {
    case notLoaded
    case downloading(progress: Double)
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
    let isEnabled: Bool
    let subtitle: String
}

enum FirstRunExperience {
    static func primaryAction(
        hasRequiredPermissions: Bool,
        hasPasteTarget: Bool,
        modelState: FirstRunLocalModelState
    ) -> FirstRunPrimaryActionState {
        guard hasRequiredPermissions else {
            return FirstRunPrimaryActionState(
                title: "Turn on the required permissions",
                detail: "Turn on Microphone, Accessibility, and System Audio Recording first so dictation and meetings are ready right away.",
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
            case .notLoaded, .downloading, .loading:
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
        }

        return FirstRunPrimaryActionState(
            title: "Continue to Transcripted",
            detail: detail,
            isEnabled: true,
            shouldStartDictation: false
        )
    }

    static func modelCard(for modelState: FirstRunLocalModelState) -> FirstRunModelCardState {
        switch modelState {
        case .notLoaded:
            return FirstRunModelCardState(
                title: "Getting local dictation ready",
                detail: "Transcripted starts the on-device voice model the first time you use it.",
                status: "Starting",
                progress: 0.06,
                tone: .working
            )
        case .downloading(let progress):
            return FirstRunModelCardState(
                title: "Downloading local dictation",
                detail: "This one-time download stays on this Mac so dictation can run locally.",
                status: "\(Int(progress * 100))% complete",
                progress: max(0.12, min(0.84, 0.12 + progress * 0.72)),
                tone: .working
            )
        case .loading:
            return FirstRunModelCardState(
                title: "Finishing local dictation setup",
                detail: "Transcripted has the files and is loading them into memory.",
                status: "Almost ready",
                progress: 0.92,
                tone: .working
            )
        case .ready:
            return FirstRunModelCardState(
                title: "Local dictation is ready",
                detail: "Your first dictation can start immediately.",
                status: "Ready",
                progress: 1.0,
                tone: .ready
            )
        case .failed(let message):
            return FirstRunModelCardState(
                title: "Couldn't load local dictation",
                detail: message,
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
        case .loading:
            subtitle = "Finishing local voice setup"
        }

        return MenuBarPrimaryActionState(
            isEnabled: true,
            subtitle: subtitle
        )
    }

    static func meetingAction(dictationReady: Bool, meetingsStatus: String) -> MenuBarPrimaryActionState {
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
            isEnabled: true,
            subtitle: subtitle
        )
    }
}
