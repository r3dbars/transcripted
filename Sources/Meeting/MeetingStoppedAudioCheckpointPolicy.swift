// MeetingStoppedAudioCheckpointPolicy.swift
// A stopped dictation take that was too long can be imported as a meeting.
// Its checkpoint (the WAV under dictation-audio-recovery) is retired only
// once the meeting transcript is saved. A failed or discarded job leaves it
// alone (the importer works from its own copy). The next launch's
// DictationStoppedAudioRecoveryStore.purgeLeftovers keeps it when it holds
// 30 s or more of audio and deletes it when shorter.

import Foundation

enum MeetingStoppedAudioCheckpointPolicy {
    enum JobEnd: Equatable {
        case transcriptSaved
        case failed
        case discardedAccidentalStart
    }

    static func transcriptPersisted(after end: JobEnd) -> Bool {
        end == .transcriptSaved
    }

    /// Returns `true` when the checkpoint was retired.
    @discardableResult
    static func finish(
        _ recovery: DictationStoppedAudioRecovery?,
        after end: JobEnd,
        fileManager: FileManager = .default
    ) -> Bool {
        DictationStoppedAudioRecoveryStore.cleanup(
            recovery,
            transcriptPersisted: transcriptPersisted(after: end),
            fileManager: fileManager
        )
    }
}
