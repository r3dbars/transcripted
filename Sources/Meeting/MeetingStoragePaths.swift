// MeetingStoragePaths.swift
// Split meeting storage between relocatable user captures and app-owned state.

import Foundation

enum MeetingStoragePaths {

    /// Root: <capture-library>/meetings/
    static var root: URL {
        let url = FileManager.default.meetingSupportDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Meeting captures live directly in the meetings folder.
    static var transcriptsFolder: URL {
        let url = root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var stateFolder: URL {
        let url = FileManager.default.transcriptedStateDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var speakersDatabase: URL {
        stateFolder.appendingPathComponent("speakers.sqlite", isDirectory: false)
    }

    static var statsDatabase: URL {
        stateFolder.appendingPathComponent("stats.sqlite", isDirectory: false)
    }

    static var failedTranscriptionsFile: URL {
        stateFolder.appendingPathComponent("failed_transcriptions.json", isDirectory: false)
    }

    static var cacheFolder: URL {
        FileManager.default.transcriptedCacheDir
    }

    static var logsFolder: URL {
        FileManager.default.transcriptedLogsDir
    }

    /// A transient scratch path kept under tmp/ so speaker clips are never persisted as
    /// long-term state even if the naming flow uses them briefly.
    static var speakerClipsFolder: URL {
        let url = recordingsScratch.appendingPathComponent("speaker_clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Temporary scratch directory for in-progress recordings. Cleaned on a best-effort basis.
    static var recordingsScratch: URL {
        let url = FileManager.default.transcriptedRecordingsDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
