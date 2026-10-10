import Foundation

/// Maps speaker labels to identified names from voice fingerprint matching.
public struct SpeakerMapping: Sendable {
    public let speakerId: String           // "0", "1", "2" for speaker IDs
    public var identifiedName: String?     // "John Smith" or nil if unidentified
    public var confidence: SpeakerConfidence?
    public var isConfirmedIdentity: Bool

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
        isConfirmedIdentity: Bool = false
    ) {
        self.speakerId = speakerId
        self.identifiedName = identifiedName
        self.confidence = confidence
        self.isConfirmedIdentity = isConfirmedIdentity
    }
}
