import Foundation

struct MeetingWarmupStatus: Equatable {
    let title: String
    let subtitle: String
    let detail: String
    let progress: Double
    let dictationStatus: String
    let meetingsStatus: String

    static let ready = MeetingWarmupStatus(
        title: "Transcripted is ready",
        subtitle: "Dictation and meetings are available",
        detail: "",
        progress: 1.0,
        dictationStatus: "Ready",
        meetingsStatus: "Ready"
    )

    static let dictationReadyMeetingsOnDemand = MeetingWarmupStatus(
        title: "Dictation is ready",
        subtitle: "Meetings load when started",
        detail: "",
        progress: 1.0,
        dictationStatus: "Ready",
        meetingsStatus: "On demand"
    )

    static let modelsOnDemand = MeetingWarmupStatus(
        title: "Transcripted is ready",
        subtitle: "Dictation and meetings load when started",
        detail: "The first use may download the local voice model once. The model is saved outside app updates after that.",
        progress: 1.0,
        dictationStatus: "On demand",
        meetingsStatus: "On demand"
    )
}

enum MeetingWarmupDictationState: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}

enum MeetingWarmupMeetingState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

enum MeetingWarmupStatusPolicy {
    static func status(
        dictationState: MeetingWarmupDictationState,
        meetingState: MeetingWarmupMeetingState,
        isMeetingWarmupInFlight: Bool,
        shouldSurfaceMeetingWarmupFailure: Bool
    ) -> MeetingWarmupStatus {
        if case .ready = dictationState, case .ready = meetingState {
            return .ready
        }

        switch dictationState {
        case .downloading(let progress):
            return MeetingWarmupStatus(
                title: "Getting Transcripted ready",
                subtitle: "Downloading local dictation model",
                detail: "One-time local model download. Keep Transcripted open; future app updates should reuse the cached model.",
                progress: max(0.08, min(0.62, 0.08 + progress * 0.54)),
                dictationStatus: progress > 0 ? "Downloading \(Int(progress * 100))%" : "Downloading",
                meetingsStatus: "Waiting"
            )
        case .loading:
            return MeetingWarmupStatus(
                title: "Getting Transcripted ready",
                subtitle: "Loading local dictation model",
                detail: "Transcripted has the model files and is loading dictation into memory.",
                progress: 0.68,
                dictationStatus: "Loading",
                meetingsStatus: "Waiting"
            )
        case .failed(let message):
            return MeetingWarmupStatus(
                title: "Couldn’t start dictation",
                subtitle: "The local dictation model failed to load",
                detail: "\(message) Try dictation again or use Retry Download in Models settings.",
                progress: 0,
                dictationStatus: "Failed",
                meetingsStatus: "Waiting"
            )
        case .ready:
            return meetingStatus(
                meetingState,
                isMeetingWarmupInFlight: isMeetingWarmupInFlight,
                shouldSurfaceMeetingWarmupFailure: shouldSurfaceMeetingWarmupFailure
            )
        case .notLoaded:
            return .modelsOnDemand
        }
    }

    private static func meetingStatus(
        _ meetingState: MeetingWarmupMeetingState,
        isMeetingWarmupInFlight: Bool,
        shouldSurfaceMeetingWarmupFailure: Bool
    ) -> MeetingWarmupStatus {
        switch meetingState {
        case .ready:
            return .ready
        case .failed(let message):
            guard shouldSurfaceMeetingWarmupFailure else {
                return .dictationReadyMeetingsOnDemand
            }
            return MeetingWarmupStatus(
                title: "Couldn’t load meetings",
                subtitle: "Meeting transcription models failed to load",
                detail: message,
                progress: 0.72,
                dictationStatus: "Ready",
                meetingsStatus: "Failed"
            )
        case .loading:
            guard isMeetingWarmupInFlight else {
                return .ready
            }
            return MeetingWarmupStatus(
                title: "Getting Transcripted ready",
                subtitle: "Loading meeting transcription",
                detail: "Dictation is ready. Transcripted is still warming up meeting transcription in the background.",
                progress: 0.86,
                dictationStatus: "Ready",
                meetingsStatus: "Loading"
            )
        case .notLoaded:
            guard isMeetingWarmupInFlight else {
                return .dictationReadyMeetingsOnDemand
            }
            return MeetingWarmupStatus(
                title: "Getting Transcripted ready",
                subtitle: "Preparing meeting transcription",
                detail: "Dictation is ready. Meeting transcription is still starting up.",
                progress: 0.76,
                dictationStatus: "Ready",
                meetingsStatus: "Starting"
            )
        }
    }
}
