import XCTest
import Combine
import FluidAudio
import AVFoundation
@testable import TranscriptedCore

/// The default meeting mic path releases its whole-meeting buffer while the
/// call track is diarized and transcribed, then loads it again for the mic
/// phase. These tests hold it to the promise that nothing a user sees changes:
/// the same words from the same audio, the same fallbacks, the same progress.
@available(macOS 14.0, *)
final class MeetingMicReleaseTests: XCTestCase {

    // MARK: - Same output

    /// An engine that scans both tracks for language windows keeps the mic
    /// buffer the whole time (today's path). An engine that doesn't releases
    /// and reloads it. Echoing a digest of every slice proves both runs handed
    /// speech-to-text byte-identical audio on both channels.
    @MainActor
    func testReleasedMicTranscribesTheSameSamplesAsTheHeldMic() async throws {
        let tracks = try makeTracks()

        let held = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: true))
        let released = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: false))

        XCTAssertFalse(released.micUtterances.isEmpty)
        XCTAssertFalse(released.systemUtterances.isEmpty)
        XCTAssertEqual(lines(released.micUtterances), lines(held.micUtterances))
        XCTAssertEqual(lines(released.systemUtterances), lines(held.systemUtterances))
        XCTAssertEqual(released.microphoneAudioOutcome, .usable)
        XCTAssertEqual(released.systemAudioOutcome, .usable)
        XCTAssertEqual(released.droppedSegments, held.droppedSegments)
    }

    /// The mic slices match what one straight load of the mic file yields
    /// through the same silence split and per-segment preparation.
    @MainActor
    func testReleasedMicSlicesMatchAStraightLoadOfTheMicFile() async throws {
        let tracks = try makeTracks()
        let result = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: false))

        let mic = try AudioResampler.loadAndResample(url: tracks.mic, targetRate: 16000)
        let expected: [String] = Transcription.detectSpeechSegments(samples: mic, sampleRate: 16000)
            .compactMap { segment in
                let slice = AudioResampler.extractSlice(from: mic, sampleRate: 16000, startTime: segment.start, endTime: segment.end)
                return Transcription.prepareMicSegmentForTranscription(samples: slice, sampleRate: 16000)
                    .map { DigestEchoEngine.digest($0.samples, source: .microphone) }
            }
        XCTAssertEqual(expected.count, 2)
        XCTAssertEqual(result.micUtterances.map(\.transcript), expected)
    }

    @MainActor
    func testExplicitLanguageReleasedMicKeepsTheSameWords() async throws {
        let tracks = try makeTracks()
        let automatic = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: true))
        let explicit = try await run(
            tracks,
            engine: DigestEchoEngine(scansLanguageWindows: true),
            language: .explicit(code: "de")
        )
        XCTAssertEqual(lines(explicit.micUtterances), lines(automatic.micUtterances))
        XCTAssertEqual(lines(explicit.systemUtterances), lines(automatic.systemUtterances))
        XCTAssertEqual(explicit.languageContext?.languageCode, "de")
    }

    // MARK: - Same fallbacks

    @MainActor
    func testReleasedMicStillCarriesAMeetingWhoseCallTrackIsUnreadable() async throws {
        let tracks = try makeTracks()
        try Data("not an audio file".utf8).write(to: tracks.system)

        let result = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: false))

        XCTAssertEqual(result.systemAudioOutcome, .unusable)
        XCTAssertEqual(result.microphoneAudioOutcome, .usable)
        XCTAssertTrue(result.systemUtterances.isEmpty)
        XCTAssertFalse(result.micUtterances.isEmpty)
    }

    @MainActor
    func testReleasedMicSTTFailureKeepsTheCallTranscript() async throws {
        let tracks = try makeTracks()
        let engine = DigestEchoEngine(scansLanguageWindows: false, failing: .microphone)

        let result = try await run(tracks, engine: engine)

        XCTAssertEqual(result.microphoneAudioOutcome, .unusable)
        XCTAssertTrue(result.micUtterances.isEmpty)
        XCTAssertFalse(result.systemUtterances.isEmpty)
    }

    @MainActor
    func testReleasedMicSTTFailureWithNoCallWordsThrowsTheMicError() async throws {
        let tracks = try makeTracks()
        let engine = DigestEchoEngine(scansLanguageWindows: false, failing: .microphone)

        do {
            _ = try await run(tracks, engine: engine, systemSegments: [])
            XCTFail("A mic failure with no call words must fail the job")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, DigestEchoEngine.errorDomain)
            XCTAssertEqual(error.code, 17)
        }
    }

    @MainActor
    func testSilentMicWithReleasePathGivesACallOnlyTranscript() async throws {
        let tracks = try makeTracks()
        try writeWAV(to: tracks.mic, samples: [Float](repeating: 0, count: 48_000 * 10))

        let result = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: false))

        XCTAssertEqual(result.microphoneAudioOutcome, .unusable)
        XCTAssertTrue(result.micUtterances.isEmpty)
        XCTAssertFalse(result.systemUtterances.isEmpty)
    }

    /// The mic file disappearing while the call track is processed only
    /// matters once the buffer is released: the mic side then degrades like
    /// any other mic failure and the call transcript survives.
    @MainActor
    func testMicFileLostDuringTheCallPhaseKeepsTheCallTranscript() async throws {
        let tracks = try makeTracks()
        let result = try await run(
            tracks,
            engine: DigestEchoEngine(scansLanguageWindows: false),
            deletingDuringDiarization: tracks.mic
        )
        XCTAssertEqual(result.microphoneAudioOutcome, .unusable)
        XCTAssertTrue(result.micUtterances.isEmpty)
        XCTAssertFalse(result.systemUtterances.isEmpty)
    }

    @MainActor
    func testMicFileLostDuringTheCallPhaseWithNoCallWordsFailsTheJob() async throws {
        let tracks = try makeTracks()
        do {
            _ = try await run(
                tracks,
                engine: DigestEchoEngine(scansLanguageWindows: false),
                systemSegments: [],
                deletingDuringDiarization: tracks.mic
            )
            XCTFail("Losing the only track with words must fail the job")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    // MARK: - Same progress

    @MainActor
    func testReleasedMicKeepsTheProgressSequence() async throws {
        let tracks = try makeTracks()
        let heldProgress = ProgressLog()
        let releasedProgress = ProgressLog()

        _ = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: true), progress: heldProgress)
        _ = try await run(tracks, engine: DigestEchoEngine(scansLanguageWindows: false), progress: releasedProgress)

        let values = releasedProgress.values
        XCTAssertEqual(values, heldProgress.values)
        XCTAssertEqual(values.first, 0.0)
        XCTAssertEqual(Array(values.suffix(2)), [0.95, 1.0])
        XCTAssertEqual(values, values.sorted())
        let tenth = try XCTUnwrap(values.firstIndex(of: 0.10))
        let thirty = try XCTUnwrap(values.firstIndex(of: 0.30))
        XCTAssertLessThan(tenth, thirty)
        let micValues = values.filter { $0 > 0.65 && $0 <= 0.90 }
        XCTAssertFalse(micValues.isEmpty)
    }

    // MARK: - Fixtures

    private struct Tracks {
        let root: URL
        let mic: URL
        let system: URL
    }

    /// 10 s, 48 kHz tracks: two tone bursts on the mic with long pauses
    /// between them, and steady call audio.
    private func makeTracks() throws -> Tracks {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMicReleaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let rate = 48_000
        var mic = [Float](repeating: 0, count: rate * 10)
        for (start, end, hz) in [(1.0, 3.0, 310.0), (6.0, 8.5, 440.0)] {
            for i in Int(start * Double(rate))..<Int(end * Double(rate)) {
                mic[i] = Float(0.1 * sin(2 * Double.pi * hz * Double(i) / Double(rate)))
            }
        }
        let system = (0..<(rate * 10)).map { i in
            Float(0.08 * sin(2 * Double.pi * 220 * Double(i) / Double(rate)) + 0.02 * sin(2 * Double.pi * 530 * Double(i) / Double(rate)))
        }
        let tracks = Tracks(root: root, mic: root.appendingPathComponent("mic.wav"), system: root.appendingPathComponent("system.wav"))
        try writeWAV(to: tracks.mic, samples: mic)
        try writeWAV(to: tracks.system, samples: system)
        return tracks
    }

    private static let defaultSystemSegments = [
        SpeakerSegment(speakerId: 0, startTime: 0.5, endTime: 4.0, embedding: [1, 0], qualityScore: 0.95),
        SpeakerSegment(speakerId: 1, startTime: 5.0, endTime: 9.5, embedding: [0, 1], qualityScore: 0.95)
    ]

    @MainActor
    private func run(
        _ tracks: Tracks,
        engine: DigestEchoEngine,
        language: TranscriptionLanguageSelection = .automatic,
        systemSegments: [SpeakerSegment] = MeetingMicReleaseTests.defaultSystemSegments,
        deletingDuringDiarization: URL? = nil,
        progress: ProgressLog? = nil
    ) async throws -> TranscriptionResult {
        let dbRoot = tracks.root.appendingPathComponent("db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let transcription = Transcription(
            speechToText: engine,
            diarization: FixedSegmentDiarizer(segments: systemSegments, deleting: deletingDuringDiarization),
            speakerStore: SpeakerDatabase(path: dbRoot.appendingPathComponent("speakers.sqlite").path),
            speakerClipsDirectory: dbRoot.appendingPathComponent("clips")
        )
        var onProgress: ((Double) -> Void)?
        if let progress {
            onProgress = { value in progress.append(value) }
        }
        return try await transcription.transcribeMultichannel(
            micURL: tracks.mic,
            systemURL: tracks.system,
            languageSelection: language,
            onProgress: onProgress
        )
    }

    private func lines(_ utterances: [TranscriptionUtterance]) -> [String] {
        utterances.map { "\($0.channel)|\($0.start)|\($0.end)|\($0.transcript)" }
    }

    private func writeWAV(to url: URL, samples: [Float], sampleRate: Double = 48_000) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

/// Returns a digest of the exact samples it was handed, so equal transcripts
/// mean equal audio.
@available(macOS 14.0, *)
@MainActor
private final class DigestEchoEngine: SpeechToTextEngine {
    static let errorDomain = "MeetingMicReleaseTests.STT"
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    let usesRepresentativeLanguageSamples: Bool
    private let failing: AudioSource?

    init(scansLanguageWindows: Bool, failing: AudioSource? = nil) {
        self.usesRepresentativeLanguageSamples = scansLanguageWindows
        self.failing = failing
    }

    nonisolated static func digest(_ samples: [Float], source: AudioSource) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for sample in samples {
            var bits = sample.bitPattern
            for _ in 0..<4 {
                hash ^= UInt64(bits & 0xff)
                hash = hash &* 0x100000001b3
                bits >>= 8
            }
        }
        return "\(source == .microphone ? "mic" : "sys") n=\(samples.count) h=\(String(hash, radix: 16))"
    }

    func initialize() async { isReady = true }
    func cleanup() { isReady = false }

    func resolveLanguage(representativeSamples: [[Float]], selection: TranscriptionLanguageSelection) async throws -> TranscriptionLanguageContext {
        if case .explicit(let code) = selection {
            return .init(selection: selection, languageCode: code, resolution: .explicit)
        }
        return .init(selection: selection, languageCode: nil, resolution: .unsupported)
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        try transcribe(samples, source: source)
    }

    func transcribeSegment(samples: [Float], source: AudioSource, language: TranscriptionLanguageContext) async throws -> String {
        try transcribe(samples, source: source)
    }

    private func transcribe(_ samples: [Float], source: AudioSource) throws -> String {
        if source == failing { throw NSError(domain: Self.errorDomain, code: 17) }
        return Self.digest(samples, source: source)
    }
}

@available(macOS 14.0, *)
@MainActor
private final class FixedSegmentDiarizer: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private let segments: [SpeakerSegment]
    private let deleting: URL?

    init(segments: [SpeakerSegment], deleting: URL?) {
        self.segments = segments
        self.deleting = deleting
    }

    func initialize() async { isReady = true }
    func cleanup() { isReady = false }

    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        if let deleting { try? FileManager.default.removeItem(at: deleting) }
        return segments
    }

    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        try await diarizeOffline(samples: [], sampleRate: 16000)
    }
}
