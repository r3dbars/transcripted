import XCTest
@testable import TranscriptedCore

/// Promises for "split generously, then merge smartly" (SpeakerSeparation.swift):
/// the cleanup that runs on the call channel after the diarizer when the app turns
/// it on. Fingerprints here are tiny hand-made vectors: A and A2 point the same way
/// (one person), B and C point elsewhere (two other people).
final class SpeakerSeparationTests: XCTestCase {
    private let a: [Float] = [1, 0, 0, 0]
    private let a2: [Float] = [0.95, 0.05, 0, 0]
    private let b: [Float] = [0, 1, 0, 0]
    private let c: [Float] = [0, 0, 1, 0]

    private func seg(_ id: Int, _ start: Double, _ end: Double, _ embedding: [Float]?, quality: Float = 0.9) -> SpeakerSegment {
        SpeakerSegment(speakerId: id, startTime: start, endTime: end, embedding: embedding, qualityScore: quality)
    }

    private func ids(_ segments: [SpeakerSegment]) -> [Int] { segments.map(\.speakerId) }

    func testWithNothingTurnedOnSegmentsComeBackUnchanged() {
        let input = [seg(0, 0, 10, a), seg(1, 10, 11, a2), seg(2, 11, 30, b)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions())
        XCTAssertEqual(ids(output), [0, 1, 2])
    }

    func testANearSilentVoiceJoinsTheVoiceItSoundsLikeNotTheLoudestOne() {
        // Voice 1 talks for 2 s and sounds like voice 0; voice 2 talks the most.
        let input = [seg(0, 0, 20, a), seg(1, 20, 22, a2), seg(2, 22, 80, b)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(foldBelowSeconds: 5))
        XCTAssertEqual(ids(output), [0, 0, 2])
    }

    func testVoicesAboveTheFoldFloorAreLeftAlone() {
        let input = [seg(0, 0, 20, a), seg(1, 20, 30, a2), seg(2, 30, 60, b)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(foldBelowSeconds: 5))
        XCTAssertEqual(ids(output), [0, 1, 2])
    }

    func testLookAlikeVoicesMergeAndDifferentPeopleStayApart() {
        let input = [seg(0, 0, 20, a), seg(1, 20, 40, a2), seg(2, 40, 60, b), seg(3, 60, 80, c)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(mergeSimilarity: 0.6))
        XCTAssertEqual(Set(ids(output)).count, 3)
        XCTAssertEqual(output[0].speakerId, output[1].speakerId)
        XCTAssertNotEqual(output[2].speakerId, output[3].speakerId)
        XCTAssertNotEqual(output[0].speakerId, output[2].speakerId)
    }

    func testAMergeKeepsTheIdOfTheVoiceThatTalkedMore() {
        // Voice 1 talks longer than voice 0, so voice 1's id survives.
        let input = [seg(0, 0, 10, a), seg(1, 10, 50, a2)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(mergeSimilarity: 0.6))
        XCTAssertEqual(ids(output), [1, 1])
    }

    func testTheInviteCapFoldsTheQuietestVoicesFirst() {
        // Four voices, cap of two: the two quietest (3 and 2) fold away.
        let input = [seg(0, 0, 60, a), seg(1, 60, 110, b), seg(2, 110, 125, c), seg(3, 125, 130, [0, 0, 0, 1])]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(maxSpeakers: 2))
        XCTAssertEqual(Set(ids(output)), [0, 1])
    }

    func testACapOfOneLeavesOneVoice() {
        let input = [seg(0, 0, 60, a), seg(1, 60, 70, b), seg(2, 70, 75, c)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(maxSpeakers: 1))
        XCTAssertEqual(Set(ids(output)), [0])
    }

    func testOnlySpeakerIdsChangeNeverTimesEmbeddingsOrOrder() {
        let input = [seg(0, 0, 20, a), seg(1, 20, 21, a2, quality: 0.4), seg(2, 21, 50, b)]
        let output = SpeakerSeparation.apply(input, options: .labTuned(maxSpeakers: nil))
        XCTAssertEqual(output.count, input.count)
        for (x, y) in zip(input, output) {
            XCTAssertEqual(x.startTime, y.startTime)
            XCTAssertEqual(x.endTime, y.endTime)
            XCTAssertEqual(x.embedding, y.embedding)
            XCTAssertEqual(x.qualityScore, y.qualityScore)
        }
    }

    func testANearSilentVoiceWithNoFingerprintJoinsTheVoiceThatTalkedMost() {
        let input = [seg(0, 0, 10, a), seg(1, 10, 11, nil), seg(2, 11, 70, b)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(foldBelowSeconds: 5))
        XCTAssertEqual(ids(output), [0, 2, 2])
    }

    func testTheSameInputAlwaysGivesTheSameOutput() {
        let input = [seg(0, 0, 3, a), seg(1, 3, 4, a2), seg(2, 4, 40, b), seg(3, 40, 44, c), seg(4, 44, 90, a)]
        let first = SpeakerSeparation.apply(input, options: .labTuned(maxSpeakers: 2))
        let second = SpeakerSeparation.apply(input, options: .labTuned(maxSpeakers: 2))
        XCTAssertEqual(ids(first), ids(second))
    }

    func testTheInviteCapLeavesASpareSeatOnCallsOfThreeOrMore() {
        XCTAssertNil(SpeakerSeparationOptions.speakerCap(invitedPeople: 0))
        XCTAssertEqual(SpeakerSeparationOptions.speakerCap(invitedPeople: 1), 1)
        XCTAssertEqual(SpeakerSeparationOptions.speakerCap(invitedPeople: 2), 2)
        XCTAssertEqual(SpeakerSeparationOptions.speakerCap(invitedPeople: 3), 4)
        XCTAssertEqual(SpeakerSeparationOptions.speakerCap(invitedPeople: 7), 8)
    }

    func testLabTunedUsesTheLabSettings() {
        let options = SpeakerSeparationOptions.labTuned(maxSpeakers: 4)
        XCTAssertEqual(options.clusteringThreshold, 0.70)
        XCTAssertEqual(options.foldBelowSeconds, 5.0)
        XCTAssertEqual(options.mergeSimilarity, 0.6)
        XCTAssertEqual(options.maxSpeakers, 4)
    }

    func testNemotronFoldsTinyVoicesAndCapsOnlyOneOnOnes() {
        let noInvite = SpeakerSeparationOptions.tuned(for: .nemotron, invitedPeople: nil)
        XCTAssertNil(noInvite.clusteringThreshold)
        XCTAssertEqual(noInvite.foldBelowSeconds, 5.0)
        XCTAssertNil(noInvite.mergeSimilarity)
        XCTAssertNil(noInvite.maxSpeakers)
        XCTAssertEqual(SpeakerSeparationOptions.tuned(for: .nemotron, invitedPeople: 1).maxSpeakers, 1)
        XCTAssertNil(SpeakerSeparationOptions.tuned(for: .nemotron, invitedPeople: 5).maxSpeakers)
    }

    func testPyannoteKeepsTheLabSettingsWithTheInviteCap() {
        XCTAssertEqual(
            SpeakerSeparationOptions.tuned(for: .pyannote, invitedPeople: 3),
            SpeakerSeparationOptions.labTuned(maxSpeakers: 4)
        )
        XCTAssertEqual(
            SpeakerSeparationOptions.tuned(for: .pyannote, invitedPeople: nil),
            SpeakerSeparationOptions.labTuned(maxSpeakers: nil)
        )
    }
}
