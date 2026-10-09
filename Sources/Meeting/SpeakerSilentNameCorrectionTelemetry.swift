import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// A voice Transcripted named silently (`source: db`) that the user later
/// moved to a different saved person from a meeting in Settings. That is a
/// wrong silent name, the error the owner wants to see every time, so it
/// reports the same `meeting_speaker_match_reviewed` event the island sends
/// for a "Not Taylor?" correction. Buckets come from the auto-accept row the
/// pipeline wrote for that meeting; no names, ids, titles or text leave.
enum SpeakerSilentNameCorrectionTelemetry {
    static let surface = "settings"

    struct Voice: Equatable, Sendable {
        let profileID: UUID
        /// "mic" or "system"; nil for an older transcript without a channel.
        let channel: String?
    }

    /// The newest auto-accept row for this voice in this meeting, if the
    /// outcome store still has one. `outcomes` is most-recent-first.
    static func autoAcceptedOutcome(for voice: Voice, in outcomes: [SpeakerMatchOutcome]) -> SpeakerMatchOutcome? {
        outcomes.first { outcome in
            outcome.kind == .autoAccepted
                && outcome.profileId == voice.profileID
                && (voice.channel == nil || outcome.channel == nil || outcome.channel == voice.channel)
        }
    }

    /// Without the auto-accept row the match strength is unknown, not absent,
    /// so the buckets say "unknown" rather than the helpers' "none".
    static func properties(for voice: Voice, outcome: SpeakerMatchOutcome?) -> [String: String] {
        var properties: [String: String] = [
            "review_action": SpeakerMatchOutcomeKind.corrected.rawValue,
            "auto_recognized": "true",
            "had_suggestion": "true",
            "channel": voice.channel ?? outcome?.channel ?? "unknown",
            "surface": surface,
            "similarity_bucket": "unknown",
            "margin_bucket": "unknown",
            "call_count_bucket": "unknown",
        ]
        guard let outcome else { return properties }
        if outcome.similarity != nil {
            properties["similarity_bucket"] = SpeakerRecognitionTelemetry.similarityBucket(outcome.similarity)
            properties["margin_bucket"] = SpeakerRecognitionTelemetry.marginBucket(
                similarity: outcome.similarity,
                secondSimilarity: outcome.secondSimilarity
            )
        }
        if let callCount = outcome.callCountAtMatch {
            properties["call_count_bucket"] = AnalyticsReporter.countBucket(callCount)
        }
        return properties
    }

    static func track(_ properties: [[String: String]]) {
        for eventProperties in properties {
            AnalyticsReporter.track("meeting_speaker_match_reviewed", properties: eventProperties)
        }
    }
}
