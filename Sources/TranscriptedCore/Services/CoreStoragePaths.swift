import Foundation

/// Centralized filesystem layout for the TranscriptedCore library.
///
/// Instead of hard-coding a home-directory Transcripted folder in every
/// component, each consumer (SpeakerDatabase, StatsDatabase, FailedTranscriptionManager,
/// TranscriptSaver, SpeakerClipExtractor, FileLogger, Audio mic/system WAV
/// writers) takes a `CoreStoragePaths` instance at init and uses it to resolve
/// concrete URLs.
///
/// This allows embedders (e.g. the app in this repo) to redirect all Core output to a
/// different location without patching Core internals. The standalone
/// Transcripted app uses `.default` which mirrors the historic layout.
public struct CoreStoragePaths: Sendable {
    /// Root directory for user-facing meeting capture output.
    public let transcripts: URL

    /// SQLite file holding voice fingerprints.
    public let speakerDB: URL

    /// SQLite file holding recording history.
    public let statsDB: URL

    /// JSON queue of unfinished transcriptions.
    public let failedQueue: URL

    /// Directory for temporary speaker audio clips if a host still needs them.
    public let speakerClips: URL

    /// Directory for raw mic/system WAV captures written by the audio engine.
    public let audioCaptures: URL

    /// Directory for JSON Lines log files.
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

    /// Default Transcripted layout:
    /// - `~/Library/Application Support/Transcripted/captures/meetings/` for meeting captures
    /// - `~/Library/Application Support/Transcripted/state/` for databases + failed queue
    /// - `~/Library/Application Support/Transcripted/tmp/recordings/` for raw audio scratch
    /// - `~/Library/Application Support/Transcripted/logs/` for app.jsonl
    ///
    /// If the Application Support directory is unreachable (restricted sandbox), falls back to
    /// the temporary directory so Core can still boot in a degraded mode.
    public static let `default`: CoreStoragePaths = {
        let fm = FileManager.default
        let appSupportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Transcripted", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("TranscriptedFallback", isDirectory: true)
        let capturesRoot = appSupportRoot.appendingPathComponent("captures", isDirectory: true)
        let stateRoot = appSupportRoot.appendingPathComponent("state", isDirectory: true)
        let logsFolder = appSupportRoot.appendingPathComponent("logs", isDirectory: true)
        let tmpRecordings = appSupportRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)

        return CoreStoragePaths(
            transcripts: capturesRoot.appendingPathComponent("meetings", isDirectory: true),
            speakerDB: stateRoot.appendingPathComponent("speakers.sqlite"),
            statsDB: stateRoot.appendingPathComponent("stats.sqlite"),
            failedQueue: stateRoot.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tmpRecordings.appendingPathComponent("speaker_clips", isDirectory: true),
            audioCaptures: tmpRecordings,
            logs: logsFolder
        )
    }()
}
