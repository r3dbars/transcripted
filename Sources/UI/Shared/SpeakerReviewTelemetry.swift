import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SpeakerReviewTelemetry {
    static func trackPrompted(request: SpeakerNamingRequest, surface: Surface = .postMeetingSheet) {
        AnalyticsReporter.track(
            "meeting_speaker_review_prompted",
            properties: properties(
                request: request,
                result: .shown,
                surface: surface
            )
        )
    }

    static func trackCompleted(
        request: SpeakerNamingRequest,
        updates: [SpeakerNameUpdate],
        explicitResult: Result? = nil,
        surface: Surface = .postMeetingSheet
    ) {
        AnalyticsReporter.track(
            "meeting_speaker_review_completed",
            properties: properties(
                request: request,
                result: explicitResult ?? result(for: updates),
                surface: surface
            )
        )
    }

    static func properties(
        request: SpeakerNamingRequest,
        result: Result,
        surface: Surface
    ) -> [String: String] {
        [
            "participant_count_bucket": AnalyticsReporter.countBucket(request.speakers.count),
            "review_reason": reviewReason(for: request).rawValue,
            "result": result.rawValue,
            "surface": surface.rawValue,
        ]
    }

    static func reviewReason(for request: SpeakerNamingRequest) -> ReviewReason {
        let speakers = request.speakers
        guard !speakers.isEmpty else { return .unknown }

        let hasNaming = speakers.contains { $0.needsNaming }
        let hasConfirmation = speakers.contains { $0.needsConfirmation }

        switch (hasNaming, hasConfirmation) {
        case (true, true):
            return .mixed
        case (true, false):
            return .namingRequired
        case (false, true):
            return .confirmationRequired
        case (false, false):
            return .unknown
        }
    }

    static func result(for updates: [SpeakerNameUpdate]) -> Result {
        guard !updates.isEmpty else { return .reviewLater }
        if updates.allSatisfy({ update in
            if case .collapsedToMe = update.action { return true }
            return false
        }) {
            return .collapsedToMe
        }
        if updates.allSatisfy({ update in
            if case .discardedFromDatabase = update.action { return true }
            return false
        }) {
            return .discarded
        }
        return .saved
    }

    enum Surface: String {
        case postMeetingSheet = "post_meeting_sheet"
    }

    enum ReviewReason: String {
        case namingRequired = "naming_required"
        case confirmationRequired = "confirmation_required"
        case mixed
        case unknown
    }

    enum Result: String {
        case shown
        case saved
        case reviewLater = "review_later"
        case closed
        case collapsedToMe = "collapsed_to_me"
        case discarded
    }
}
