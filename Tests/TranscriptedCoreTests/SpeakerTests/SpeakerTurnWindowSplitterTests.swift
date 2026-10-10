import XCTest
@testable import TranscriptedCore

/// Promises for splitting a long mixed turn from window embeddings: A then B
/// becomes two turns; a unimodal monologue stays one.
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
