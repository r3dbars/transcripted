import Foundation
@testable import TranscriptedCore

extension TranscriptSaver {
    /// Test convenience over the production batch API: name one deferred review
    /// row in its saved transcript. Production callers always use the batch
    /// `updateDeferredSpeakerNames(_:newName:)` directly.
    @discardableResult
    static func updateDeferredSpeakerName(
        transcriptURL: URL,
        dbId: UUID,
        diarizerSpeakerId: String,
        channel: UtteranceChannel,
        newName: String
    ) -> Bool {
        (try? updateDeferredSpeakerNames(
            [DeferredSpeakerNameUpdate(
                transcriptURL: transcriptURL,
                dbId: dbId,
                diarizerSpeakerId: diarizerSpeakerId,
                channel: channel
            )],
            newName: newName
        )) ?? false
    }
}
