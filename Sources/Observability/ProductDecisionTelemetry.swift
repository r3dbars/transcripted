import Foundation

enum ProductDecisionTelemetry {
    enum MeetingPromptDecision: String {
        case recordNow = "record_now"
        case remindLater = "remind_later"
        case notNow = "not_now"
        case dismiss
        case ignore
        case unknown
    }

    enum MeetingPromptOutcome: String {
        case recordingStarted = "recording_started"
        case transcriptSaved = "transcript_saved"
        case suppressed
        case noAction = "no_action"
        case failed
        case cancelled
        case unknown
    }

    enum CaptureKind: String {
        case dictation
        case meeting
        case importedAudio = "imported_audio"
        case savedAudio = "saved_audio"
        case unknown
    }

    enum RetryAction: String {
        case retry
        case retranscribe
        case openAudio = "open_audio"
        case delete
        case report
        case none
    }

    enum RetryOutcome: String {
        case recovered
        case failed
        case blocked
        case cancelled
        case unknown
    }

    enum SummaryAction: String {
        case regenerate
        case open
        case copy
        case run
        case preview
    }

    enum SummaryResult: String {
        case started
        case success
        case failed
        case blocked
        case cancelled
        case unknown
    }

    enum SpeakerReviewAction: String {
        case accepted
        case rejected
        case corrected
        case skipped
    }

    static func trackMeetingPromptDecision(
        baseProperties: [String: String],
        decision: MeetingPromptDecision,
        elapsedBucket: String = "unknown"
    ) {
        let properties = meetingPromptDecisionProperties(
            baseProperties: baseProperties,
            decision: decision,
            elapsedBucket: elapsedBucket
        )
        AnalyticsReporter.track("meeting_prompt_decision_made", properties: properties)
    }

    static func trackMeetingPromptFollowupOutcome(
        baseProperties: [String: String],
        decision: MeetingPromptDecision,
        outcome: MeetingPromptOutcome,
        elapsedBucket: String = "unknown"
    ) {
        var properties = meetingPromptDecisionProperties(
            baseProperties: baseProperties,
            decision: decision,
            elapsedBucket: elapsedBucket
        )
        properties["outcome"] = outcome.rawValue
        AnalyticsReporter.track("meeting_prompt_followup_outcome", properties: properties)
    }

    static func trackFailedCaptureRetryDecision(
        captureKind: CaptureKind,
        failureKind: String,
        retryAction: RetryAction,
        elapsedBucket: String = "unknown"
    ) {
        AnalyticsReporter.track(
            "failed_capture_retry_decision",
            properties: failedCaptureRetryProperties(
                captureKind: captureKind,
                failureKind: failureKind,
                retryAction: retryAction,
                elapsedBucket: elapsedBucket
            )
        )
    }

    static func trackFailedCaptureRetryOutcome(
        captureKind: CaptureKind,
        failureKind: String,
        retryAction: RetryAction,
        outcome: RetryOutcome,
        elapsedBucket: String = "unknown"
    ) {
        var properties = failedCaptureRetryProperties(
            captureKind: captureKind,
            failureKind: failureKind,
            retryAction: retryAction,
            elapsedBucket: elapsedBucket
        )
        properties["outcome"] = outcome.rawValue
        AnalyticsReporter.track("failed_capture_retry_outcome", properties: properties)
    }

    static func trackLocalSummaryFeedback(
        action: SummaryAction,
        result: SummaryResult,
        providerFamily: String,
        chunkCount: Int? = nil,
        elapsedBucket: String = "unknown"
    ) {
        AnalyticsReporter.track(
            "local_summary_feedback_given",
            properties: localSummaryProperties(
                action: action,
                result: result,
                providerFamily: providerFamily,
                chunkCount: chunkCount,
                elapsedBucket: elapsedBucket
            )
        )
    }

    static func trackLocalSummaryUsedAfterGeneration(
        action: SummaryAction,
        result: SummaryResult,
        providerFamily: String,
        chunkCount: Int? = nil,
        elapsedBucket: String = "unknown"
    ) {
        AnalyticsReporter.track(
            "local_summary_used_after_generation",
            properties: localSummaryProperties(
                action: action,
                result: result,
                providerFamily: providerFamily,
                chunkCount: chunkCount,
                elapsedBucket: elapsedBucket
            )
        )
    }

    static func trackSpeakerNameCorrected(
        action: SpeakerReviewAction,
        reviewReason: String,
        itemCount: Int,
        suggestionConfidenceBucket: String
    ) {
        AnalyticsReporter.track(
            "speaker_name_corrected",
            properties: speakerReviewProperties(
                action: action,
                reviewReason: reviewReason,
                itemCount: itemCount,
                suggestionConfidenceBucket: suggestionConfidenceBucket
            )
        )
    }

    static func trackSpeakerSuggestionAcceptedOrRejected(
        action: SpeakerReviewAction,
        reviewReason: String,
        itemCount: Int,
        suggestionConfidenceBucket: String
    ) {
        AnalyticsReporter.track(
            "speaker_suggestion_accepted_or_rejected",
            properties: speakerReviewProperties(
                action: action,
                reviewReason: reviewReason,
                itemCount: itemCount,
                suggestionConfidenceBucket: suggestionConfidenceBucket
            )
        )
    }

    static func trackArtifactReusedAfterSave(
        artifactKind: ActivationTelemetry.ArtifactKind,
        actionKind: ActivationTelemetry.ArtifactActionKind,
        surface: ActivationTelemetry.Surface,
        artifactDate: Date?,
        now: Date = Date()
    ) {
        guard let artifactDate else { return }
        guard let returnWindowBucket = ActivationTelemetry.returnWindowBucket(since: artifactDate, now: now) else {
            return
        }

        AnalyticsReporter.track(
            "artifact_reused_after_save",
            properties: [
                "action_kind": actionKind.rawValue,
                "artifact_kind": artifactKind.rawValue,
                "result": "success",
                "return_window_bucket": returnWindowBucket,
                "surface": surface.rawValue,
            ]
        )
    }

    static func itemCountBucket(_ count: Int) -> String {
        AnalyticsReporter.countBucket(count)
    }

    static func suggestionConfidenceBucket(similarity: Double?) -> String {
        guard let similarity else { return "unknown" }
        switch similarity {
        case ..<0.70:
            return "low"
        case ..<0.85:
            return "medium"
        case ..<0.92:
            return "high"
        default:
            return "very_high"
        }
    }

    private static func meetingPromptDecisionProperties(
        baseProperties: [String: String],
        decision: MeetingPromptDecision,
        elapsedBucket: String
    ) -> [String: String] {
        var properties = baseProperties
        properties["decision"] = decision.rawValue
        properties["elapsed_bucket"] = elapsedBucket
        properties["prompt_origin"] = promptOrigin(from: baseProperties)
        return properties
    }

    private static func promptOrigin(from properties: [String: String]) -> String {
        if properties["source"] == "calendar_event" {
            return "calendar"
        }
        if properties["app_signal"]?.contains("browser") == true {
            return "browser"
        }
        if properties["call_state"] == "mic_active" {
            return "mic"
        }
        return "unknown"
    }

    private static func failedCaptureRetryProperties(
        captureKind: CaptureKind,
        failureKind: String,
        retryAction: RetryAction,
        elapsedBucket: String
    ) -> [String: String] {
        [
            "capture_kind": captureKind.rawValue,
            "elapsed_bucket": elapsedBucket,
            "failure_kind": failureKind,
            "retry_action": retryAction.rawValue,
        ]
    }

    private static func localSummaryProperties(
        action: SummaryAction,
        result: SummaryResult,
        providerFamily: String,
        chunkCount: Int?,
        elapsedBucket: String
    ) -> [String: String] {
        var properties = [
            "elapsed_bucket": elapsedBucket,
            "provider_family": providerFamily,
            "result": result.rawValue,
            "summary_action": action.rawValue,
        ]
        if let chunkCount {
            properties["chunk_count_bucket"] = AnalyticsReporter.countBucket(chunkCount)
        }
        return properties
    }

    private static func speakerReviewProperties(
        action: SpeakerReviewAction,
        reviewReason: String,
        itemCount: Int,
        suggestionConfidenceBucket: String
    ) -> [String: String] {
        [
            "action": action.rawValue,
            "item_count_bucket": itemCountBucket(itemCount),
            "review_reason": reviewReason,
            "suggestion_confidence_bucket": suggestionConfidenceBucket,
        ]
    }
}
