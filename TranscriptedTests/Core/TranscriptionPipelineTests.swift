import XCTest
@testable import Transcripted

@available(macOS 26.0, *)
final class TranscriptionPipelineTests: XCTestCase {

    // MARK: - mergeConsecutiveUtterances: Empty & Single

    func testMergeEmptyArray() {
        let result = Transcription.mergeConsecutiveUtterances([], maxGap: 1.5)
        XCTAssertTrue(result.isEmpty, "Merging an empty array should return an empty array")
    }

    func testMergeSingleUtterance() {
        let single = TranscriptionUtterance.mock(start: 0, end: 5, transcript: "Hello")
        let result = Transcription.mergeConsecutiveUtterances([single], maxGap: 1.5)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 5)
        XCTAssertEqual(result[0].transcript, "Hello")
    }

    // MARK: - mergeConsecutiveUtterances: Same Speaker Merging

    func testMergeSameSpeakerSmallGap() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "Hello")
        let u2 = TranscriptionUtterance.mock(start: 3.5, end: 6, speakerId: 1, transcript: "world")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 1, "Same speaker with small gap should merge into one utterance")
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 6)
        XCTAssertEqual(result[0].transcript, "Hello world")
        XCTAssertEqual(result[0].speakerId, 1)
    }

    func testMergeDifferentSpeakersNotMerged() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "Hello")
        let u2 = TranscriptionUtterance.mock(start: 3.5, end: 6, speakerId: 2, transcript: "Hi there")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 2, "Different speakers should not be merged")
        XCTAssertEqual(result[0].transcript, "Hello")
        XCTAssertEqual(result[1].transcript, "Hi there")
    }

    func testMergeSameSpeakerLargeGap() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "First")
        let u2 = TranscriptionUtterance.mock(start: 5.0, end: 8, speakerId: 1, transcript: "Second")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 2, "Same speaker with gap >= maxGap should not merge")
        XCTAssertEqual(result[0].transcript, "First")
        XCTAssertEqual(result[1].transcript, "Second")
    }

    func testMergeSameSpeakerDifferentChannel() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, channel: 0, speakerId: 1, transcript: "Mic")
        let u2 = TranscriptionUtterance.mock(start: 3.5, end: 6, channel: 1, speakerId: 1, transcript: "System")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 2, "Same speaker on different channels should not merge")
        XCTAssertEqual(result[0].channel, 0)
        XCTAssertEqual(result[1].channel, 1)
    }

    func testMergeThreeConsecutiveSameSpeaker() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "One")
        let u2 = TranscriptionUtterance.mock(start: 3.5, end: 6, speakerId: 1, transcript: "two")
        let u3 = TranscriptionUtterance.mock(start: 6.2, end: 9, speakerId: 1, transcript: "three")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2, u3], maxGap: 1.5)

        XCTAssertEqual(result.count, 1, "Three consecutive utterances from same speaker should merge into one")
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 9)
        XCTAssertEqual(result[0].transcript, "One two three")
    }

    // MARK: - mergeConsecutiveUtterances: Duration Cap

    func testMergeDurationCapStopsMerge() {
        // Two utterances whose combined span would exceed maxDuration
        let u1 = TranscriptionUtterance.mock(start: 0, end: 20, speakerId: 1, transcript: "Long speech")
        let u2 = TranscriptionUtterance.mock(start: 20.5, end: 31.0, speakerId: 1, transcript: "More speech")
        // Combined duration: 31.0 - 0 = 31s, exceeds 30s cap
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5, maxDuration: 30.0)

        XCTAssertEqual(result.count, 2, "Combined duration exceeding maxDuration should prevent merge")
    }

    func testMergeDurationCapBoundaryAllowed() {
        // Combined duration exactly at maxDuration (uses <=)
        let u1 = TranscriptionUtterance.mock(start: 0, end: 20, speakerId: 1, transcript: "First part")
        let u2 = TranscriptionUtterance.mock(start: 20.5, end: 30.0, speakerId: 1, transcript: "Second part")
        // Combined duration: 30.0 - 0 = 30s, exactly at cap
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5, maxDuration: 30.0)

        XCTAssertEqual(result.count, 1, "Combined duration exactly at maxDuration should still merge (uses <=)")
        XCTAssertEqual(result[0].transcript, "First part Second part")
    }

    // MARK: - mergeConsecutiveUtterances: Gap Boundary

    func testMergeGapBoundaryNotMerged() {
        // Gap exactly at maxGap -- uses strict < so should NOT merge
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "First")
        let u2 = TranscriptionUtterance.mock(start: 4.5, end: 7, speakerId: 1, transcript: "Second")
        // Gap: 4.5 - 3.0 = 1.5, which is NOT < 1.5
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 2, "Gap exactly equal to maxGap should NOT merge (uses strict <)")
    }

    // MARK: - mergeConsecutiveUtterances: Persistent ID & Similarity Coalescing

    func testMergePersistentIdPrefersCurrentOverNext() {
        let currentId = UUID()
        let nextId = UUID()
        let u1 = TranscriptionUtterance.mock(
            start: 0, end: 3, speakerId: 1,
            persistentSpeakerId: currentId, transcript: "First"
        )
        let u2 = TranscriptionUtterance.mock(
            start: 3.5, end: 6, speakerId: 1,
            persistentSpeakerId: nextId, transcript: "Second"
        )
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].persistentSpeakerId, currentId,
                       "Merged utterance should prefer current's persistentSpeakerId over next's")
    }

    func testMergeMatchSimilarityPrefersCurrentOverNext() {
        let u1 = TranscriptionUtterance.mock(
            start: 0, end: 3, speakerId: 1,
            matchSimilarity: 0.85, transcript: "First"
        )
        let u2 = TranscriptionUtterance.mock(
            start: 3.5, end: 6, speakerId: 1,
            matchSimilarity: 0.92, transcript: "Second"
        )
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].matchSimilarity, 0.85,
                       "Merged utterance should prefer current's matchSimilarity over next's")
    }

    // MARK: - mergeConsecutiveUtterances: Mixed Speaker Patterns

    func testMergeMixedSpeakersAABB() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "A1")
        let u2 = TranscriptionUtterance.mock(start: 3.5, end: 6, speakerId: 1, transcript: "A2")
        let u3 = TranscriptionUtterance.mock(start: 7, end: 10, speakerId: 2, transcript: "B1")
        let u4 = TranscriptionUtterance.mock(start: 10.5, end: 13, speakerId: 2, transcript: "B2")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2, u3, u4], maxGap: 1.5)

        XCTAssertEqual(result.count, 2, "AABB pattern should merge each pair separately")
        XCTAssertEqual(result[0].speakerId, 1)
        XCTAssertEqual(result[0].transcript, "A1 A2")
        XCTAssertEqual(result[1].speakerId, 2)
        XCTAssertEqual(result[1].transcript, "B1 B2")
    }

    func testMergeAlternatingABA() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "A1")
        let u2 = TranscriptionUtterance.mock(start: 3.5, end: 6, speakerId: 2, transcript: "B1")
        let u3 = TranscriptionUtterance.mock(start: 6.5, end: 9, speakerId: 1, transcript: "A2")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2, u3], maxGap: 1.5)

        XCTAssertEqual(result.count, 3, "Alternating speakers A-B-A should produce no merges")
        XCTAssertEqual(result[0].speakerId, 1)
        XCTAssertEqual(result[1].speakerId, 2)
        XCTAssertEqual(result[2].speakerId, 1)
    }

    // MARK: - mergeConsecutiveUtterances: Long Chain with Duration Cap

    func testMergeLongChainWithDurationCap() {
        // 20 utterances, each 2s, with 0.5s gaps. maxDuration = 30s should cap merging.
        var utterances: [TranscriptionUtterance] = []
        for i in 0..<20 {
            let start = Double(i) * 2.5  // 2s speech + 0.5s gap
            let end = start + 2.0
            utterances.append(TranscriptionUtterance.mock(
                start: start, end: end, speakerId: 1,
                transcript: "Segment \(i)"
            ))
        }

        let result = Transcription.mergeConsecutiveUtterances(utterances, maxGap: 1.5, maxDuration: 30.0)

        // Each merged utterance can span at most 30s. With 2.5s per utterance cycle,
        // that's about 12 utterances per merged group (12 * 2.5 = 30s span).
        // 20 utterances should produce at least 2 merged groups.
        XCTAssertGreaterThan(result.count, 1, "Duration cap should prevent all 20 utterances from merging into one")
        XCTAssertLessThan(result.count, 20, "Adjacent utterances with small gaps should merge")

        // Verify no merged utterance exceeds the duration cap
        for utterance in result {
            let duration = utterance.end - utterance.start
            XCTAssertLessThanOrEqual(duration, 30.0 + 0.001,
                                     "No merged utterance should exceed maxDuration of 30s")
        }
    }

    // MARK: - mergeConsecutiveUtterances: Whitespace Trimming

    func testMergeTrimsWhitespace() {
        let u1 = TranscriptionUtterance.mock(start: 0, end: 3, speakerId: 1, transcript: "  Hello  ")
        let u2 = TranscriptionUtterance.mock(start: 3.5, end: 6, speakerId: 1, transcript: "  world  ")
        let result = Transcription.mergeConsecutiveUtterances([u1, u2], maxGap: 1.5)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].transcript, "Hello world",
                       "Merged transcript should trim leading/trailing whitespace from each part")
        // Ensure no double spaces or leading/trailing whitespace in result
        XCTAssertFalse(result[0].transcript.hasPrefix(" "), "Result should not have leading whitespace")
        XCTAssertFalse(result[0].transcript.hasSuffix(" "), "Result should not have trailing whitespace")
        XCTAssertFalse(result[0].transcript.contains("  "), "Result should not have double spaces")
    }

    // MARK: - embeddingWeight

    func testEmbeddingWeightClean() {
        // 0.0 mic fraction = completely clean system audio
        let weight = Transcription.embeddingWeight(forMicFraction: 0.0)
        XCTAssertEqual(weight, 1.0, "0% mic overlap should return weight 1.0 (clean)")
    }

    func testEmbeddingWeightLow() {
        // 0.2 mic fraction = still in the <0.3 range
        let weight = Transcription.embeddingWeight(forMicFraction: 0.2)
        XCTAssertEqual(weight, 1.0, "20% mic overlap should return weight 1.0 (clean)")
    }

    func testEmbeddingWeightModerate() {
        // 0.35 mic fraction = in the 0.3-0.5 range
        let weight = Transcription.embeddingWeight(forMicFraction: 0.35)
        XCTAssertEqual(weight, 0.5, "35% mic overlap should return weight 0.5 (moderate contamination)")
    }

    func testEmbeddingWeightHigh() {
        // 0.6 mic fraction = in the 0.5-0.8 range
        let weight = Transcription.embeddingWeight(forMicFraction: 0.6)
        XCTAssertEqual(weight, 0.2, "60% mic overlap should return weight 0.2 (heavy contamination)")
    }

    func testEmbeddingWeightExcluded() {
        // 0.85 mic fraction = above 0.8 threshold
        let weight = Transcription.embeddingWeight(forMicFraction: 0.85)
        XCTAssertNil(weight, "85% mic overlap should return nil (excluded)")
    }

    // MARK: - embeddingWeight: Boundary values

    func testEmbeddingWeightAtExactly0Point3() {
        // 0.3 is in the 0.3... range (Swift range pattern)
        let weight = Transcription.embeddingWeight(forMicFraction: 0.3)
        XCTAssertEqual(weight, 0.5, "Exactly 0.3 should return 0.5 (matches 0.3... range)")
    }

    func testEmbeddingWeightAtExactly0Point5() {
        // 0.5 is in the 0.5... range
        let weight = Transcription.embeddingWeight(forMicFraction: 0.5)
        XCTAssertEqual(weight, 0.2, "Exactly 0.5 should return 0.2 (matches 0.5... range)")
    }

    func testEmbeddingWeightAtExactly0Point8() {
        // 0.8 is NOT > 0.8, so it should match the 0.5... range
        let weight = Transcription.embeddingWeight(forMicFraction: 0.8)
        XCTAssertEqual(weight, 0.2, "Exactly 0.8 should return 0.2 (not excluded; 0.8 is not > 0.8)")
    }

    // MARK: - detectSpeechSegments: Edge Cases

    func testDetectVeryShortBurstFiltered() {
        // A very short speech burst (< 0.5s) surrounded by silence should be filtered out.
        // The method has minSegmentDuration = 0.5s.
        var samples: [Float] = []
        samples += TestAudioGenerator.silence(duration: 1.0)
        samples += TestAudioGenerator.tone(duration: 0.3, amplitude: 0.5)  // 300ms burst -- too short
        samples += TestAudioGenerator.silence(duration: 1.0)

        let segments = Transcription.detectSpeechSegments(samples: samples, sampleRate: 16000)

        // The short burst should be filtered. Fallback returns a single full-track segment
        // when no valid segments are detected.
        XCTAssertEqual(segments.count, 1, "Very short burst should be filtered; fallback returns one segment")
        // The fallback segment covers the entire track
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.01)
        let expectedEnd = Double(samples.count) / 16000.0
        XCTAssertEqual(segments[0].end, expectedEnd, accuracy: 0.01)
    }

    func testDetectConstantNoiseReturnsSingleSegment() {
        // All samples above threshold -- should return a single continuous segment
        let samples = TestAudioGenerator.tone(duration: 5.0, amplitude: 0.5)
        let segments = Transcription.detectSpeechSegments(samples: samples, sampleRate: 16000)

        XCTAssertEqual(segments.count, 1, "Constant noise above threshold should yield one segment")
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.05)
        XCTAssertEqual(segments[0].end, 5.0, accuracy: 0.1)
    }

    func testDetectSegmentBoundariesChronological() {
        // Create multiple speech segments with clear silence gaps
        var samples: [Float] = []
        samples += TestAudioGenerator.tone(duration: 1.5, amplitude: 0.5)
        samples += TestAudioGenerator.silence(duration: 0.8)  // > 0.4s minSilenceDuration
        samples += TestAudioGenerator.tone(duration: 1.5, amplitude: 0.5)
        samples += TestAudioGenerator.silence(duration: 0.8)
        samples += TestAudioGenerator.tone(duration: 1.5, amplitude: 0.5)

        let segments = Transcription.detectSpeechSegments(samples: samples, sampleRate: 16000)

        XCTAssertGreaterThanOrEqual(segments.count, 2,
                                    "Multiple speech regions separated by silence should produce multiple segments")

        // Verify chronological ordering
        for i in 1..<segments.count {
            XCTAssertGreaterThan(segments[i].start, segments[i - 1].start,
                                 "Segment \(i) start should be after segment \(i - 1) start")
            XCTAssertGreaterThanOrEqual(segments[i].start, segments[i - 1].end,
                                        "Segment \(i) should not overlap with segment \(i - 1)")
        }

        // Verify all segments have positive duration
        for (index, segment) in segments.enumerated() {
            XCTAssertGreaterThan(segment.end, segment.start,
                                 "Segment \(index) should have positive duration")
        }
    }
}
