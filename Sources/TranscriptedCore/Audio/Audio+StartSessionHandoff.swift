import Foundation

// MARK: - Start/Stop handoff of the mic file and journal

/// A meeting start publishes its mic file and journal under the same session
/// lock Stop reads them with, after Stop advances the generation. So for each
/// one, either Stop sees it and owns it, or the start sees it lost and backs
/// out. Nothing a start makes is left without an owner.
extension Audio {
    /// Commit both filenames before either backend can create a writer or admit PCM.
    func openMeetingStartTracks(
        capturesSystemAudio: Bool, sessionGeneration: UInt64
    ) throws -> (mic: URL, system: URL?) {
        let directory = paths.audioCaptures
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "meeting_\(DateFormattingHelper.formatFilenamePrecise(Date()))"
        let mic = directory.appendingPathComponent(stem + "_mic.wav")
        let system = capturesSystemAudio ? directory.appendingPathComponent(stem + "_system.wav") : nil
        guard ![mic, system].compactMap({ $0 }).contains(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw MeetingRecordingJournalStartError.alreadyExists
        }
        _ = try openJournalSessionIfCurrent(
            primaryMicURL: mic, systemURL: system, sessionGeneration: sessionGeneration
        )
        return (mic, system)
    }

    func openJournalSessionIfCurrent(
        primaryMicURL: URL, systemURL: URL? = nil, sessionGeneration: UInt64
    ) throws -> MeetingRecordingJournalSession {
        guard recordingSessionGeneration == sessionGeneration else { throw AudioCaptureStaleSessionError() }
        do {
            return try recordingJournal.begin(
                primaryMicURL: primaryMicURL,
                systemURL: systemURL,
                languageSelection: languageSelectionForCurrentRecording,
                micOnlyByChoice: !currentRecordingCapturesSystemAudio
            ) { session in
                try journalSessionLock.withLock {
                    guard recordingSessionGeneration == sessionGeneration else {
                        throw AudioCaptureStaleSessionError()
                    }
                    _journalSession = session
                }
            }
        } catch {
            guard recordingSessionGeneration == sessionGeneration else { throw AudioCaptureStaleSessionError() }
            throw error
        }
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
