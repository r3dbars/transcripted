import Foundation

/// Maps speaker labels to identified names from voice fingerprint matching.
public struct SpeakerMapping: Sendable {
    public let speakerId: String           // "0", "1", "2" for speaker IDs
    public var identifiedName: String?     // "John Smith" or nil if unidentified
    public var confidence: SpeakerConfidence?
    public var isConfirmedIdentity: Bool

    /// Display name used in persisted artifacts.
    /// Suggested identities remain generic until the user confirms them.
    public var displayName: String {
        if isConfirmedIdentity, let name = identifiedName {
            return name
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
