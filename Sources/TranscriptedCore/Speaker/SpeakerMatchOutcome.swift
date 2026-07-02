import Foundation

// MARK: - Speaker match outcomes (the recognition lifeline)

/// One recorded verdict in a speaker profile's recognition lifeline.
///
/// Rows are written at exactly two points:
/// - the pipeline runner records `.autoAccepted` when a returning speaker is
///   silently named without review
/// - the naming coordinator records the user's review verdict
///   (`.confirmed` / `.corrected` / `.named` / `.merged`) when the review
///   sheet is submitted
///
/// The store keeps only similarity numbers, counts, and enum kinds — never
/// display names, embeddings, transcript text, or audio — so it can back the
/// local `speaker-stats` report and the bucketed anonymous analytics events
/// without becoming a privacy surface.
public enum SpeakerMatchOutcomeKind: String, Sendable, CaseIterable {
    /// Silently recognized without review (`SpeakerNamingPolicy.shouldAutoAccept`).
    case autoAccepted = "auto_accepted"
    /// User accepted the suggested match — the suggestion was right.
    case confirmed
    /// User rejected the suggested match — the suggestion was wrong.
    case corrected
    /// User named a voice that had no accepted suggestion (enrollment).
    case named
    /// User manually linked the voice to an existing saved person.
    case merged
}

public struct SpeakerMatchOutcome: Sendable {
    public let profileId: UUID
    public let kind: SpeakerMatchOutcomeKind
    /// Best-profile cosine similarity at match time, when a match was attempted.
    public let similarity: Double?
    /// Runner-up similarity at match time; margin = similarity − secondSimilarity.
    public let secondSimilarity: Double?
    /// The profile's call_count at match time — its appearance number, which is
    /// what makes "how many meetings until auto-recognition" computable later.
    public let callCountAtMatch: Int?
    /// "mic" or "system" (`UtteranceChannel.rawValue`); nil when unknown.
    public let channel: String?
    /// Saved transcript this outcome belongs to, for per-meeting grouping.
    public let transcriptId: UUID?
    public let recordedAt: Date

    public init(
        profileId: UUID,
        kind: SpeakerMatchOutcomeKind,
        similarity: Double? = nil,
        secondSimilarity: Double? = nil,
        callCountAtMatch: Int? = nil,
        channel: String? = nil,
        transcriptId: UUID? = nil,
        recordedAt: Date = Date()
    ) {
        self.profileId = profileId
        self.kind = kind
        self.similarity = similarity
        self.secondSimilarity = secondSimilarity
        self.callCountAtMatch = callCountAtMatch
        self.channel = channel
        self.transcriptId = transcriptId
        self.recordedAt = recordedAt
    }
}

// MARK: - Profile health (self-healing demotion)

/// Trust tier that gates silent auto-recognition per profile.
///
/// A profile whose recent verdicts include corrections is demoted from silent
/// auto-accept back to "confirm?" mode until the user re-confirms it. That is
/// the anti-degradation property: a wrong profile cannot keep mislabeling
/// meetings quietly — its errors turn into review questions, and the answers
/// repair it (or keep it demoted).
public enum SpeakerProfileHealth: Sendable, Equatable {
    case trusted
    case probation

    /// How many most-recent outcomes the demotion rules look at.
    public static let recentOutcomeWindow = 5

    /// Assess a profile from its dispute count and most-recent-first outcome kinds.
    ///
    /// Probation when any of:
    /// - an unresolved dispute is on the profile (existing auto-accept blocker)
    /// - the most recent user verdict in the window was a correction, so the
    ///   profile must earn back one explicit confirmation before going silent
    ///   again even after its dispute count was reset through a merge/rename path
    /// - two or more corrections landed inside the window (chronically confusable)
    public static func assess(
        disputeCount: Int,
        recentOutcomes: [SpeakerMatchOutcomeKind]
    ) -> SpeakerProfileHealth {
        if disputeCount > 0 { return .probation }

        let window = recentOutcomes.prefix(recentOutcomeWindow)
        if let latestVerdict = window.first(where: { $0 != .autoAccepted }),
           latestVerdict == .corrected {
            return .probation
        }
        if window.filter({ $0 == .corrected }).count >= 2 {
            return .probation
        }
        return .trusted
    }
}
