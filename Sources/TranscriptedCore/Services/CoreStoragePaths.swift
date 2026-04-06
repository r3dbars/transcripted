import Foundation

/// Centralized filesystem layout for the TranscriptedCore library.
///
/// Instead of hard-coding `~/Documents/Transcripted` in every component, each
/// consumer (SpeakerDatabase, StatsDatabase, FailedTranscriptionManager,
/// TranscriptSaver, SpeakerClipExtractor, FileLogger, Audio mic/system WAV
/// writers) takes a `CoreStoragePaths` instance at init and uses it to resolve
/// concrete URLs.
///
/// This allows embedders (e.g. the Draft app) to redirect all Core output to a
/// different location without patching Core internals. The standalone
/// Transcripted app uses `.default` which mirrors the historic layout.
public struct CoreStoragePaths: Sendable {
    /// Root directory for user-facing transcript output (`~/Documents/Transcripted` by default).
    public let transcripts: URL

    /// SQLite file holding voice fingerprints (`~/Documents/Transcripted/speakers.sqlite` by default).
    public let speakerDB: URL

    /// SQLite file holding recording history (`~/Documents/Transcripted/stats.sqlite` by default).
    public let statsDB: URL

    /// JSON queue of unfinished transcriptions (`~/Documents/Transcripted/failed_transcriptions.json` by default).
    public let failedQueue: URL

    /// Directory for persistent speaker audio clips (`~/Documents/Transcripted/speaker_clips` by default).
    public let speakerClips: URL

    /// Directory for raw mic/system WAV captures written by the audio engine
    /// (`~/Documents` by default, matching the historic layout).
    public let audioCaptures: URL

    /// Directory for JSON Lines log files (`~/Library/Logs/Transcripted` by default).
    public let logs: URL

    public init(
        transcripts: URL,
        speakerDB: URL,
        statsDB: URL,
        failedQueue: URL,
        speakerClips: URL,
        audioCaptures: URL,
        logs: URL
    ) {
        self.transcripts = transcripts
        self.speakerDB = speakerDB
        self.statsDB = statsDB
        self.failedQueue = failedQueue
        self.speakerClips = speakerClips
        self.audioCaptures = audioCaptures
        self.logs = logs
    }

    /// The historic Transcripted layout:
    /// - `~/Documents/Transcripted/` for transcripts, databases, failed queue, clips
    /// - `~/Documents/` for raw mic/system WAV captures
    /// - `~/Library/Logs/Transcripted/` for app.jsonl
    ///
    /// If the documents directory is unreachable (restricted sandbox), falls back to
    /// the temporary directory so Core can still boot in a degraded mode.
    public static let `default`: CoreStoragePaths = {
        let fm = FileManager.default
        let documentsRoot = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory.appendingPathComponent("TranscriptedFallback")
        let transcriptedFolder = documentsRoot.appendingPathComponent("Transcripted")
        let logsFolder = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Transcripted")

        return CoreStoragePaths(
            transcripts: transcriptedFolder,
            speakerDB: transcriptedFolder.appendingPathComponent("speakers.sqlite"),
            statsDB: transcriptedFolder.appendingPathComponent("stats.sqlite"),
            failedQueue: transcriptedFolder.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: transcriptedFolder.appendingPathComponent("speaker_clips"),
            audioCaptures: documentsRoot,
            logs: logsFolder
        )
    }()
}
