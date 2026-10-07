import Foundation
import TranscriptedCore

/// Bridges review surfaces that hold plain `SpeakerNameChoice` values to
/// Core's naming policy, which wants its own option type. UI passes values;
/// the conversion stays in the Meeting layer.
enum MeetingSpeakerReviewNaming {
    /// The saved people a review can link a voice to, as plain values.
    static func choices(for request: SpeakerNamingRequest) -> [SpeakerNameChoice] {
        request.knownPeople.map {
            SpeakerNameChoice(id: $0.id, displayName: $0.displayName, callCount: $0.callCount)
        }
    }

    static func typedNameUpdate(
        entry: SpeakerNamingEntry,
        typedName: String,
        choicesByLabel: [String: SpeakerNameChoice]
    ) -> SpeakerNameUpdate? {
        SpeakerNamingPolicy.typedNameUpdate(
            entry: entry,
            typedName: typedName,
            optionsByLabel: choicesByLabel.mapValues {
                SpeakerIdentityOption(id: $0.id, displayName: $0.displayName, callCount: $0.callCount)
            }
        )
    }
}
