import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

@available(macOS 14.0, *)
enum SpeakerReviewAnalytics {
    enum Surface: String {
        case sheet = "speaker_review_sheet"
        case home = "home"
    }

    enum Action: String {
        case shown
        case save
        case reviewLater = "review_later"
        case windowClosed = "window_closed"
        case keepAsYou = "keep_as_you"
    }

    enum Result: String {
        case prompted
        case namesSubmitted = "names_submitted"
        case skipped
        case dismissed
        case noChanges = "no_changes"
    }

    static func trackPrompted(request: SpeakerNamingRequest, surface: Surface = .sheet) {
        AnalyticsReporter.track(
            "meeting_speaker_review_prompted",
            properties: properties(
                request: request,
                surface: surface,
                action: .shown,
                result: .prompted
            )
        )
    }

    static func trackAction(
        request: SpeakerNamingRequest,
        action: Action,
        result: Result,
        updateCount: Int? = nil,
        surface: Surface = .sheet
    ) {
        AnalyticsReporter.track(
            "meeting_speaker_review_actioned",
            properties: properties(
                request: request,
                surface: surface,
                action: action,
                result: result,
                updateCount: updateCount
            )
        )
    }

    static func trackCompleted(
        request: SpeakerNamingRequest,
        result: Result,
        updateCount: Int? = nil,
        surface: Surface = .sheet
    ) {
        AnalyticsReporter.track(
            "meeting_speaker_review_completed",
            properties: properties(
                request: request,
                surface: surface,
                result: result,
                updateCount: updateCount
            )
        )
    }

    static func properties(
        request: SpeakerNamingRequest,
        surface: Surface,
        action: Action? = nil,
        result: Result? = nil,
        updateCount: Int? = nil,
        now: Date = Date()
    ) -> [String: String] {
        var properties: [String: String] = [
            "participant_count_bucket": AnalyticsReporter.countBucket(request.speakers.count),
            "unresolved_count_bucket": AnalyticsReporter.countBucket(request.speakers.filter(\.needsNaming).count),
            "review_reason": reviewReason(for: request).rawValue,
            "surface": surface.rawValue,
        ]

        if let action {
            properties["action"] = action.rawValue
        }
        if let result {
            properties["result"] = result.rawValue
        }
        if let updateCount {
            properties["update_count_bucket"] = AnalyticsReporter.countBucket(updateCount)
        }
        if let meetingAgeBucket = meetingAgeBucket(for: request.transcriptURL, now: now) {
            properties["meeting_age_bucket"] = meetingAgeBucket
        }

        return properties
    }

    enum ReviewReason: String {
        case needsNames = "needs_names"
        case confirmMatches = "confirm_matches"
        case mixed
        case unknown
    }

    private static func reviewReason(for request: SpeakerNamingRequest) -> ReviewReason {
        let needsNames = request.speakers.contains { $0.needsNaming }
        let needsConfirmation = request.speakers.contains { $0.needsConfirmation }
        switch (needsNames, needsConfirmation) {
        case (true, true):
            return .mixed
        case (true, false):
            return .needsNames
        case (false, true):
            return .confirmMatches
        case (false, false):
            return .unknown
        }
    }

    private static func meetingAgeBucket(for transcriptURL: URL, now: Date) -> String? {
        guard let values = try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else {
            return nil
        }

        return AnalyticsReporter.durationBucket(seconds: max(0, now.timeIntervalSince(date)))
    }
}
