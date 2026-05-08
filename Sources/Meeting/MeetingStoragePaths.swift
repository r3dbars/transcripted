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

    /// Retained mic/system audio for saved meetings.
    static var audioArchiveFolder: URL {
        let url = root.appendingPathComponent("audio", isDirectory: true)
        FileManager.default.ensurePrivateDirectory(at: url, context: "meeting audio archive")
        return url
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

    /// Owner-only speaker review samples live under tmp/recordings. Temporary
    /// per-meeting clips are cleaned after review; one UUID-keyed sample can stay
    /// so Settings > People still has audio evidence when review is deferred.
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
