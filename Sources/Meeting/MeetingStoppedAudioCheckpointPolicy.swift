// MeetingStoppedAudioCheckpointPolicy.swift
// A stopped dictation take that was too long can be imported as a meeting.
// Its restart checkpoint (the WAV under dictation-audio-recovery) is retired
// only once the meeting transcript is saved. A failed job keeps it so the
// take can still be recovered, and a discarded job leaves it alone.

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
