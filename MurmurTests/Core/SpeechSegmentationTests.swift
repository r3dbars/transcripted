import XCTest
@testable import Transcripted

@available(macOS 26.0, *)
final class SpeechSegmentationTests: XCTestCase {

    private let sampleRate: Double = 16000

    // MARK: - Basic segmentation

    func testEmptySamplesReturnsEmpty() {
        let segments = callDetect(samples: [])
        XCTAssertTrue(segments.isEmpty)
    }

    func testSilenceOnlyReturnsSingleSegment() {
        // 2 seconds of silence — should fall back to single full-track segment
        let samples = [Float](repeating: 0.0, count: Int(sampleRate * 2))
        let segments = callDetect(samples: samples)
        XCTAssertEqual(segments.count, 1)
    }

    func testContinuousSpeechReturnsSingleSegment() {
        // 3 seconds of loud audio (no silence gaps)
        let samples = generateTone(duration: 3.0, amplitude: 0.5)
        let segments = callDetect(samples: samples)
        XCTAssertEqual(segments.count, 1)
    }

    func testSpeechWithSilenceGapReturnsTwoSegments() {
        // 1s speech + 0.6s silence + 1s speech
        var samples: [Float] = []
        samples.append(contentsOf: generateTone(duration: 1.0, amplitude: 0.5))
        samples.append(contentsOf: [Float](repeating: 0.0, count: Int(sampleRate * 0.6)))
        samples.append(contentsOf: generateTone(duration: 1.0, amplitude: 0.5))

        let segments = callDetect(samples: samples)
        XCTAssertEqual(segments.count, 2)

        // First segment should start near 0 and end near 1.0
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.05)
        XCTAssertEqual(segments[0].end, 1.0, accuracy: 0.1)

        // Second segment should start near 1.6 and end near 2.6
        XCTAssertEqual(segments[1].start, 1.5, accuracy: 0.2)
        XCTAssertEqual(segments[1].end, 2.6, accuracy: 0.1)
    }

    func testShortSilenceGapDoesNotSplit() {
        // 1s speech + 0.2s silence (too short to split) + 1s speech
        var samples: [Float] = []
        samples.append(contentsOf: generateTone(duration: 1.0, amplitude: 0.5))
        samples.append(contentsOf: [Float](repeating: 0.0, count: Int(sampleRate * 0.2)))
        samples.append(contentsOf: generateTone(duration: 1.0, amplitude: 0.5))

        let segments = callDetect(samples: samples)
        XCTAssertEqual(segments.count, 1) // Short gap shouldn't split
    }

    func testMultipleSilenceGapsReturnsMultipleSegments() {
        // 3 speech segments with silence gaps
        var samples: [Float] = []
        for i in 0..<3 {
            samples.append(contentsOf: generateTone(duration: 1.0, amplitude: 0.5))
            if i < 2 {
                samples.append(contentsOf: [Float](repeating: 0.0, count: Int(sampleRate * 0.6)))
            }
        }

        let segments = callDetect(samples: samples)
        XCTAssertEqual(segments.count, 3)
    }

    func testSegmentsAreChronological() {
        var samples: [Float] = []
        for i in 0..<4 {
            samples.append(contentsOf: generateTone(duration: 0.8, amplitude: 0.5))
            if i < 3 {
                samples.append(contentsOf: [Float](repeating: 0.0, count: Int(sampleRate * 0.5)))
            }
        }

        let segments = callDetect(samples: samples)
        for i in 1..<segments.count {
            XCTAssertGreaterThan(segments[i].start, segments[i - 1].start)
            XCTAssertGreaterThanOrEqual(segments[i].start, segments[i - 1].end)
        }
    }

    // MARK: - Helpers

    /// Generate a simple tone (sine wave) for testing
    private func generateTone(duration: Double, amplitude: Float, frequency: Float = 440) -> [Float] {
        let count = Int(sampleRate * duration)
        return (0..<count).map { i in
            amplitude * sin(2 * .pi * frequency * Float(i) / Float(sampleRate))
        }
    }

    /// Call the private static method via the type
    private func callDetect(samples: [Float]) -> [(start: Double, end: Double)] {
        // Use Mirror to access private struct, or test through public interface
        // Since detectSpeechSegments is private, we test it indirectly through its effect
        // on mic transcription. But we made it private static, so we need a test helper.
        //
        // For now, we test the behavior observable through Transcription's public API.
        // The segmentation is also callable via the type for unit tests.

        // Access private method through @testable import
        let result = Transcription.detectSpeechSegments(samples: samples, sampleRate: sampleRate)
        return result.map { (start: $0.start, end: $0.end) }
    }
}
