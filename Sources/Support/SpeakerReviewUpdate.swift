import Foundation

/// Plain speaker-review answers passed from UI to the Meeting bridge.
struct SpeakerReviewUpdate: Sendable {
    let persistentSpeakerId: UUID
    let diarizerSpeakerId: String
    let channel: Channel
    let newName: String
    let previousName: String?
    let action: NamingAction
    let resolvedPersistentSpeakerId: UUID?

    init(
        persistentSpeakerId: UUID,
        diarizerSpeakerId: String,
        channel: Channel = .system,
        newName: String,
        previousName: String? = nil,
        action: NamingAction,
        resolvedPersistentSpeakerId: UUID? = nil
    ) {
        self.persistentSpeakerId = persistentSpeakerId
        self.diarizerSpeakerId = diarizerSpeakerId
        self.channel = channel
        self.newName = newName
        self.previousName = previousName
        self.action = action
        self.resolvedPersistentSpeakerId = resolvedPersistentSpeakerId
    }

    enum Channel: String, Sendable {
        case mic, system

        func speakerKey(diarizerSpeakerId: String) -> String {
            "\(rawValue)_\(diarizerSpeakerId)"
        }
    }

    enum NamingAction: Sendable {
        case named      // user typed a name for unknown speaker
        case confirmed  // user confirmed suggested name
        case corrected  // user rejected suggestion and typed correct name
        case merged(targetProfileId: UUID)  // user linked this speaker to an existing profile
        case collapsedToMe  // user clicked "Keep as You" — collapse this mic speaker into the single owner
        case discardedFromDatabase  // user kept this review row out of the speaker database
    }
}
