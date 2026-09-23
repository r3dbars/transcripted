import XCTest
@testable import TranscriptedCore

/// Pins `NemotronTurnBuilder`, the pure step that turns Nemotron 3 Diarization's
/// per-frame speaker probabilities into the exclusive speaker turns the meeting
/// pipeline transcribes one by one. No models involved.
final class NemotronTurnBuilderTests: XCTestCase {

    private let frameSeconds = 0.01

    /// Build frame-major probabilities from `(activeSlots, frameCount)` blocks.
    /// Slots missing from a block's dictionary are 0.
    private func probabilities(numSpeakers: Int, _ blocks: [([Int: Float], Int)]) -> [Float] {
        var out: [Float] = []
        for (active, count) in blocks {
            for _ in 0..<count {
                var row = [Float](repeating: 0, count: numSpeakers)
                for (slot, p) in active { row[slot] = p }
                out.append(contentsOf: row)
            }
        }
        return out
    }

    private func turns(
        numSpeakers: Int = 3,
        _ blocks: [([Int: Float], Int)]
    ) -> [NemotronSpeakerTurn] {
        let probs = probabilities(numSpeakers: numSpeakers, blocks)
        return NemotronTurnBuilder.turns(
            probabilities: probs,
            frameCount: probs.count / numSpeakers,
            numSpeakers: numSpeakers,
            frameSeconds: frameSeconds
        )
    }

    /// (speakerIndex, startFrame, endFrame) for compact assertions.
    private func shape(_ turns: [NemotronSpeakerTurn]) -> [[Int]] {
        turns.map { [$0.speakerIndex, $0.startFrame, $0.endFrame] }
    }

    private func assertExclusive(_ turns: [NemotronSpeakerTurn], file: StaticString = #filePath, line: UInt = #line) {
        for (previous, next) in zip(turns, turns.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.endFrame, next.startFrame, "turns overlap", file: file, line: line)
            XCTAssertLessThanOrEqual(previous.endTime, next.startTime, "turn times overlap", file: file, line: line)
        }
        for turn in turns {
            XCTAssertLessThan(turn.startFrame, turn.endFrame, file: file, line: line)
        }
    }

    // MARK: - Empty / silent

    func testEmptyAndDegenerateInputProduceNoTurns() {
        XCTAssertTrue(NemotronTurnBuilder.turns(probabilities: [], frameCount: 0, numSpeakers: 8, frameSeconds: 0.01).isEmpty)
        XCTAssertTrue(NemotronTurnBuilder.turns(probabilities: [], frameCount: 100, numSpeakers: 8, frameSeconds: 0.01).isEmpty)
        let probs = probabilities(numSpeakers: 3, [([0: 0.9], 100)])
        XCTAssertTrue(NemotronTurnBuilder.turns(probabilities: probs, frameCount: 0, numSpeakers: 3, frameSeconds: 0.01).isEmpty)
        XCTAssertTrue(NemotronTurnBuilder.turns(probabilities: probs, frameCount: 100, numSpeakers: 0, frameSeconds: 0.01).isEmpty)
        XCTAssertTrue(NemotronTurnBuilder.turns(probabilities: probs, frameCount: 100, numSpeakers: 3, frameSeconds: 0).isEmpty)
    }

    func testAllSilentFramesProduceNoTurns() {
        XCTAssertTrue(turns([([:], 500)]).isEmpty)
        XCTAssertTrue(turns([([0: 0.3, 1: 0.49], 500)]).isEmpty)  // below threshold everywhere
    }

    // MARK: - Basic turns

    func testSingleSpeakerTurnTimesAndQuality() {
        let result = turns([([:], 10), ([0: 0.9], 50)])
        XCTAssertEqual(shape(result), [[0, 10, 60]])
        XCTAssertEqual(result[0].startTime, 0.10, accuracy: 1e-9)
        XCTAssertEqual(result[0].endTime, 0.60, accuracy: 1e-9)
        XCTAssertEqual(result[0].duration, 0.50, accuracy: 1e-9)
        XCTAssertEqual(result[0].meanActiveProbability, 0.9, accuracy: 1e-5)
    }

    func testThresholdIsInclusiveAtHalf() {
        let result = turns([([0: 0.5], 30), ([0: 0.4999], 30), ([1: 0.5001], 30)])
        XCTAssertEqual(shape(result), [[0, 0, 30], [1, 60, 90]])
    }

    // MARK: - Overlap / exclusivity

    func testOverlapGoesToTheMoreConfidentSpeaker() {
        // A alone, then A (0.9) overlapping B (0.7), then B alone: A keeps the overlap.
        let aWins = turns([([0: 0.9], 50), ([0: 0.9, 1: 0.7], 50), ([1: 0.7], 50)])
        XCTAssertEqual(shape(aWins), [[0, 0, 100], [1, 100, 150]])
        assertExclusive(aWins)

        // Same layout but B is louder in the overlap: B takes it.
        let bWins = turns([([0: 0.9], 50), ([0: 0.9, 1: 0.95], 50), ([1: 0.7], 50)])
        XCTAssertEqual(shape(bWins), [[0, 0, 50], [1, 50, 150]])
        XCTAssertEqual(bWins[1].meanActiveProbability, 0.825, accuracy: 1e-5)
        assertExclusive(bWins)
    }

    func testThreeWayOverlapStaysExclusive() {
        let result = turns([
            ([0: 0.8], 40),
            ([0: 0.8, 1: 0.9, 2: 0.6], 40),
            ([0: 0.6, 2: 0.95], 40),
            ([2: 0.7], 40),
        ])
        XCTAssertEqual(shape(result), [[0, 0, 40], [1, 40, 80], [2, 80, 160]])
        assertExclusive(result)
    }

    func testTieGoesToLowerSlot() {
        // Slot 2 speaks first (becomes index 0), then slots 1 and 2 tie: slot 1 wins.
        let result = turns([([2: 0.8], 30), ([1: 0.8, 2: 0.8], 30)])
        XCTAssertEqual(shape(result), [[0, 0, 30], [1, 30, 60]])
    }

    // MARK: - Gap bridging

    func testShortSameSpeakerSilenceIsBridged() {
        // 28 frames = 0.28 s < 0.2874 s -> one turn.
        let bridged = turns([([0: 0.9], 30), ([:], 28), ([0: 0.9], 30)])
        XCTAssertEqual(shape(bridged), [[0, 0, 88]])
    }

    func testLongerSilenceIsNotBridged() {
        // 29 frames = 0.29 s >= 0.2874 s -> two turns of the same speaker.
        let split = turns([([0: 0.9], 30), ([:], 29), ([0: 0.9], 30)])
        XCTAssertEqual(shape(split), [[0, 0, 30], [0, 59, 89]])
    }

    func testDifferentSpeakersAreNeverBridged() {
        let result = turns([([0: 0.9], 30), ([:], 5), ([1: 0.9], 30)])
        XCTAssertEqual(shape(result), [[0, 0, 30], [1, 35, 65]])
    }

    func testMeanProbabilityIgnoresBridgedSilence() {
        // 0.6 for 30 frames, a 10-frame gap, 0.8 for 30 frames -> mean 0.7.
        let result = turns([([0: 0.6], 30), ([0: 0.1], 10), ([0: 0.8], 30)])
        XCTAssertEqual(shape(result), [[0, 0, 70]])
        XCTAssertEqual(result[0].meanActiveProbability, 0.7, accuracy: 1e-5)
    }

    // MARK: - Minimum duration

    func testTurnsShorterThanMinimumAreDropped() {
        // 24 frames = 0.24 s < 0.25 s -> dropped.
        let dropped = turns([([0: 0.9], 30), ([:], 40), ([1: 0.9], 24), ([:], 40)])
        XCTAssertEqual(shape(dropped), [[0, 0, 30]])

        // 25 frames = 0.25 s -> kept.
        let kept = turns([([0: 0.9], 30), ([:], 40), ([1: 0.9], 25), ([:], 40)])
        XCTAssertEqual(shape(kept), [[0, 0, 30], [1, 70, 95]])
    }

    func testDroppedBlipLetsTheSurroundingTurnRejoin() {
        // A, a 0.1 s flicker to B, A again: the blip is dropped and A is one turn.
        let result = turns([([0: 0.9], 50), ([1: 0.95], 10), ([0: 0.9], 50)])
        XCTAssertEqual(shape(result), [[0, 0, 110]])
        XCTAssertEqual(result[0].meanActiveProbability, 0.9, accuracy: 1e-5)
    }

    func testCustomParametersAreHonored() {
        let probs = probabilities(numSpeakers: 2, [([0: 0.9], 10), ([:], 50), ([0: 0.9], 10)])
        let result = NemotronTurnBuilder.turns(
            probabilities: probs,
            frameCount: 70,
            numSpeakers: 2,
            frameSeconds: 0.01,
            threshold: 0.95,
            maxBridgeGapSeconds: 1.0,
            minTurnSeconds: 0
        )
        XCTAssertTrue(result.isEmpty)  // 0.9 is below the custom threshold

        let loose = NemotronTurnBuilder.turns(
            probabilities: probs,
            frameCount: 70,
            numSpeakers: 2,
            frameSeconds: 0.01,
            threshold: 0.5,
            maxBridgeGapSeconds: 1.0,
            minTurnSeconds: 0
        )
        XCTAssertEqual(shape(loose), [[0, 0, 70]])
    }

    // MARK: - Index remapping

    func testSpeakerIndicesAreRemappedInFirstAppearanceOrder() {
        let result = turns(numSpeakers: 8, [([5: 0.9], 30), ([2: 0.9], 30), ([5: 0.9], 30), ([7: 0.9], 30)])
        XCTAssertEqual(shape(result), [[0, 0, 30], [1, 30, 60], [0, 60, 90], [2, 90, 120]])
        XCTAssertEqual(Set(result.map(\.speakerIndex)), [0, 1, 2])
    }

    // MARK: - Malformed input

    func testFewerProbabilitiesThanFramesUsesAvailableFrames() {
        let probs = probabilities(numSpeakers: 3, [([0: 0.9], 60)])
        let result = NemotronTurnBuilder.turns(probabilities: probs, frameCount: 100, numSpeakers: 3, frameSeconds: 0.01)
        XCTAssertEqual(shape(result), [[0, 0, 60]])
    }

    func testMoreProbabilitiesThanFramesUsesFrameCount() {
        let probs = probabilities(numSpeakers: 3, [([0: 0.9], 100)])
        let result = NemotronTurnBuilder.turns(probabilities: probs, frameCount: 40, numSpeakers: 3, frameSeconds: 0.01)
        XCTAssertEqual(shape(result), [[0, 0, 40]])
    }

    func testRaggedProbabilityCountIsTruncatedToWholeFrames() {
        var probs = probabilities(numSpeakers: 3, [([0: 0.9], 60)])
        probs.append(contentsOf: [0.9, 0.9])  // a partial 61st frame
        let result = NemotronTurnBuilder.turns(probabilities: probs, frameCount: 100, numSpeakers: 3, frameSeconds: 0.01)
        XCTAssertEqual(shape(result), [[0, 0, 60]])
    }

    func testNonFiniteProbabilitiesCountAsSilence() {
        let result = turns([([0: 0.9], 30), ([0: .nan], 40), ([0: 0.9], 30)])
        XCTAssertEqual(shape(result), [[0, 0, 30], [0, 70, 100]])
    }

    // MARK: - Frame helpers

    func testGapAndMinimumFrameConversions() {
        XCTAssertEqual(NemotronTurnBuilder.maxBridgeGapFrames(seconds: 0.2874, frameSeconds: 0.01), 28)
        XCTAssertEqual(NemotronTurnBuilder.maxBridgeGapFrames(seconds: 0.30, frameSeconds: 0.01), 29)  // "shorter than" is exclusive
        XCTAssertEqual(NemotronTurnBuilder.maxBridgeGapFrames(seconds: 0, frameSeconds: 0.01), 0)
        XCTAssertEqual(NemotronTurnBuilder.minTurnFrames(seconds: 0.25, frameSeconds: 0.01), 25)
        XCTAssertEqual(NemotronTurnBuilder.minTurnFrames(seconds: 0.251, frameSeconds: 0.01), 26)
        XCTAssertEqual(NemotronTurnBuilder.minTurnFrames(seconds: 0, frameSeconds: 0.01), 0)
    }
}
