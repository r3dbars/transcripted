import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Which audio channel a speaker in the review queue came from. Review
/// surfaces (UI) hold this plain value so they never name the Core
/// `UtteranceChannel`; the one hop back to Core is `utteranceChannel`, used
/// where a Core write API still wants its own channel type.
enum SpeakerReviewChannel: String, Sendable, Hashable {
    case mic
    case system

    #if canImport(TranscriptedCore)
    var utteranceChannel: UtteranceChannel {
        switch self {
        case .mic: return .mic
        case .system: return .system
        }
    }
    #endif
}
