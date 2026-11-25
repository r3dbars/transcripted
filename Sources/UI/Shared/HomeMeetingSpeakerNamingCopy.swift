import Foundation

/// Meetings copy for the transcript's quick fix ("Who's this?").
enum HomeMeetingSpeakerNamingCopy {
    /// Shown when a typed name is written into this transcript and no
    /// voiceprint was saved — CLI-imported or older meetings with no
    /// retained audio, or a WeSpeaker-native launch with no embedder.
    static let transcriptOnlyNoVoiceprint = "Named in this transcript only, no voiceprint saved"
    /// The quick fix's line under "Who's this?". Before saving, whether a
    /// voice print lands depends on kept audio, which it can't know yet.
    static let learnsVoiceIfAudioKept = "This meeting. Learns the voice if its audio was kept."
    static let renamesSavedPerson = "Renames this person in all their meetings."
    static let usesSavedPerson = "Uses this person in all their meetings."
    static let linksToSavedPerson = "Links this voice to that person."

    static func pickerScope(isSavedPerson: Bool, selectedProfileID: UUID?) -> String {
        if isSavedPerson {
            return selectedProfileID == nil ? renamesSavedPerson : usesSavedPerson
        }
        return selectedProfileID == nil ? learnsVoiceIfAudioKept : linksToSavedPerson
    }
}

enum HomeMeetingSpeakerVoiceprintSave {
    /// Attach a newly enrolled or taught person to a transcript-local edit
    /// so `HomeMeetingSpeakerRename` writes `db_id`.
    static func linking(
        _ assignment: HomeMeetingSpeakerAssignment,
        to profileID: UUID
    ) -> HomeMeetingSpeakerAssignment {
        HomeMeetingSpeakerAssignment(
            identity: assignment.identity,
            newName: assignment.newName,
            targetProfileID: assignment.targetProfileID ?? profileID,
            removesPersistentSpeakerLink: assignment.removesPersistentSpeakerLink
        )
    }
}
