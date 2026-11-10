import Combine
import Darwin
import Foundation
import FluidAudio
import TranscriptedCore

// A Core-only import host. It never constructs Audio/AVAudioEngine, loads a
// model, starts an app, or uses a default failed-queue, database, stats or capture path.
@MainActor
private final class SyntheticSpeech: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    var calls = 0
    var usesRepresentativeLanguageSamples: Bool { false }
    var transcriptionEngineDescriptor: SpeechTranscriptionEngineDescriptor {
        .init(identifier: "synthetic_smoke", displayName: "Synthetic smoke")
    }
    func initialize() async { isReady = true }
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        calls += 1
        if ProcessInfo.processInfo.environment["TRANSCRIPTED_IMPORTED_SMOKE_FAIL_STT"] == "1" {
            throw NSError(domain: "SyntheticImportedAudioSmoke", code: 1)
        }
        return "The imported recording should save as one searchable meeting note."
    }
    func cleanup() { isReady = false }
}

@MainActor
private final class SyntheticDiarizer: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    var calls = 0
    func initialize() async { isReady = true }
    private func segments() -> [SpeakerSegment] {
        calls += 1
        return [.init(speakerId: 1, startTime: 0, endTime: 3,
                      embedding: Array(repeating: 0.42, count: 256), qualityScore: 0.95)]
    }
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { segments() }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { segments() }
    func cleanup() { isReady = false }
}

private final class InMemoryStats: StatsStore {
    private let lock = NSLock()
    private var sessions: [RecordingMetadata] = []
    func recordSession(_ metadata: RecordingMetadata) {
        lock.lock(); defer { lock.unlock() }
        sessions.append(metadata)
    }
    func getTotalRecordingsCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] {
        lock.lock(); defer { lock.unlock() }
        return sessions.filter { $0.date >= startDate && $0.date <= endDate }
    }
    func recordingExists(transcriptPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.contains { $0.transcriptPath == transcriptPath }
    }
}

private struct ProducerReceipt: Encodable {
    let formatVersion = 1
    let transcript: String
    let retainedAudio: String
    let speechCalls: Int
    let diarizationCalls: Int
}

@main
private enum ImportedAudioArtifactSmoke {
    @MainActor
    static func main() async {
        setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)
        setenv("TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS", "1", 1)
        // A hang guard, not a performance assertion. Every write below is
        // confined to the fresh QA-owned evidence root, even on failure.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            fputs("BLOCKED: Core imported-audio smoke did not finish.\n", stderr)
            exit(3)
        }
        do { try await run() }
        catch {
            fputs("Core imported-audio smoke failed; no pipeline success receipt emitted.\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, args[0] == "--root", args[2] == "--source" else { throw invalid() }
        let root = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let source = URL(fileURLWithPath: args[3]).standardizedFileURL
        let prefix = "transcripted-imported-audio-smoke-"
        guard root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              root.resolvingSymlinksInPath() == root,
              source == root.appendingPathComponent("source/Imported Partner Brief.wav"),
              (try? String(contentsOf: root.appendingPathComponent(".producer-root"), encoding: .utf8)) == "core-import-smoke-v1",
              try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular
        else { throw invalid() }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/unused-stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed.json"),
            speakerClips: root.appendingPathComponent("state/clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("scratch", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        for directory in [paths.transcripts, paths.speakerClips, paths.audioCaptures] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let scratch = paths.audioCaptures.appendingPathComponent("imported.wav")
        try FileManager.default.copyItem(at: source, to: scratch)
        let speech = SyntheticSpeech()
        let diarizer = SyntheticDiarizer()
        let failed = FailedTranscriptionManager(paths: paths)
        let speakers = SpeakerDatabase(path: paths.speakerDB.path, adoptCanonicalModelIdentity: false)
        let retention = paths.transcripts.appendingPathComponent("audio", isDirectory: true)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: failed,
            speechToText: speech,
            diarization: diarizer,
            speakerStore: speakers,
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: retention,
            transcriptDirectoryProvider: { paths.transcripts },
            transcriptFormatOptionsProvider: { TranscriptFormatOptions(audioSources: [.systemAudio]) },
            statsStore: InMemoryStats(),
            notifier: nil
        )
        manager.startImportedTranscription(
            audioURL: scratch,
            outputFolder: paths.transcripts,
            meetingTitle: "Imported Partner Brief",
            recordingDate: Date(timeIntervalSince1970: 1_782_144_900)
        )
        while manager.activeCount > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        guard speech.calls > 0, diarizer.calls > 0,
              failed.failedTranscriptions.isEmpty,
              manager.lastFailureDiagnosticMessage == nil,
              let transcript = manager.lastSavedTranscriptURL else { throw invalid() }
        let retained = retention.appendingPathComponent(transcript.deletingPathExtension().lastPathComponent + "_audio")
            .appendingPathComponent("recording.wav")
        guard FileManager.default.fileExists(atPath: retained.path),
              try Data(contentsOf: source) == Data(contentsOf: retained) else { throw invalid() }
        func relative(_ file: URL) throws -> String {
            let canonical = file.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(root.path + "/") else { throw invalid() }
            return String(canonical.path.dropFirst(root.path.count + 1))
        }
        let receipt = try ProducerReceipt(transcript: relative(transcript), retainedAudio: relative(retained),
                                          speechCalls: speech.calls, diarizationCalls: diarizer.calls)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("producer-receipt.json"), options: .atomic)
    }

    private static func invalid() -> NSError { NSError(domain: "SyntheticImportedAudioSmoke", code: 2) }
}
