import Foundation

/// Maps speaker labels to identified names from voice fingerprint matching.
public struct SpeakerMapping: Sendable {
    public let speakerId: String           // "0", "1", "2" for speaker IDs
    public var identifiedName: String?     // "John Smith" or nil if unidentified
    public var confidence: SpeakerConfidence?
    public var isConfirmedIdentity: Bool
    /// Set when an unconfirmed name is still shown because something other
    /// than a voiceprint supplied it. The name displays, but the speaker
    /// stays in review (`source: db_pending`) and the frontmatter row says
    /// where the name came from (`name_source:`).
    public var shownNameSource: ShownNameSource?

    /// Where a shown-but-unconfirmed name came from. The raw value is the
    /// frontmatter `name_source:` value.
    public enum ShownNameSource: String, Sendable, Equatable {
        /// The call app (Zoom, Meet, Teams, Slack) showed this person
        /// speaking while this voice talked (`CallSpeakerAttributionPolicy`).
        case callApp = "call_app"
    }

    /// Suffix written by `--name-likely-speakers`. Shown in persisted
    /// artifacts so the hedge is visible; the identity stays unconfirmed.
    public static let likelyNameSuffix = " (likely)"

    /// Display name used in persisted artifacts.
    /// Suggested identities remain generic until the user confirms them.
    /// An opt-in likely name is written as-is (`Name (likely)`) so the hedge
    /// is visible; it is never a confirmed identity.
    public var displayName: String {
        if let name = identifiedName, !name.isEmpty {
            if isConfirmedIdentity { return name }
            if shownNameSource != nil { return name }
            if name.hasSuffix(Self.likelyNameSuffix) { return name }
        }
        return "Speaker \(speakerId)"
    }

    public var suggestedName: String? {
        guard !isConfirmedIdentity else { return nil }
        return identifiedName
    }

    public init(
        speakerId: String,
        identifiedName: String? = nil,
        confidence: SpeakerConfidence? = nil,
        isConfirmedIdentity: Bool = false,
        shownNameSource: ShownNameSource? = nil
    ) {
        self.speakerId = speakerId
        self.identifiedName = identifiedName
        self.confidence = confidence
        self.isConfirmedIdentity = isConfirmedIdentity
        self.shownNameSource = shownNameSource
    }
}
