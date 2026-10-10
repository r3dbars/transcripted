import Foundation
import XCTest
@testable import TranscriptedCore

/// Promise: the explanation for a numbered speaker never disagrees with the decision.
/// `silentNamingBlockers` is empty exactly when the no-lineup `shouldAutoAccept` names
/// the person, for both voiceprint models' bars, and it names the gates that failed.
final class SpeakerNamingBlockerTests: XCTestCase {
    func testBlockersAreEmptyExactlyWhenSilentNamingAccepts() {
        let names: [String?] = ["Fixture Person", nil, ""]
        let counts = [0, 1, 4, 5, 9]
        let disputes = [0, 1]
        let outcomes: [[SpeakerMatchOutcomeKind]] = [[], [.autoAccepted, .corrected]]
        let similarities = [0.80, 0.92, 0.93, 0.946, 0.95, 0.99]
        let runnerUps: [Double?] = [nil, -1, 0.70, 0.85, 0.90]
        let margins: [(best: Double, secondBest: Double)?] = [nil, (0.96, 0.70), (0.90, 0.85)]
        var checked = 0
        for thresholds in [SpeakerEmbeddingThresholds.weSpeaker, .reDimNet2B4] {
            for name in names { for count in counts { for dispute in disputes { for recent in outcomes {
                let profile = SpeakerProfile(
                    id: UUID(), displayName: name, nameSource: NameSource.userManual,
                    embedding: [1, 0], firstSeen: .distantPast, lastSeen: .distantPast,
                    callCount: 10, confidence: 0.9, disputeCount: dispute, confirmedMeetingCount: count
                )
                for similarity in similarities { for runnerUp in runnerUps { for margin in margins {
                    let accepts = SpeakerNamingPolicy.shouldAutoAccept(
                        profile: profile, similarity: similarity, secondBestSimilarity: runnerUp,
                        recentOutcomes: recent, marginSimilarities: margin, thresholds: thresholds)
                    let blockers = SpeakerNamingPolicy.silentNamingBlockers(
                        profile: profile, similarity: similarity, secondBestSimilarity: runnerUp,
                        recentOutcomes: recent, marginSimilarities: margin, thresholds: thresholds)
                    XCTAssertEqual(blockers.isEmpty, accepts, "\(name ?? "nil") \(count) \(dispute) \(similarity) \(String(describing: runnerUp)) \(blockers)")
                    checked += 1
                }}}
            }}}}
        }
        XCTAssertGreaterThan(checked, 1_000)
    }

    func testTwoConfirmationsIsTheOnlyBlockerForAStrongMatch() {
        let profile = SpeakerProfile(
            id: UUID(), displayName: "Fixture Person", nameSource: NameSource.userManual,
            embedding: [1, 0], firstSeen: .distantPast, lastSeen: .distantPast,
            callCount: 3, confidence: 0.9, disputeCount: 0, confirmedMeetingCount: 2
        )
        XCTAssertEqual(
            SpeakerNamingPolicy.silentNamingBlockers(
                profile: profile, similarity: 0.97, secondBestSimilarity: 0.70, recentOutcomes: [],
                marginSimilarities: (0.96, 0.70), thresholds: .reDimNet2B4),
            [.needsConfirmations(have: 2, need: 5)]
        )
    }

    func testReDimNet2BarIsStricterThanWeSpeakers() {
        let profile = SpeakerProfile(
            id: UUID(), displayName: "Fixture Person", nameSource: NameSource.userManual,
            embedding: [1, 0], firstSeen: .distantPast, lastSeen: .distantPast,
            callCount: 10, confidence: 0.9, disputeCount: 0, confirmedMeetingCount: 5
        )
        let at = { (thresholds: SpeakerEmbeddingThresholds) in
            SpeakerNamingPolicy.silentNamingBlockers(
                profile: profile, similarity: 0.93, secondBestSimilarity: -1, recentOutcomes: [],
                thresholds: thresholds)
        }
        XCTAssertEqual(at(.weSpeaker), [])
        XCTAssertEqual(at(.reDimNet2B4), [.similarityBelowBar(similarity: 0.93, bar: SpeakerEmbeddingThresholds.reDimNet2B4.autoAcceptSimilarity)])
    }

    func testLikelyNamingUsesTheInviteeSimilarityFloor() {
        XCTAssertEqual(SpeakerNamingPolicy.likelySimilarityFloor(thresholds: .reDimNet2B4), 0.815)
        XCTAssertEqual(SpeakerNamingPolicy.likelySimilarityFloor(thresholds: .weSpeaker), 0.80)
        let belowSilent = [SpeakerNamingBlocker.similarityBelowBar(similarity: 0.891, bar: 0.946)]
        XCTAssertTrue(SpeakerNamingPolicy.shouldNameAsLikely(blockers: belowSilent, thresholds: .reDimNet2B4))
        let belowFloor = [SpeakerNamingBlocker.similarityBelowBar(similarity: 0.814, bar: 0.946)]
        XCTAssertFalse(SpeakerNamingPolicy.shouldNameAsLikely(blockers: belowFloor, thresholds: .reDimNet2B4))
        let confirmations = [SpeakerNamingBlocker.needsConfirmations(have: 2, need: 5)]
        XCTAssertTrue(SpeakerNamingPolicy.shouldNameAsLikely(blockers: confirmations, thresholds: .reDimNet2B4))
        XCTAssertFalse(SpeakerNamingPolicy.shouldNameAsLikely(blockers: [.recentCorrections], thresholds: .reDimNet2B4))
        XCTAssertFalse(SpeakerNamingPolicy.shouldNameAsLikely(blockers: [], thresholds: .reDimNet2B4))
    }

    func testLikelyNamingRejectsAnAmbiguousRunnerUp() {
        // 0.891 vs 0.85: clears the invitee floor, but the 0.041 gap is
        // below ReDimNet2's inviteeMarginMin (0.106).
        let ambiguous: [SpeakerNamingBlocker] = [
            .similarityBelowBar(similarity: 0.891, bar: 0.946),
            .runnerUpTooClose(margin: 0.891 - 0.85, needed: 0.128),
        ]
        XCTAssertEqual(SpeakerEmbeddingThresholds.reDimNet2B4.inviteeMarginMin, 0.106)
        XCTAssertFalse(SpeakerNamingPolicy.shouldNameAsLikely(blockers: ambiguous, thresholds: .reDimNet2B4))
    }

    func testLikelyNamingAcceptsAClearRunnerUpMargin() {
        // 0.891 vs 0.70: same floor, 0.191 gap beats inviteeMarginMin.
        let clear: [SpeakerNamingBlocker] = [
            .similarityBelowBar(similarity: 0.891, bar: 0.946),
            .runnerUpTooClose(margin: 0.891 - 0.70, needed: 0.128),
        ]
        XCTAssertTrue(SpeakerNamingPolicy.shouldNameAsLikely(blockers: clear, thresholds: .reDimNet2B4))
    }
}
