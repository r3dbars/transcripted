import XCTest
@testable import TranscriptedCore

/// Guards the release-critical retune from #1493's findings: the multi-exemplar feature (#1488)
/// let a distinct speaker clear the auto-accept gate via ONE lucky exemplar (similarity 0.93–0.97,
/// best-vs-second margin 0.12–0.27), producing 12 silent mislabels on degraded AMI audio where the
/// average-only matcher had 0. The fix decouples the auto-accept MARGIN from the best-exemplar
/// score: keep best-of-exemplars for match SELECTION (the recall win), but judge the best-vs-second
/// margin against each profile's blended AVERAGE. A genuine owner is close on both average and best
/// exemplar (margin holds); a lucky-exemplar impostor is far from the average (margin collapses,
/// auto-accept withheld). See docs/speaker-eval-exemplar-delta-2026-07.md.
///
/// These are the in-tree, corpus-free proof of that behavior (the full A/B lives in
/// `SpeakerExemplarDeltaEvalTests`, which is XCTSkip'd without the 11 GB qmatrix corpus).
@available(macOS 14.0, *)
final class SpeakerAutoAcceptMarginTests: XCTestCase {

    private func matureProfile(
        _ name: String,
        embedding: [Float],
        exemplars: [[Float]] = [],
        callCount: Int = 10,
        disputeCount: Int = 0
    ) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            displayName: name,
            nameSource: NameSource.userManual,
            embedding: embedding,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: callCount,
            confidence: 0.9,
            disputeCount: disputeCount,
            exemplars: exemplars)
    }

    // MARK: - Policy gate, explicit scores

    /// The exact failure shape: best exemplar 0.95, exemplar runner-up 0.80 (legacy margin 0.15 ≥
    /// 0.12 → the pre-fix gate silently auto-names), but on the AVERAGE the winner is 0.60 and the
    /// runner-up 0.55 (avg margin 0.05 < 0.12). The retuned gate must withhold.
    func testLuckyExemplarImpostorRejectedByAverageMargin() {
        let profile = matureProfile("Alice", embedding: [1, 0, 0])

        // Pre-fix behavior (regression witness): best-exemplar margin waves the impostor through.
        XCTAssertTrue(
            SpeakerNamingPolicy.shouldAutoAccept(
                profile: profile, similarity: 0.95, secondBestSimilarity: 0.80),
            "pre-fix best-exemplar margin should have auto-accepted (this is the regression)")

        // Fixed behavior: the collapsed average margin withholds the auto-accept.
        XCTAssertFalse(
            SpeakerNamingPolicy.shouldAutoAccept(
                profile: profile, similarity: 0.95, secondBestSimilarity: 0.80,
                marginSimilarities: (best: 0.60, secondBest: 0.55)),
            "average-based margin (0.05) is below 0.12 → auto-accept must be withheld")
    }

    /// The genuine owner: same 0.95 best exemplar and 0.80 runner-up, but close to the profile on
    /// its AVERAGE too (0.93 vs 0.55 → avg margin 0.38). The retune must NOT cost this auto-name.
    func testGenuineOwnerStillAutoAcceptedUnderAverageMargin() {
        let profile = matureProfile("Alice", embedding: [1, 0, 0])
        XCTAssertTrue(
            SpeakerNamingPolicy.shouldAutoAccept(
                profile: profile, similarity: 0.95, secondBestSimilarity: 0.80,
                marginSimilarities: (best: 0.93, secondBest: 0.55)),
            "genuine owner is close on the average too → margin holds, auto-accept preserved")
    }

    /// Legacy single-average profiles (no exemplars) pass nil and behave exactly as before, so the
    /// change is a no-op off the exemplar path.
    func testNilMarginPreservesLegacyBehavior() {
        let profile = matureProfile("Alice", embedding: [1, 0, 0])
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile, similarity: 0.95, secondBestSimilarity: 0.80))
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile, similarity: 0.95, secondBestSimilarity: 0.90))   // margin 0.05
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile, similarity: 0.95, secondBestSimilarity: -1))     // no runner-up
    }

    // MARK: - Full match path: matchAgainstProfiles computes the average margin

    /// Constructs the fixture as real profiles + embedding and drives the production matcher: the
    /// impostor wins on a lucky exemplar (best-of-exemplars 1.0), a runner-up clears the floor on
    /// exemplar (0.85 → legacy margin 0.15), yet both sit low on the average (0.60 vs 0.55). The
    /// SnapshotMatchResult must carry the collapsed average margin, and the gate fed those values
    /// must withhold — while the legacy call on the same result would auto-name.
    func testMatchAgainstProfilesCarriesCollapsedAverageMargin() throws {
        let candidate: [Float] = [1, 0, 0]
        // Impostor target: far on the average (0.60), but one exemplar sits right on the candidate.
        let alice = matureProfile("Alice", embedding: [0.6, 0.8, 0], exemplars: [[1, 0, 0]])
        // Runner-up: clears the 0.70 floor on its exemplar (0.85) but is low on the average (0.55).
        let bob = matureProfile("Bob", embedding: [0.55, 0, 0.835], exemplars: [[0.85, 0.5268, 0]])

        let match = try XCTUnwrap(
            Transcription.matchAgainstProfiles(candidate, profiles: [alice, bob], threshold: 0.70))
        XCTAssertEqual(match.profileId, alice.id, "impostor wins match selection via the lucky exemplar")
        XCTAssertEqual(match.similarity, 1.0, accuracy: 1e-4, "best-of-exemplars score clears the 0.92 bar")
        XCTAssertEqual(match.secondBestSimilarity, 0.85, accuracy: 1e-4, "exemplar runner-up (legacy margin 0.15)")
        XCTAssertEqual(match.averageSimilarity, 0.60, accuracy: 1e-3, "winner is far on the average")
        XCTAssertEqual(match.secondBestAverageSimilarity, 0.55, accuracy: 1e-3, "runner-up is far on the average too")

        // Pre-fix gate (exemplar margin 1.0 − 0.85 = 0.15) auto-names the impostor.
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(
            profile: alice, similarity: match.similarity, secondBestSimilarity: match.secondBestSimilarity),
            "legacy margin on the same match would silently mislabel")

        // Retuned gate (average margin 0.60 − 0.55 = 0.05) withholds.
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(
            profile: alice, similarity: match.similarity, secondBestSimilarity: match.secondBestSimilarity,
            marginSimilarities: (best: match.averageSimilarity, secondBest: match.secondBestAverageSimilarity)),
            "average-based margin collapses → the fix withholds the auto-name")
    }

    /// The genuine owner through the same production matcher: high on both exemplar and average, so
    /// the average margin (0.95 − 0.55) stays wide and the auto-accept survives the retune.
    func testMatchAgainstProfilesGenuineOwnerStillAutoAccepts() throws {
        let candidate: [Float] = [1, 0, 0]
        let alice = matureProfile("Alice", embedding: [0.95, 0.3122, 0], exemplars: [[1, 0, 0]])
        let bob = matureProfile("Bob", embedding: [0.55, 0, 0.835], exemplars: [[0.85, 0.5268, 0]])

        let match = try XCTUnwrap(
            Transcription.matchAgainstProfiles(candidate, profiles: [alice, bob], threshold: 0.70))
        XCTAssertEqual(match.profileId, alice.id)
        XCTAssertEqual(match.averageSimilarity, 0.95, accuracy: 1e-3)
        XCTAssertEqual(match.secondBestAverageSimilarity, 0.55, accuracy: 1e-3)

        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(
            profile: alice, similarity: match.similarity, secondBestSimilarity: match.secondBestSimilarity,
            marginSimilarities: (best: match.averageSimilarity, secondBest: match.secondBestAverageSimilarity)),
            "genuine owner clears the average margin → auto-accept preserved")
    }
}
