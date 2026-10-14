import Foundation

/// Home copy for naming a voice that is not (yet) a saved person.
enum HomeMeetingSpeakerNamingCopy {
    /// Shown when a typed name is written into this transcript and no
    /// voiceprint was saved — CLI-imported or older meetings with no
    /// retained audio, or a WeSpeaker-native launch with no embedder.
    static let transcriptOnlyNoVoiceprint = "Named in this transcript only, no voiceprint saved"
    /// Before saving: whether a voiceprint lands depends on retained audio,
    /// which the picker can't know yet.
    static let learnsVoiceIfAudioKept = "Updates this meeting, and learns the voice if its audio was kept."
    static let thisMeeting = "This meeting"

    static let renamesSavedPerson = "Renames this saved person in linked meetings."
    static let usesSavedPerson = "Uses this saved person in linked meetings."
    static let linksToSavedPerson = "Links this voice to the saved person."
    static let linkedMeetings = "Linked meetings"

    static func pickerScope(isSavedPerson: Bool, selectedProfileID: UUID?) -> String {
        if isSavedPerson {
            return selectedProfileID == nil ? renamesSavedPerson : usesSavedPerson
        }
        return selectedProfileID == nil ? learnsVoiceIfAudioKept : linksToSavedPerson
    }

    static func rowScope(isSavedPerson: Bool) -> String {
        isSavedPerson ? linkedMeetings : thisMeeting
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
