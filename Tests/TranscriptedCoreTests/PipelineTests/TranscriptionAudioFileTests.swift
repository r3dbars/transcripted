import XCTest
import Combine
import FluidAudio
import TranscriptedCore

@available(macOS 14.0, *)
extension TranscriptionTaskManagerMetadataTests {
    func testAudioFilePublicAPIInitializesModelsAndPreservesInput() async throws {
        let input = tempDirectory.appendingPathComponent("import.wav")
        try writeMonoWAV(to: input, duration: 2)
        let original = try Data(contentsOf: input)
        let engine = FileInputSpeechToTextEngine(isReady: false)
        let diarizer = MetadataStubDiarizationEngine(
            isReady: false,
            segments: singleSpeakerSegments()
        )
        let store = SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
        let profile = store.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.42, count: 256), existingId: nil
        )
        store.setDisplayName(id: profile.id, name: "Fixture Speaker", source: NameSource.userManual)
        let clips = tempDirectory.appendingPathComponent("unused-clips")
        let transcription = Transcription(
            speechToText: engine, diarization: diarizer,
            speakerStore: store, speakerClipsDirectory: clips
        )
        let progress = FileInputProgressRecorder()

        let result = try await transcription.transcribeAudioFile(at: input) {
            progress.append($0)
        }

        XCTAssertEqual(engine.initializeCallCount, 1)
        XCTAssertEqual(diarizer.initializeCallCount, 1)
        XCTAssertEqual(engine.selections, [.automatic])
        XCTAssertEqual(engine.sampleCounts, [32_000])
        XCTAssertEqual(engine.systemSources, [true])
        XCTAssertTrue(result.micUtterances.isEmpty)
        XCTAssertEqual(result.microphoneAudioOutcome, .notProvided)
        XCTAssertEqual(result.systemAudioOutcome, .usable)
        XCTAssertEqual(result.duration, 2, accuracy: 0.001)
        XCTAssertEqual(result.systemUtterances.map(\.transcript), ["Fixture transcript"])
        XCTAssertEqual(result.systemUtterances.first?.persistentSpeakerId, profile.id)
        XCTAssertEqual(result.systemSpeakerContexts["1"]?.matchedProfileSnapshot?.displayName, "Fixture Speaker")
        XCTAssertEqual(progress.values.first, 0)
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertNil(transcription.lastSavedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clips.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path).contains { $0.hasSuffix(".md") })
    }

    func testAudioFilePublicAPIPropagatesExplicitLanguage() async throws {
        let input = tempDirectory.appendingPathComponent("explicit-language.wav")
        try writeMonoWAV(to: input, duration: 2)
        let engine = FileInputSpeechToTextEngine()
        let transcription = Transcription(
            speechToText: engine,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            speakerStore: SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
        )
        let selection = TranscriptionLanguageSelection.explicit(code: "fi")

        let result = try await transcription.transcribeAudioFile(at: input, languageSelection: selection)

        XCTAssertEqual(engine.initializeCallCount, 0, "Ready injected engines should be reused")
        XCTAssertEqual(engine.selections, [selection])
        XCTAssertEqual(engine.representativeSampleCounts, [0])
        XCTAssertEqual(result.languageContext?.selection, selection)
        XCTAssertEqual(result.languageContext?.languageCode, "fi")
        XCTAssertEqual(result.languageContext?.resolution, .explicit)
        XCTAssertEqual(engine.segmentLanguages, [try XCTUnwrap(result.languageContext)])
    }

    func testAudioFilePublicAPIPropagatesReadinessFailureWithoutDeletingInput() async throws {
        let input = tempDirectory.appendingPathComponent("model-unavailable.wav")
        try writeMonoWAV(to: input, duration: 2)
        let original = try Data(contentsOf: input)
        let engine = FileInputSpeechToTextEngine(isReady: false, initializeSucceeds: false)
        let transcription = Transcription(
            speechToText: engine,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            speakerStore: SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
        )

        do {
            _ = try await transcription.transcribeAudioFile(at: input)
            XCTFail("Expected the unready injected model to fail")
        } catch PipelineError.modelNotLoaded(let model) {
            XCTAssertEqual(model, "Parakeet")
        }

        XCTAssertEqual(engine.initializeCallCount, 1)
        XCTAssertTrue(engine.sampleCounts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertNil(transcription.lastSavedFileURL)
    }

    func testAudioFilePublicAPIPropagatesNoSpeechWithoutDeletingInput() async throws {
        let input = tempDirectory.appendingPathComponent("no-speech.wav")
        try writeMonoWAV(to: input, duration: 2)
        let original = try Data(contentsOf: input)
        let engine = FileInputSpeechToTextEngine()
        let transcription = Transcription(
            speechToText: engine,
            diarization: MetadataStubDiarizationEngine(segments: []),
            speakerStore: SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
        )

        do {
            _ = try await transcription.transcribeAudioFile(at: input)
            XCTFail("Expected the shared pipeline to reject a no-speech result")
        } catch PipelineError.noSpeechDetected {
            // The file-only entry point preserves the pipeline's typed error.
        }

        XCTAssertTrue(engine.sampleCounts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(transcription.isProcessing)
        XCTAssertNil(transcription.lastSavedFileURL)
    }
}

@available(macOS 14.0, *)
@MainActor
private final class FileInputSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool
    private let initializeSucceeds: Bool
    var initializeCallCount = 0
    var selections: [TranscriptionLanguageSelection] = []
    var representativeSampleCounts: [Int] = []
    var segmentLanguages: [TranscriptionLanguageContext] = []
    var sampleCounts: [Int] = []
    var systemSources: [Bool] = []

    init(isReady: Bool = true, initializeSucceeds: Bool = true) {
        self.isReady = isReady
        self.initializeSucceeds = initializeSucceeds
    }

    func initialize() async {
        initializeCallCount += 1
        isReady = initializeSucceeds
    }

    func resolveLanguage(
        representativeSamples: [[Float]], selection: TranscriptionLanguageSelection
    ) async throws -> TranscriptionLanguageContext {
        selections.append(selection)
        representativeSampleCounts.append(representativeSamples.count)
        switch selection {
        case .automatic:
            return .init(selection: selection, languageCode: nil, resolution: .automaticUncertain)
        case .explicit(let code):
            return .init(selection: selection, languageCode: code, resolution: .explicit)
        }
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        XCTFail("The pipeline must use the resolved language context")
        return ""
    }

    func transcribeSegment(
        samples: [Float], source: AudioSource, language: TranscriptionLanguageContext
    ) async throws -> String {
        segmentLanguages.append(language)
        sampleCounts.append(samples.count)
        systemSources.append(source == .system)
        return "Fixture transcript"
    }

    func cleanup() { isReady = false }
}

private final class FileInputProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        recordedValues.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}
