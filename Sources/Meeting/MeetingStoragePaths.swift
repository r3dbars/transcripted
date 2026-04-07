// MeetingStoragePaths.swift
// Draft-owned storage layout for the Meeting feature.
// Isolates Draft meeting artifacts from Transcripted's ~/Documents/Transcripted
// so both apps can coexist without clobbering each other's databases.
// See merge-plan.md §6.5 Option B.

import Foundation

/// Absolute file/folder locations for meeting transcripts, speaker DB, stats DB,
/// failed-queue, speaker clips, and logs. All live under
/// `~/Library/Application Support/Draft/meetings/`.
///
/// Each property is computed (never cached) so that the directories exist on the
/// next read even if the user manually deleted them between sessions. Each call
/// creates missing parent directories with `withIntermediateDirectories: true`.
enum MeetingStoragePaths {

    /// Root: `~/Library/Application Support/Draft/meetings/`
    static var root: URL {
        let url = FileManager.default.meetingSupportDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Folder where TranscriptionTaskManager writes saved `.md` + `.json` transcripts.
    static var transcriptsFolder: URL {
        let url = root.appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Persistent speaker embeddings/profiles (SQLite). Passed to `SpeakerDatabase(path:)`.
    static var speakersDatabase: URL {
        root.appendingPathComponent("speakers.sqlite", isDirectory: false)
    }

    /// Speaker audio clips (one WAV per identified speaker) written by the diarization pipeline.
    static var speakerClipsFolder: URL {
        let url = root.appendingPathComponent("speaker_clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Temporary scratch directory for in-progress recordings. Cleaned on a best-effort basis.
    static var recordingsScratch: URL {
        let url = root.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
