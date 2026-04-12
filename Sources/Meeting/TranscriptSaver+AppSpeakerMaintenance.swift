import Foundation
import TranscriptedCore

extension TranscriptSaver {
    /// App-side compatibility overload for settings-driven rename flows.
    /// TranscriptedCore now owns the file rewrite, while the app refreshes the agent index.
    static func retroactivelyUpdateSpeaker(
        dbId: UUID,
        newName: String,
        directory: URL,
        speakerStoreForIndex: any SpeakerStore
    ) {
        retroactivelyUpdateSpeaker(dbId: dbId, newName: newName)
        try? AgentOutput.writeIndex(to: directory, speakerStore: speakerStoreForIndex)
    }

    /// App-side compatibility overload for merge flows.
    /// The surviving speaker profile is reflected in future indexing, even though
    /// TranscriptedCore no longer exposes the older directory-scoped merge rewrite helper.
    static func retroactivelyMergeSpeaker(
        sourceDbId: UUID,
        into targetDbId: UUID,
        newName: String,
        directory: URL,
        speakerStoreForIndex: any SpeakerStore
    ) {
        _ = sourceDbId
        retroactivelyUpdateSpeaker(dbId: targetDbId, newName: newName)
        try? AgentOutput.writeIndex(to: directory, speakerStore: speakerStoreForIndex)
    }
}
