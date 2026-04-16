// MeetingStoragePaths.swift
// Split meeting storage between relocatable user captures and app-owned state.

import Foundation

enum MeetingStoragePaths {

    /// Root: <capture-library>/meetings/
    static var root: URL {
        FileManager.default.meetingSupportDir
    }

    /// Meeting captures live directly in the meetings folder.
    static var transcriptsFolder: URL {
        root
    }

    static var stateFolder: URL {
        FileManager.default.transcriptedStateDir
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
        FileManager.default.ensurePrivateDirectory(at: url, context: "meeting speaker clips")
        return url
    }

    /// Temporary scratch directory for in-progress recordings. Cleaned on a best-effort basis.
    static var recordingsScratch: URL {
        FileManager.default.transcriptedRecordingsDir
    }
}
