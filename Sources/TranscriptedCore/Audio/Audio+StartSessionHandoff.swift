import Foundation

// MARK: - Start/Stop handoff of the mic file and journal

/// A meeting start publishes its mic file and journal under the same session
/// lock Stop reads them with, after Stop advances the generation. So for each
/// one, either Stop sees it and owns it, or the start sees it lost and backs
/// out. Nothing a start makes is left without an owner.
extension Audio {
    /// Opens this recording's journal and publishes its session in one step
    /// under the session lock. Stop advances the generation first and then
    /// takes the session under this same lock, so it either gets the journal
    /// this start opened or no journal is opened at all. Returns nil, without
    /// calling `open`, when Stop already ended `sessionGeneration`.
    ///
    /// Reads the generation through its lock-free mirror on purpose: segment
    /// registration holds the generation lock and then reads the session, so
    /// taking the generation lock in here would invert that order. `open`
    /// must not touch `journalSession`.
    func openJournalSessionIfCurrent(
        sessionGeneration: UInt64,
        open: () throws -> MeetingRecordingJournalSession
    ) rethrows -> MeetingRecordingJournalSession? {
        journalSessionLock.lock()
        defer { journalSessionLock.unlock() }
        guard recordingSessionGeneration == sessionGeneration else { return nil }
        let session = try open()
        _journalSession = session
        return session
    }

    /// Records the start's mic WAV as this recording's file, but only while
    /// `sessionGeneration` is still current. Runs under the session lock that
    /// Stop's `snapshotStartedMicFiles` takes after it advances the
    /// generation, so either Stop sees this URL and owns the file, or this
    /// returns false and the start never creates it. Lock order is session
    /// lock, then the segment lock; nothing takes them the other way round.
    func publishMeetingMicStartFileIfCurrent(_ fileURL: URL, sessionGeneration: UInt64) -> Bool {
        journalSessionLock.lock()
        defer { journalSessionLock.unlock() }
        guard recordingSessionGeneration == sessionGeneration else { return false }
        originalMicAudioFileURL = fileURL
        micSegments = [MicRecordingSegment(url: fileURL)]
        return true
    }

    /// Stop's read of the start's mic files. See
    /// `publishMeetingMicStartFileIfCurrent`.
    func snapshotStartedMicFiles() -> (primaryURL: URL?, segments: [MicRecordingSegment]) {
        journalSessionLock.lock()
        defer { journalSessionLock.unlock() }
        return (originalMicAudioFileURL, micSegments)
    }
}
