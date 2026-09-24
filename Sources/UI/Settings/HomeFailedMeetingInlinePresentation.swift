import Foundation

struct HomeFailedMeetingInlinePresentation: Equatable {
    let statusText: String
    let inlineDetail: String?
    let canShowRetryAction: Bool

    static func make(
        isRetryable: Bool,
        isRetrying: Bool,
        hasAudioFiles: Bool,
        detail: String,
        usableAudio: FailedMeetingUsableAudio = .unknown,
        failureKind: MeetingFailureKind? = nil
    ) -> HomeFailedMeetingInlinePresentation {
        if isRetrying {
            return HomeFailedMeetingInlinePresentation(
                statusText: "Retrying",
                inlineDetail: nil,
                canShowRetryAction: true
            )
        }

        if isRetryable, hasAudioFiles {
            // Probed and silent is the one case where offering retry would only
            // waste the user's time reproducing the original failure. While the
            // probe is still `.unknown` we stay optimistic and keep the action
            // visible rather than letting it pop in a moment later.
            if usableAudio == .absent {
                return HomeFailedMeetingInlinePresentation(
                    statusText: "No sound saved",
                    inlineDetail: "The saved audio is silent, so there is nothing to transcribe.",
                    canShowRetryAction: false
                )
            }

            // Say why it failed when that changes what to do first; a bare
            // "Retry ready" sends people straight back into the same wall.
            return HomeFailedMeetingInlinePresentation(
                statusText: "Retry ready",
                inlineDetail: failureKind.flatMap(retryReason(for:))
                    ?? "Saved audio is still here. Try again will transcribe it.",
                canShowRetryAction: true
            )
        }

        if isRetryable {
            return HomeFailedMeetingInlinePresentation(
                statusText: "Audio missing",
                inlineDetail: "Saved audio is missing, so this meeting cannot be retried.",
                canShowRetryAction: false
            )
        }

        return HomeFailedMeetingInlinePresentation(
            statusText: "Needs attention",
            inlineDetail: detail,
            canShowRetryAction: false
        )
    }

    /// Home's header line for the failed-meetings pile. A speaker-name failure
    /// keeps the saved transcript, so a pile of only those must not read as
    /// lost meetings.
    static func attentionSummary(
        failureKinds: [MeetingFailureKind]
    ) -> (title: String, detail: String, onlySpeakerNamesMissing: Bool) {
        let count = failureKinds.count
        let onlySpeakerNamesMissing = !failureKinds.isEmpty && failureKinds.allSatisfy {
            $0 == .speakerNameFinalizationFailed || $0 == .speakerFinalizationFailed
        }
        if onlySpeakerNamesMissing {
            return (
                title: count == 1 ? "1 meeting needs speaker names" : "\(count) meetings need speaker names",
                detail: "The transcripts are saved. Try again to name the speakers.",
                onlySpeakerNamesMissing: true
            )
        }
        return (
            title: count == 1 ? "1 meeting failed" : "\(count) meetings failed",
            detail: count == 1
                ? "Saved audio is waiting for review or retry."
                : "\(count) saved recordings are waiting for review or retry.",
            onlySpeakerNamesMissing: false
        )
    }

    /// The one-line reason shown on a retry-ready row, in Home's own words
    /// (the long failure copy is written for the pill and points at the Meetings page).
    /// Nil keeps the generic saved-audio line: for these kinds, Try again is
    /// the whole answer.
    static func retryReason(for failureKind: MeetingFailureKind) -> String? {
        switch failureKind {
        case .systemAudioPermission:
            return "Turn on System Audio Recording in System Settings first, then try again."
        case .systemAudioPermissionCheckInconclusive:
            return "Couldn't confirm call-audio access. Check System Audio Recording in System Settings, then try again."
        case .microphonePermission:
            return "Turn on Microphone access in System Settings first, then try again."
        case .languageNeedsWhisperModel:
            return "This meeting's language needs a Whisper model. Pick one under Model in Settings, then try again."
        case .modelDownloadFailed, .modelNotLoaded:
            return "The speech model wasn't ready. Try again once it has loaded."
        case .microphoneAudioUnusable:
            return "The mic had no usable signal. Try again to transcribe the call audio."
        case .audioDeviceUnavailable:
            return "The mic disconnected mid-meeting. Try again to transcribe what was saved."
        case .stopTimeout:
            return "The recording didn't close cleanly. Try again to transcribe what was saved."
        case .savedBeforeQuit:
            return "Saved when Transcripted quit. Try again to finish the transcript."
        case .speakerNameFinalizationFailed, .speakerFinalizationFailed:
            return "The transcript is saved, but the speaker names didn't save. Try again to rebuild it and name them."
        case .saveFailed:
            return "The transcript file couldn't be written. Check free disk space, then try again."
        default:
            return nil
        }
    }
}
