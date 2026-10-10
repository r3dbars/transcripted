import XCTest
@testable import TranscriptedCore

/// Promises for splitting a long mixed turn from window embeddings: A then B
/// becomes two turns; a unimodal monologue stays one; a long meeting cannot
/// pay an unbounded 1 s window grid.
@available(macOS 14.0, *)
final class SpeakerTurnWindowSplitterTests: XCTestCase {

    func testMixedTurnSplitsAtTheVoiceChange() {
        let segment = SpeakerSegment(
            speakerId: 1,
            startTime: 0,
            endTime: 16,
            embedding: [0.7, 0.7],
            qualityScore: 0.9
        )
        let windows = stride(from: 0.0, through: 14.0, by: 1.0).map { start -> (Double, Double, [Float]) in
            let embedding: [Float] = start < 7.0 ? [1, 0] : [0, 1]
            return (start, start + 2, embedding)
        }
        let pieces = SpeakerTurnWindowSplitter.splitSegment(
            segment,
            windows: windows,
            nextSpeakerId: 2,
            maxBetween: 0.88
        )
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(Set(pieces.map(\.speakerId)), [1, 2])
        XCTAssertEqual(pieces[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(pieces[1].endTime, 16, accuracy: 0.01)
        XCTAssertGreaterThan(pieces[0].endTime, 6)
        XCTAssertLessThan(pieces[0].endTime, 10)
        XCTAssertEqual(pieces[0].endTime, pieces[1].startTime, accuracy: 0.01)
    }

    func testExactOneSecondOutlierPiecesAreAbsorbedInAMonologue() {
        // One flipped 2 s window at a 1 s hop yields a piece of exactly 1.0 s
        // (change point midway between window centers). Two such cough/laugh
        // windows in a 10 s monologue must not become a second speaker.
        let segment = SpeakerSegment(
            speakerId: 1,
            startTime: 0,
            endTime: 10,
            embedding: [1, 0],
            qualityScore: 0.9
        )
        let windows = stride(from: 0.0, through: 8.0, by: 1.0).map { start -> (Double, Double, [Float]) in
            let flipped = start == 3.0 || start == 7.0
            return (start, start + 2, flipped ? [0, 1] : [1, 0])
        }
        let pieces = SpeakerTurnWindowSplitter.splitSegment(
            segment,
            windows: windows,
            nextSpeakerId: 2,
            maxBetween: 0.88
        )
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].speakerId, 1)
        XCTAssertEqual(pieces[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(pieces[0].endTime, 10, accuracy: 0.01)
    }

    func testUnimodalLongTurnStaysOneSegment() {
        let segment = SpeakerSegment(
            speakerId: 3,
            startTime: 0,
            endTime: 16,
            embedding: [1, 0],
            qualityScore: 0.9
        )
        let windows = stride(from: 0.0, through: 14.0, by: 1.0).map { start -> (Double, Double, [Float]) in
            (start, start + 2, [1, 0])
        }
        let pieces = SpeakerTurnWindowSplitter.splitSegment(
            segment,
            windows: windows,
            nextSpeakerId: 4,
            maxBetween: 0.88
        )
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].speakerId, 3)
        XCTAssertEqual(pieces[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(pieces[0].endTime, 16, accuracy: 0.01)
    }

    func testAlternatingVoicesBecomeTwoIdsNotOneMixedTurn() {
        let segment = SpeakerSegment(
            speakerId: 1,
            startTime: 0,
            endTime: 16,
            embedding: [0.5, 0.5],
            qualityScore: 0.9
        )
        // 4 s of A, 4 s of B, 4 s of A, 4 s of B.
        let windows = stride(from: 0.0, through: 14.0, by: 1.0).map { start -> (Double, Double, [Float]) in
            let block = Int(start) / 4
            let embedding: [Float] = block % 2 == 0 ? [1, 0] : [0, 1]
            return (start, start + 2, embedding)
        }
        let pieces = SpeakerTurnWindowSplitter.splitSegment(
            segment,
            windows: windows,
            nextSpeakerId: 2,
            maxBetween: 0.88
        )
        XCTAssertGreaterThanOrEqual(pieces.count, 3)
        XCTAssertEqual(Set(pieces.map(\.speakerId)), [1, 2])
    }

    func testRefineWithAConstantEmbedderKeepsOneSpeaker() async {
        let embedder = TimeSplitEmbedder()
        let service = await MainActor.run { DiarizationService() }
        let samples = [Float](repeating: 0.01, count: 16_000 * 16)
        let segment = SpeakerSegment(
            speakerId: 1,
            startTime: 0,
            endTime: 16,
            embedding: nil,
            qualityScore: 0.9
        )
        let out = service.reembed(
            segments: [segment],
            samples: samples,
            sampleRate: 16_000,
            using: embedder
        )
        XCTAssertEqual(out.map(\.speakerId), [1])
        XCTAssertEqual(out.count, 1)
    }

    func testLongTurnUsesACappedWindowGrid() {
        let starts = SpeakerTurnWindowSplitter.windowStarts(startTime: 0, endTime: 60)
        XCTAssertLessThanOrEqual(starts.count, SpeakerTurnWindowSplitter.maxWindowsPerSegment)
        XCTAssertGreaterThanOrEqual(starts.count, SpeakerTurnWindowSplitter.minWindowsPerGroup * 2)
        XCTAssertEqual(starts.first ?? -1, 0, accuracy: 0.01)
        if starts.count >= 2 {
            XCTAssertGreaterThan(starts[1] - starts[0], SpeakerTurnWindowSplitter.hopSeconds)
        }
        let lastEnd = (starts.last ?? 0) + SpeakerTurnWindowSplitter.windowSeconds
        XCTAssertGreaterThanOrEqual(lastEnd + 1e-9, 60)
    }

    func testTypicalTurnKeepsAOneSecondHop() {
        let starts = SpeakerTurnWindowSplitter.windowStarts(startTime: 0, endTime: 9)
        XCTAssertGreaterThanOrEqual(starts.count, 4)
        XCTAssertLessThanOrEqual(starts.count, SpeakerTurnWindowSplitter.maxWindowsPerSegment)
        if starts.count >= 2 {
            XCTAssertEqual(starts[1] - starts[0], SpeakerTurnWindowSplitter.hopSeconds, accuracy: 0.05)
        }
    }

    func testRefineStopsAfterTheMeetingWindowBudget() async {
        let embedder = CountingEmbedder()
        let service = await MainActor.run { DiarizationService() }
        let turnCount = 12
        let turnSeconds = 20.0
        let samples = [Float](repeating: 0.01, count: 16_000 * Int(Double(turnCount) * turnSeconds))
        let segments = (0..<turnCount).map { index in
            SpeakerSegment(
                speakerId: 1,
                startTime: Double(index) * turnSeconds,
                endTime: Double(index) * turnSeconds + turnSeconds,
                embedding: nil,
                qualityScore: 0.9
            )
        }
        _ = service.reembed(
            segments: segments,
            samples: samples,
            sampleRate: 16_000,
            using: embedder
        )
        let windowEmbeds = embedder.embedCount - turnCount
        XCTAssertGreaterThan(windowEmbeds, 0)
        XCTAssertLessThanOrEqual(windowEmbeds, SpeakerTurnWindowSplitter.maxWindowsPerRefine)
    }

    func testRefineLeavesAShortTurnAlone() async {
        let embedder = TimeSplitEmbedder()
        let service = await MainActor.run { DiarizationService() }
        let samples = [Float](repeating: 0.01, count: 16_000 * 4)
        let segment = SpeakerSegment(
            speakerId: 5,
            startTime: 0,
            endTime: 4,
            embedding: [1, 0],
            qualityScore: 0.9
        )
        let out = service.reembed(
            segments: [segment],
            samples: samples,
            sampleRate: 16_000,
            using: embedder
        )
        XCTAssertEqual(out.map(\.speakerId), [5])
        XCTAssertEqual(out.count, 1)
    }

    final class CountingEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 2
        let identifier = "counting-stub"
        let thresholds = SpeakerEmbeddingThresholds.weSpeaker
        private let lock = NSLock()
        private(set) var embedCount = 0

        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            _ = (samples, sampleRate)
            lock.lock()
            embedCount += 1
            lock.unlock()
            return [1, 0]
        }
    }

    final class TimeSplitEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 2
        let identifier = "time-split-stub"
        let thresholds = SpeakerEmbeddingThresholds.weSpeaker

        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            // Slice-only embedder: length is all we see. Windows are 2 s, so
            // this path cannot split by time — refine should still use it
            // without crashing. Return a constant so short-turn tests stay 1 ID.
            _ = (samples, sampleRate)
            return [1, 0]
        }
    }
}

/// Contextual embedder that returns A for audio before 8 s and B after.
@available(macOS 14.0, *)
final class TimeSplitContextualEmbedder: ContextualSpeakerSegmentEmbedder, @unchecked Sendable {
    let dimension = 2
    let identifier = "time-split-contextual"
    let thresholds = SpeakerEmbeddingThresholds.weSpeaker

    func embed(samples: [Float], sampleRate: Int) -> [Float]? {
        _ = (samples, sampleRate)
        return [1, 0]
    }

    func embed(audio: [Float], sampleRate: Int, startSample: Int, endSample: Int) -> [Float]? {
        _ = audio
        let mid = (startSample + endSample) / 2
        return mid < 8 * sampleRate ? [1, 0] : [0, 1]
    }
}

@available(macOS 14.0, *)
extension SpeakerTurnWindowSplitterTests {
    func testRefineUsesContextualEmbeddingsToSplitByTime() async {
        let embedder = TimeSplitContextualEmbedder()
        let service = await MainActor.run { DiarizationService() }
        let samples = [Float](repeating: 0.01, count: 16_000 * 16)
        let segment = SpeakerSegment(
            speakerId: 1,
            startTime: 0,
            endTime: 16,
            embedding: nil,
            qualityScore: 0.9
        )
        let out = service.reembed(
            segments: [segment],
            samples: samples,
            sampleRate: 16_000,
            using: embedder
        )
        XCTAssertEqual(Set(out.map(\.speakerId)).count, 2)
        XCTAssertGreaterThanOrEqual(out.count, 2)
    }
}
