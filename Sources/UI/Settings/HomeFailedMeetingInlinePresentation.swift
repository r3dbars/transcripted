import Foundation

struct HomeFailedMeetingInlinePresentation: Equatable {
    let statusText: String
    let inlineDetail: String?
    let canShowRetryAction: Bool

    static func make(
        isRetryable: Bool,
        isRetrying: Bool,
        hasAudioFiles: Bool,
        detail: String
    ) -> HomeFailedMeetingInlinePresentation {
        if isRetrying {
            return HomeFailedMeetingInlinePresentation(
                statusText: "Retrying",
                inlineDetail: nil,
                canShowRetryAction: true
            )
        }

        if isRetryable, hasAudioFiles {
            return HomeFailedMeetingInlinePresentation(
                statusText: "Needs retry",
                inlineDetail: nil,
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
