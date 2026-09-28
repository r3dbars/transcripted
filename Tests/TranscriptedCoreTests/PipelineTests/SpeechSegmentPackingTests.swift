import XCTest
import Combine
import FluidAudio
@testable import TranscriptedCore

final class SpeechSegmentPackingTests: XCTestCase {

    func testLayoutPutsSilenceBetweenSegmentsAndRecordsRanges() {
        let layout = SpeechSegmentPacking.layout([[1, 1], [2, 2, 2], [3]], gapSamples: 2)
        XCTAssertEqual(layout.samples, [1, 1, 0, 0, 2, 2, 2, 0, 0, 3])
        XCTAssertEqual(layout.ranges, [0..<2, 4..<7, 9..<10])
    }

    func testSplitAssignsWholeWordsByFirstTokenStart() {
        // Segments at 0-2 s, 2.5-5 s, 5.5-7 s: boundaries at 2.25 s and 5.25 s.
        let ranges = [0..<32_000, 40_000..<80_000, 88_000..<112_000]
        let tokens = [
            TimedTranscriptToken(text: " Hello", startSeconds: 0.1),
            TimedTranscriptToken(text: " there", startSeconds: 1.0),
            // A word that starts just before a boundary keeps its tail.
            TimedTranscriptToken(text: " every", startSeconds: 2.2),
            TimedTranscriptToken(text: "one", startSeconds: 2.3),
            TimedTranscriptToken(text: " next", startSeconds: 2.6),
            TimedTranscriptToken(text: " last", startSeconds: 6.0),
            TimedTranscriptToken(text: "", startSeconds: 6.1),
            TimedTranscriptToken(text: ".", startSeconds: 6.4),
        ]
        XCTAssertEqual(
            SpeechSegmentPacking.split(tokens: tokens, ranges: ranges),
            ["Hello there everyone", "next", "last."]
        )
    }

    func testSplitSortsTokensAndLeavesSilentSegmentsEmpty() {
        let ranges = [0..<16_000, 24_000..<40_000, 48_000..<64_000]
        let tokens = [
            TimedTranscriptToken(text: " three", startSeconds: 3.2),
            TimedTranscriptToken(text: " one", startSeconds: 0.2),
        ]
        XCTAssertEqual(SpeechSegmentPacking.split(tokens: tokens, ranges: ranges), ["one", "", "three"])
        XCTAssertEqual(SpeechSegmentPacking.split(tokens: [], ranges: ranges), ["", "", ""])
        XCTAssertEqual(SpeechSegmentPacking.split(tokens: tokens, ranges: []), [])
    }

    func testSplitMatchesJoinedTextForASingleSegment() {
        let tokens = [
            TimedTranscriptToken(text: " It", startSeconds: 0),
            TimedTranscriptToken(text: "'s", startSeconds: 0.1),
            TimedTranscriptToken(text: " fine", startSeconds: 0.4),
        ]
        XCTAssertEqual(SpeechSegmentPacking.split(tokens: tokens, ranges: [0..<16_000]), ["It's fine"])
    }

    func testBatcherFillsWindowsInOrder() {
        var batcher = SpeechSegmentBatcher<Int>(windowSamples: 10, gapSamples: 1)
        var batches: [[Int]] = []
        for (item, count) in [(0, 4), (1, 4), (2, 4), (3, 12), (4, 3), (5, 3)] {
            batches += batcher.add(item, samples: Array(repeating: 0, count: count)).map { $0.map(\.item) }
        }
        batches += batcher.finish().map { $0.map(\.item) }
        // 4 + 1 + 4 = 9 fits; adding 2 would be 14. 12 is over the window, so
        // it goes alone and flushes what came before it.
        XCTAssertEqual(batches, [[0, 1], [2], [3], [4, 5]])
        XCTAssertTrue(batcher.finish().isEmpty)
    }

    func testZeroWindowMeansOneSegmentPerBatch() {
        var batcher = SpeechSegmentBatcher<Int>(windowSamples: 0)
        var batches: [[Int]] = []
        for item in 0..<3 {
            batches += batcher.add(item, samples: [1, 2]).map { $0.map(\.item) }
        }
        batches += batcher.finish().map { $0.map(\.item) }
        XCTAssertEqual(batches, [[0], [1], [2]])
    }

    @MainActor
    func testBatchUsesPackedCallAndFallsBackWhenItFails() async throws {
        let language = TranscriptionLanguageContext(selection: .automatic, languageCode: nil, resolution: .unsupported)
        let engine = PackingStubEngine()
        engine.packedResult = ["a", "b"]
        let packed = try await Transcription.transcribeSegmentBatch([[1], [2]], engine: engine, source: .system, language: language)
        XCTAssertEqual(packed, ["a", "b"])
        XCTAssertEqual(engine.packedCalls, 1)
        XCTAssertEqual(engine.singleCalls, 0)

        engine.packedError = true
        let fallback = try await Transcription.transcribeSegmentBatch([[1], [2]], engine: engine, source: .system, language: language)
        XCTAssertEqual(fallback, ["single1", "single2"])
        XCTAssertEqual(engine.singleCalls, 2)

        engine.packedError = false
        engine.packedResult = ["only one"]
        let wrongCount = try await Transcription.transcribeSegmentBatch([[1], [2]], engine: engine, source: .system, language: language)
        XCTAssertEqual(wrongCount, ["single1", "single2"], "a packed result that doesn't match the segments is not trusted")

        let single = try await Transcription.transcribeSegmentBatch([[7]], engine: engine, source: .system, language: language)
        XCTAssertEqual(single, ["single7"])
        XCTAssertEqual(engine.packedCalls, 3, "a batch of one never packs")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class PackingStubEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true
    var packedResult: [String]?
    var packedError = false
    var packedCalls = 0
    var singleCalls = 0

    var packedSegmentWindowSamples: Int? { 240_000 }

    func initialize() async {}

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        singleCalls += 1
        return "single\(Int(samples.first ?? 0))"
    }

    func transcribePackedSegments(
        _ segments: [[Float]],
        source: AudioSource,
        language: TranscriptionLanguageContext
    ) async throws -> [String]? {
        packedCalls += 1
        if packedError { throw NSError(domain: "PackingStub", code: 1) }
        return packedResult
    }

    func cleanup() {}
}
