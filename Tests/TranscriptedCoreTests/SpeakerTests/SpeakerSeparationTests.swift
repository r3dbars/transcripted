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

    func testANearSilentVoiceWithNoFingerprintStaysItsOwnSpeaker() {
        // Nothing says who voice 1 sounds like, so it must not go to whoever
        // talked most.
        let input = [seg(0, 0, 10, a), seg(1, 10, 11, nil), seg(2, 11, 70, b)]
        XCTAssertEqual(ids(SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(foldBelowSeconds: 5))), [0, 1, 2])
        XCTAssertEqual(ids(SpeakerSeparation.apply(input, options: .nemotronTuned(invitedPeople: nil))), [0, 1, 2])
    }

    func testAShortLineFromSomeoneElseKeepsItsOwnSpeaker() {
        // The hardware case: a real 3.4 s line from a third person, under the
        // 5 s fold, sounds like neither of the two people who talked more.
        let input = [seg(0, 0, 40, a), seg(1, 40, 43.4, c), seg(2, 43.4, 100, b)]
        for thresholds in [SpeakerEmbeddingThresholds.weSpeaker, .reDimNet2B4] {
            let output = SpeakerSeparation.apply(input, options: .nemotronTuned(invitedPeople: nil, thresholds: thresholds))
            XCTAssertEqual(ids(output), [0, 1, 2])
        }
    }

    func testAShortPieceOfSomeoneWhoTalkedMoreStillFolds() {
        // The fold floor only stops folds between voices that don't sound alike.
        let input = [seg(0, 0, 40, a), seg(1, 40, 43.4, a2), seg(2, 43.4, 100, b)]
        let output = SpeakerSeparation.apply(input, options: .nemotronTuned(invitedPeople: nil, thresholds: .reDimNet2B4))
        XCTAssertEqual(ids(output), [0, 0, 2])
    }

    func testAShortVoiceFoldsOnlyWhenItClearsTheFoldBar() {
        // Voice 1 is about 0.71 like voice 0: in under a 0.6 bar, out under a 0.8 bar.
        let halfway: [Float] = [0.7, 0, 0, 0.7]
        let input = [seg(0, 0, 40, a), seg(1, 40, 43, halfway), seg(2, 43, 100, b)]
        XCTAssertEqual(
            ids(SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(foldBelowSeconds: 5, foldSimilarity: 0.6))),
            [0, 0, 2]
        )
        XCTAssertEqual(
            ids(SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(foldBelowSeconds: 5, foldSimilarity: 0.8))),
            [0, 1, 2]
        )
    }

    func testAOneOnOneCapNeverCollapsesADifferentPersonIntoTheInvitee() {
        // A 1:1 on the calendar, but a third person is on the call (or it's a
        // different call in the 1:1's slot). Voice 1 is another piece of voice 0
        // and folds; voice 2 sounds like nobody and stays, even though that leaves
        // two voices under a cap of one.
        let input = [seg(0, 0, 60, a), seg(1, 60, 80, a2), seg(2, 80, 88, b)]
        for thresholds in [SpeakerEmbeddingThresholds.weSpeaker, .reDimNet2B4] {
            let output = SpeakerSeparation.apply(input, options: .nemotronTuned(invitedPeople: 1, thresholds: thresholds))
            XCTAssertEqual(ids(output), [0, 0, 2])
        }
    }

    func testACapWithABarKeepsAVoiceWithNoFingerprint() {
        let input = [seg(0, 0, 60, a), seg(1, 60, 70, nil)]
        let output = SpeakerSeparation.apply(input, options: SpeakerSeparationOptions(maxSpeakers: 1, capFoldSimilarity: 0.6))
        XCTAssertEqual(ids(output), [0, 1])
    }

    func testAOneOnOneWithOnlyTheInviteeStillEndsWithOneVoice() {
        // What the 1:1 cap is for: Nemotron split one remote person in two.
        let input = [seg(0, 0, 60, a), seg(1, 60, 75, a2)]
        let output = SpeakerSeparation.apply(input, options: .nemotronTuned(invitedPeople: 1, thresholds: .reDimNet2B4))
        XCTAssertEqual(Set(ids(output)), [0])
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
        XCTAssertEqual(options.foldSimilarity, Double(SpeakerEmbeddingThresholds.weSpeaker.microAbsorb))
        XCTAssertEqual(options.capFoldSimilarity, SpeakerEmbeddingThresholds.weSpeaker.separationMerge)
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

    func testFoldAndCapBarsComeFromTheActiveVoiceprintModel() {
        let thresholds = SpeakerEmbeddingThresholds.reDimNet2B4
        let options = SpeakerSeparationOptions.tuned(for: .nemotron, invitedPeople: 1, thresholds: thresholds)
        XCTAssertEqual(options.foldSimilarity, Double(thresholds.microAbsorb))
        XCTAssertEqual(options.capFoldSimilarity, thresholds.separationMerge)
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
