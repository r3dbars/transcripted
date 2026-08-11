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
        usableAudio: FailedMeetingUsableAudio = .unknown
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

            return HomeFailedMeetingInlinePresentation(
                statusText: "Retry ready",
                inlineDetail: "Saved audio is still here. Try again will transcribe it.",
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
}
