import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

@available(macOS 14.0, *)
enum SpeakerReviewAnalytics {
    enum Surface: String {
        case sheet = "review_sheet"
        case home = "home"
        case people = "people"
    }

    enum Result: String {
        case shown
        case saved
        case noChanges = "no_changes"
        case reviewLater = "review_later"
        case windowClosed = "window_closed"
        case opened
    }

    enum SettingsAction: String {
        case needsAttention = "needs_attention"
        case rowMenu = "row_menu"
        case retranscribeBlocked = "retranscribe_blocked"
        case unknown
    }

    enum ReviewReason: String {
        case needsLabels = "needs_labels"
        case confirmSuggestions = "confirm_suggestions"
        case mixed
        case settingsQueue = "settings_queue"
        case unknown
    }

    static func trackPresented(request: SpeakerNamingRequest, surface: Surface = .sheet) {
        AnalyticsReporter.track(
            "speaker_review_presented",
            properties: lifecycleProperties(request: request, surface: surface, result: .shown)
        )
    }

    static func trackCompleted(
        request: SpeakerNamingRequest,
        updates: [SpeakerNameUpdate],
        surface: Surface = .sheet
    ) {
        AnalyticsReporter.track(
            "speaker_review_completed",
            properties: lifecycleProperties(
                request: request,
                surface: surface,
                result: updates.isEmpty ? .noChanges : .saved,
                updates: updates
            )
        )
    }

    static func trackDismissed(
        request: SpeakerNamingRequest,
        result: Result,
        surface: Surface = .sheet
    ) {
        AnalyticsReporter.track(
            "speaker_review_dismissed",
            properties: lifecycleProperties(request: request, surface: surface, result: result)
        )
    }

    static func trackSettingsAction(
        action: SettingsAction,
        surface: Surface,
        pendingCount: Int
    ) {
        AnalyticsReporter.track(
            "speaker_review_settings_action",
            properties: settingsActionProperties(
                action: action,
                surface: surface,
                pendingCount: pendingCount
            )
        )
    }

    static func lifecycleProperties(
        request: SpeakerNamingRequest,
        surface: Surface,
        result: Result,
        updates: [SpeakerNameUpdate] = []
    ) -> [String: String] {
        let localCount = request.speakers.filter { $0.channel == .mic }.count
        let remoteCount = request.speakers.filter { $0.channel == .system }.count
        let suggestionCount = request.speakers.filter { $0.needsConfirmation }.count
        let unknownCount = request.speakers.filter { $0.needsNaming }.count
        let updateCounts = updateBuckets(updates)

        return [
            "collapsed_local_to_you": updateCounts.collapsedLocalToYou ? "true" : "false",
            "confirmed_count_bucket": AnalyticsReporter.countBucket(updateCounts.confirmed),
            "discarded_count_bucket": AnalyticsReporter.countBucket(updateCounts.discarded),
            "has_local": localCount > 0 ? "true" : "false",
            "has_remote": remoteCount > 0 ? "true" : "false",
            "has_suggestions": suggestionCount > 0 ? "true" : "false",
            "local_count_bucket": AnalyticsReporter.countBucket(localCount),
            "participant_count_bucket": AnalyticsReporter.countBucket(request.speakers.count),
            "remote_count_bucket": AnalyticsReporter.countBucket(remoteCount),
            "result": result.rawValue,
            "review_reason": reviewReason(for: request).rawValue,
            "suggestion_count_bucket": AnalyticsReporter.countBucket(suggestionCount),
            "surface": surface.rawValue,
            "typed_count_bucket": AnalyticsReporter.countBucket(updateCounts.typed),
            "unknown_count_bucket": AnalyticsReporter.countBucket(unknownCount),
        ]
    }

    static func settingsActionProperties(
        action: SettingsAction,
        surface: Surface,
        pendingCount: Int
    ) -> [String: String] {
        [
            "action": action.rawValue,
            "pending_count_bucket": AnalyticsReporter.countBucket(pendingCount),
            "result": Result.opened.rawValue,
            "review_reason": ReviewReason.settingsQueue.rawValue,
            "surface": surface.rawValue,
        ]
    }

    private static func reviewReason(for request: SpeakerNamingRequest) -> ReviewReason {
        let needsLabels = request.speakers.contains { $0.needsNaming }
        let needsConfirmation = request.speakers.contains { $0.needsConfirmation }
        switch (needsLabels, needsConfirmation) {
        case (true, true):
            return .mixed
        case (true, false):
            return .needsLabels
        case (false, true):
            return .confirmSuggestions
        case (false, false):
            return .unknown
        }
    }

    private struct UpdateBuckets {
        var collapsedLocalToYou = false
        var confirmed = 0
        var typed = 0
        var discarded = 0
    }

    private static func updateBuckets(_ updates: [SpeakerNameUpdate]) -> UpdateBuckets {
        var buckets = UpdateBuckets()
        for update in updates {
            switch update.action {
            case .collapsedToMe:
                buckets.collapsedLocalToYou = true
            case .confirmed:
                buckets.confirmed += 1
            case .named, .corrected, .merged:
                buckets.typed += 1
            case .discardedFromDatabase:
                buckets.discarded += 1
            }
        }
        return buckets
    }
}
