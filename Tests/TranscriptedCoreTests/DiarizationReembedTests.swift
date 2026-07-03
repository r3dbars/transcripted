import XCTest
import Foundation
@testable import TranscriptedCore

/// Exercises DiarizationService.reembedIfNeeded — the per-segment re-embedding
/// bounds/slicing logic — directly with a stub embedder, without standing up the
/// real diarizer. Covers the no-embedder identity path, embedding replacement +
/// metadata preservation, correct slice lengths, embedder-returns-nil fallback,
/// out-of-bounds / zero-length / empty-samples safety.
@available(macOS 14.0, *)
final class DiarizationReembedTests: XCTestCase {

    /// Records the sample lengths it was asked to embed; returns a fixed result.
    final class StubEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 192
        let identifier = "stub"
        let thresholds: SpeakerEmbeddingThresholds
        let result: [Float]?
        private let lock = NSLock()
        private var _seen: [Int] = []
        var seenLengths: [Int] { lock.lock(); defer { lock.unlock() }; return _seen }
        init(result: [Float]?, thresholds: SpeakerEmbeddingThresholds = .weSpeaker) {
            self.result = result
            self.thresholds = thresholds
        }
        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            lock.lock(); _seen.append(samples.count); lock.unlock()
            return result
        }
    }

    private let dim192 = ERes2NetEmbedder.l2Normalize(Array(repeating: Float(0.1), count: 192))

    private func seg(_ s: Double, _ e: Double, dim: Int = 256) -> SpeakerSegment {
        SpeakerSegment(speakerId: 7, startTime: s, endTime: e,
                       embedding: Array(repeating: Float(0.5), count: dim), qualityScore: 0.9)
    }

    private func samples(_ seconds: Double) -> [Float] {
        Array(repeating: Float(0.01), count: Int(16000 * seconds))
    }

    func testNoEmbedderIsIdentity() async {
        let svc = await MainActor.run { DiarizationService() }
        let out = svc.reembedIfNeeded(segments: [seg(0, 2), seg(2, 4)], samples: samples(5), sampleRate: 16000)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map { $0.embedding?.count }, [256, 256])  // untouched WeSpeaker dim
    }

    func testReembedReplacesEmbeddingAndPreservesMetadata() async {
        let stub = StubEmbedder(result: dim192)
        let svc = await MainActor.run { DiarizationService(segmentEmbedder: stub) }
        let out = svc.reembedIfNeeded(segments: [seg(0, 2), seg(2, 4)], samples: samples(5), sampleRate: 16000)
        XCTAssertEqual(out.map { $0.embedding?.count }, [192, 192])
        XCTAssertEqual(out[0].startTime, 0); XCTAssertEqual(out[1].endTime, 4)
        XCTAssertEqual(out[0].speakerId, 7); XCTAssertEqual(out[0].qualityScore, 0.9)
        XCTAssertEqual(stub.seenLengths, [32000, 32000])  // 2s @ 16k each
    }

    func testEmbedderReturningNilDropsNativeEmbedding() async {
        // When an embedder is active, a failed re-embed must NOT keep the native
        // 256-d WeSpeaker vector — that would leak the wrong dimension into the
        // ERes2Net database. The segment survives for diarization with embedding=nil.
        let stub = StubEmbedder(result: nil)
        let svc = await MainActor.run { DiarizationService(segmentEmbedder: stub) }
        let out = svc.reembedIfNeeded(segments: [seg(0, 2)], samples: samples(5), sampleRate: 16000)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].embedding)         // native 256-d dropped, not leaked
        XCTAssertEqual(out[0].speakerId, 7)    // segment kept for diarization
    }

    func testOutOfBoundsTimesDropEmbeddingButKeepSegment() async {
        let stub = StubEmbedder(result: dim192)
        let svc = await MainActor.run { DiarizationService(segmentEmbedder: stub) }
        // seg fully past end -> embedding dropped; seg partially past end -> clamped + embedded.
        let out = svc.reembedIfNeeded(segments: [seg(10, 12), seg(0.5, 100)],
                                      samples: samples(1), sampleRate: 16000)
        XCTAssertEqual(out.count, 2)
        XCTAssertNil(out[0].embedding)                // beyond bounds -> dropped (no 256-d leak)
        XCTAssertEqual(out[1].embedding?.count, 192)  // clamped slice embedded
        XCTAssertEqual(stub.seenLengths, [8000])      // only the clamped 0.5s..end slice
    }

    func testZeroLengthSegmentDropsEmbedding() async {
        let stub = StubEmbedder(result: dim192)
        let svc = await MainActor.run { DiarizationService(segmentEmbedder: stub) }
        let out = svc.reembedIfNeeded(segments: [seg(1, 1)], samples: samples(5), sampleRate: 16000)
        XCTAssertNil(out[0].embedding)  // empty slice -> embedding dropped, segment kept
        XCTAssertTrue(stub.seenLengths.isEmpty)
    }

    func testEmptySamplesDropEmbedding() async {
        let stub = StubEmbedder(result: dim192)
        let svc = await MainActor.run { DiarizationService(segmentEmbedder: stub) }
        let out = svc.reembedIfNeeded(segments: [seg(0, 2)], samples: [], sampleRate: 16000)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].embedding)  // no audio -> embedding dropped, segment kept
    }

    func testEmptySegmentsReturnsEmpty() async {
        let stub = StubEmbedder(result: dim192)
        let svc = await MainActor.run { DiarizationService(segmentEmbedder: stub) }
        let out = svc.reembedIfNeeded(segments: [], samples: samples(5), sampleRate: 16000)
        XCTAssertTrue(out.isEmpty)
    }
}
