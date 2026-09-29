import XCTest
@testable import TranscriptedCore

/// Every cosine bar the speaker stack compares a voiceprint against belongs to the
/// voiceprint model, not to the code. Promises:
/// - The WeSpeaker and ERes2Net presets keep exactly the bars the app ran with
///   before they became per-model, so today's behavior is unchanged.
/// - A calibration file may set any identity bar; one it leaves out keeps
///   WeSpeaker's value, and an impossible one is an error.
/// - A bar set that way changes the decision it names: the match guards, the
///   negative veto, voiceprint write-back, cluster fusion, exemplars, the naming
///   ladder, lineup naming, confidence, duplicate cleanup and separation merge.
@available(macOS 14.0, *)
final class SpeakerIdentityBarsTests: XCTestCase {

    // MARK: - Helpers

    /// A calibration file: WeSpeaker's nine match and clustering bars plus `identity`.
    private func calibrated(_ identity: [String: Double]) throws -> SpeakerEmbeddingThresholds {
        var object: [String: Any] = [
            "match_one_segment": 0.85, "match_few_segments": 0.78, "match_many_segments": 0.70,
            "ghost_merge_floor": 0.72, "consolidation": 0.88, "absorb": 0.72, "micro_absorb": 0.62,
            "per_segment_split": 0.62, "known_profile_conflict": 0.70,
        ]
        for (key, value) in identity { object[key] = value }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try SpeakerEmbeddingThresholds.decode(jsonData: data)
    }

    private func unit(_ values: [Float]) -> [Float] { SpeakerVectorMath.l2Normalize(values) }

    /// A unit vector whose cosine to the x axis is `cosine`, bent into `axis`.
    private func atCosine(_ cosine: Float, axis: Int, dimension: Int = 4) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[0] = cosine
        v[axis] = (1 - cosine * cosine).squareRoot()
        return v
    }

    private let xAxis: [Float] = [1, 0, 0, 0]

    private func person(_ name: String, confirmedMeetings: Int, callCount: Int = 10,
                        embedding: [Float] = [1, 0, 0, 0]) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(), displayName: name, nameSource: NameSource.userManual, embedding: embedding,
            firstSeen: Date(), lastSeen: Date(), callCount: callCount, confidence: 0.9,
            disputeCount: 0, confirmedMeetingCount: confirmedMeetings)
    }

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerIdentityBarsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
    }

    private func tempDBPath() -> String {
        tempDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    // MARK: - Presets keep today's bars

    func testWeSpeakerIdentityBarsAreTheValuesTheStackAlwaysUsed() {
        let t = SpeakerEmbeddingThresholds.weSpeaker
        XCTAssertEqual(t.immatureProfileMatchBonus, 0.08)
        XCTAssertEqual(t.developingProfileMatchBonus, 0.04)
        XCTAssertEqual(t.ambiguousMatchMargin, 0.05)
        XCTAssertEqual(t.negativeVetoFloor, 0.80)
        XCTAssertEqual(t.writeBackMarginMin, 0.12)
        XCTAssertEqual(t.confidentWriteBack, 0.80)
        XCTAssertEqual(t.cautiousWriteBack, 0.72)
        XCTAssertEqual(t.crossClusterLink, 0.78)
        XCTAssertEqual(t.exemplarSameCondition, 0.80)
        XCTAssertEqual(t.autoAcceptSimilarity, 0.92)
        XCTAssertEqual(t.autoAcceptMarginMin, 0.12)
        XCTAssertEqual(t.inviteeSimilarity, 0.80)
        XCTAssertEqual(t.inviteeMarginMin, 0.10)
        XCTAssertEqual(t.highConfidenceSimilarity, 0.85)
        XCTAssertEqual(t.duplicateProfileMerge, 0.6)
        XCTAssertEqual(t.separationMerge, 0.6)
    }

    /// ERes2Net always ran with the WeSpeaker-scale identity bars; it still does.
    func testERes2NetKeepsTheIdentityBarsItAlwaysRanWith() {
        let e = SpeakerEmbeddingThresholds.eRes2Net
        let w = SpeakerEmbeddingThresholds.weSpeaker
        XCTAssertEqual(e.immatureProfileMatchBonus, w.immatureProfileMatchBonus)
        XCTAssertEqual(e.developingProfileMatchBonus, w.developingProfileMatchBonus)
        XCTAssertEqual(e.ambiguousMatchMargin, w.ambiguousMatchMargin)
        XCTAssertEqual(e.negativeVetoFloor, w.negativeVetoFloor)
        XCTAssertEqual(e.writeBackMarginMin, w.writeBackMarginMin)
        XCTAssertEqual(e.confidentWriteBack, w.confidentWriteBack)
        XCTAssertEqual(e.cautiousWriteBack, w.cautiousWriteBack)
        XCTAssertEqual(e.crossClusterLink, w.crossClusterLink)
        XCTAssertEqual(e.exemplarSameCondition, w.exemplarSameCondition)
        XCTAssertEqual(e.autoAcceptSimilarity, w.autoAcceptSimilarity)
        XCTAssertEqual(e.autoAcceptMarginMin, w.autoAcceptMarginMin)
        XCTAssertEqual(e.inviteeSimilarity, w.inviteeSimilarity)
        XCTAssertEqual(e.inviteeMarginMin, w.inviteeMarginMin)
        XCTAssertEqual(e.highConfidenceSimilarity, w.highConfidenceSimilarity)
        XCTAssertEqual(e.duplicateProfileMerge, w.duplicateProfileMerge)
        XCTAssertEqual(e.separationMerge, w.separationMerge)
    }

    /// Callers without a model in hand read the policy constants; they are WeSpeaker's.
    func testPolicyConstantsAreTheWeSpeakerBars() {
        let w = SpeakerEmbeddingThresholds.weSpeaker
        XCTAssertEqual(SpeakerWritePathPolicy.writeBackMarginMin, w.writeBackMarginMin)
        XCTAssertEqual(SpeakerWritePathPolicy.confidentWriteBackSimilarity, w.confidentWriteBack)
        XCTAssertEqual(SpeakerWritePathPolicy.cautiousWriteBackSimilarity, w.cautiousWriteBack)
        XCTAssertEqual(SpeakerWritePathPolicy.crossClusterLinkFloor, w.crossClusterLink)
        XCTAssertEqual(SpeakerExemplarPolicy.sameConditionSimilarity, w.exemplarSameCondition)
        XCTAssertEqual(SpeakerNegativeExemplarPolicy.vetoFloor, w.negativeVetoFloor)
        XCTAssertEqual(SpeakerNamingPolicy.autoAcceptSimilarityThreshold, w.autoAcceptSimilarity)
        XCTAssertEqual(SpeakerNamingPolicy.autoAcceptMarginMin, w.autoAcceptMarginMin)
        XCTAssertEqual(SpeakerNamingPolicy.InviteeBars.labTuned,
                       SpeakerNamingPolicy.InviteeBars(requiredConfirmedMeetings: 2, similarity: 0.80, marginMin: 0.10))
        XCTAssertEqual(SpeakerNamingPolicy.InviteeBars.labTuned(for: .weSpeaker), .labTuned)
        XCTAssertEqual(SpeakerSeparationOptions.labTuned(maxSpeakers: nil).mergeSimilarity, 0.6)
    }

    func testADatabaseWithoutThresholdsUsesWeSpeakers() {
        XCTAssertEqual(SpeakerDatabase(path: tempDBPath()).thresholds, .weSpeaker)
    }

    // MARK: - Calibration files

    func testAFileWithoutIdentityBarsKeepsWeSpeakersIdentityBars() throws {
        let t = try calibrated([:])
        XCTAssertEqual(t, .weSpeaker)
    }

    func testAFileSetsIdentityBarsInSnakeOrCamelCase() throws {
        let t = try calibrated([
            "negative_veto_floor": 0.55, "confident_write_back": 0.61, "auto_accept_similarity": 0.70,
            "invitee_similarity": 0.58, "separation_merge": 0.44,
        ])
        XCTAssertEqual(t.negativeVetoFloor, 0.55)
        XCTAssertEqual(t.confidentWriteBack, 0.61)
        XCTAssertEqual(t.autoAcceptSimilarity, 0.70)
        XCTAssertEqual(t.inviteeSimilarity, 0.58)
        XCTAssertEqual(t.separationMerge, 0.44)
        // Untouched identity bars stay WeSpeaker's.
        XCTAssertEqual(t.cautiousWriteBack, SpeakerEmbeddingThresholds.weSpeaker.cautiousWriteBack)

        let camel = try calibrated(["crossClusterLink": 0.52, "duplicateProfileMerge": 0.49])
        XCTAssertEqual(camel.crossClusterLink, 0.52)
        XCTAssertEqual(camel.duplicateProfileMerge, 0.49)
    }

    func testAnImpossibleIdentityBarIsAnErrorNamingIt() {
        XCTAssertThrowsError(try calibrated(["exemplar_same_condition": 1.4])) { error in
            let message = (error as? SpeakerEmbeddingThresholdsFileError)?.message ?? ""
            XCTAssertTrue(message.contains("exemplarSameCondition"), message)
        }
    }

    // MARK: - Matching guards

    func testTheImmatureProfileBonusComesFromThresholds() throws {
        let candidate = xAxis
        let newcomer = person("New", confirmedMeetings: 0, callCount: 1, embedding: atCosine(0.75, axis: 1))
        // WeSpeaker: 0.70 floor + 0.08 = 0.78 > 0.75, so no match.
        XCTAssertNil(Transcription.matchAgainstProfiles(candidate, profiles: [newcomer], threshold: 0.70))
        let small = try calibrated(["immature_profile_match_bonus": 0.02])
        XCTAssertEqual(
            Transcription.matchAgainstProfiles(candidate, profiles: [newcomer], threshold: 0.70, thresholds: small)?.profileId,
            newcomer.id)
    }

    func testTheDevelopingProfileBonusComesFromThresholds() throws {
        let candidate = xAxis
        let developing = person("Dev", confirmedMeetings: 0, callCount: 3, embedding: atCosine(0.72, axis: 1))
        // WeSpeaker: 0.70 + 0.04 = 0.74 > 0.72.
        XCTAssertNil(Transcription.matchAgainstProfiles(candidate, profiles: [developing], threshold: 0.70))
        let small = try calibrated(["developing_profile_match_bonus": 0.01])
        XCTAssertNotNil(Transcription.matchAgainstProfiles(candidate, profiles: [developing], threshold: 0.70, thresholds: small))
    }

    func testTheAmbiguityMarginComesFromThresholds() throws {
        let candidate = xAxis
        let first = person("A", confirmedMeetings: 5, embedding: atCosine(0.90, axis: 1))
        let second = person("B", confirmedMeetings: 5, embedding: atCosine(0.87, axis: 2))
        // WeSpeaker: 0.03 apart is inside the 0.05 margin, so the match is ambiguous.
        XCTAssertNil(Transcription.matchAgainstProfiles(candidate, profiles: [first, second], threshold: 0.70))
        let narrow = try calibrated(["ambiguous_match_margin": 0.02])
        XCTAssertEqual(
            Transcription.matchAgainstProfiles(candidate, profiles: [first, second], threshold: 0.70, thresholds: narrow)?.profileId,
            first.id)
    }

    func testTheNegativeVetoFloorComesFromThresholds() throws {
        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(positiveSimilarity: 0.60, negativeSimilarity: 0.70))
        let low = try calibrated(["negative_veto_floor": 0.65])
        XCTAssertTrue(SpeakerNegativeExemplarPolicy.shouldVeto(
            positiveSimilarity: 0.60, negativeSimilarity: 0.70, thresholds: low))

        // The matcher uses the same floor: a candidate a bit closer to a rejected
        // sample (0.74) than to the person (0.72) is vetoed only under the lower floor.
        let owner = person("Owner", confirmedMeetings: 5, embedding: atCosine(0.72, axis: 1))
        let negatives = [owner.id: [atCosine(0.74, axis: 2)]]
        XCTAssertEqual(
            Transcription.matchAgainstProfiles(xAxis, profiles: [owner], threshold: 0.6,
                                               negativeExemplarsByProfile: negatives)?.profileId,
            owner.id)
        XCTAssertNil(Transcription.matchAgainstProfiles(
            xAxis, profiles: [owner], threshold: 0.6, negativeExemplarsByProfile: negatives, thresholds: low))
    }

    // MARK: - Write path

    func testWriteBackGatesComeFromThresholds() throws {
        // 0.66 is below WeSpeaker's cautious bar (0.72): frozen.
        XCTAssertEqual(SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.66, secondBestSimilarity: nil),
                       SpeakerWritePathPolicy.frozenBlendAlpha)
        let lowConfident = try calibrated(["confident_write_back": 0.60, "cautious_write_back": 0.50])
        XCTAssertEqual(SpeakerWritePathPolicy.voiceprintBlendAlpha(
            similarity: 0.66, secondBestSimilarity: nil, thresholds: lowConfident),
                       SpeakerWritePathPolicy.confidentBlendAlpha)
        let lowCautious = try calibrated(["confident_write_back": 0.70, "cautious_write_back": 0.60])
        XCTAssertEqual(SpeakerWritePathPolicy.voiceprintBlendAlpha(
            similarity: 0.66, secondBestSimilarity: nil, thresholds: lowCautious),
                       SpeakerWritePathPolicy.cautiousBlendAlpha)
    }

    func testTheWriteBackMarginComesFromThresholds() throws {
        // 0.08 to the runner-up is inside WeSpeaker's 0.12 margin: frozen.
        XCTAssertEqual(SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.95, secondBestSimilarity: 0.87),
                       SpeakerWritePathPolicy.frozenBlendAlpha)
        let narrow = try calibrated(["write_back_margin_min": 0.05])
        XCTAssertEqual(SpeakerWritePathPolicy.voiceprintBlendAlpha(
            similarity: 0.95, secondBestSimilarity: 0.87, thresholds: narrow),
                       SpeakerWritePathPolicy.confidentBlendAlpha)
    }

    func testClusterFusionUsesTheModelsLinkBar() throws {
        let profileId = UUID()
        func plan(_ thresholds: SpeakerEmbeddingThresholds) -> Transcription.CrossClusterLinkPlan {
            Transcription.planCrossClusterLinks(
                matchedProfileBySpeaker: [0: profileId, 1: profileId],
                matchSimilarityBySpeaker: [0: 0.90, 1: 0.80],
                meanBySpeaker: [0: xAxis, 1: atCosine(0.70, axis: 1)],
                segmentCountBySpeaker: [0: 5, 1: 5],
                thresholds: thresholds)
        }
        // Two clusters 0.70 apart: below WeSpeaker's 0.78 link bar, so the weaker one is spun off.
        XCTAssertEqual(plan(.weSpeaker).spinOffs, [1])
        XCTAssertFalse(SpeakerWritePathPolicy.shouldFuseMatchedClusters(crossClusterSimilarity: 0.70))

        let low = try calibrated(["cross_cluster_link": 0.65])
        XCTAssertEqual(plan(low).spinOffs, [])
        XCTAssertEqual(plan(low).remaps, [1: 0])
        XCTAssertTrue(SpeakerWritePathPolicy.shouldFuseMatchedClusters(crossClusterSimilarity: 0.70, thresholds: low))
    }

    func testTheExemplarSameConditionBarComesFromThresholds() throws {
        let newMean = atCosine(0.70, axis: 1)
        // 0.70 to the average is below WeSpeaker's 0.80: a new capture condition, stored.
        XCTAssertEqual(SpeakerExemplarPolicy.updated(current: [], newMean: newMean, average: xAxis).count, 1)
        let low = try calibrated(["exemplar_same_condition": 0.65])
        XCTAssertEqual(SpeakerExemplarPolicy.updated(current: [], newMean: newMean, average: xAxis, thresholds: low).count, 0)
    }

    /// The database decides exemplars with the bars it was opened with.
    func testTheDatabaseStoresExemplarsWithItsModelsBar() throws {
        func exemplarsAfterSecondCondition(_ db: SpeakerDatabase) -> Int? {
            let profile = db.addOrUpdateSpeaker(embedding: xAxis, existingId: nil)
            _ = db.addOrUpdateSpeaker(embedding: [0, 1, 0, 0], existingId: profile.id)
            return db.getSpeaker(id: profile.id)?.exemplars.count
        }
        XCTAssertEqual(exemplarsAfterSecondCondition(SpeakerDatabase(path: tempDBPath())), 1)
        let low = try calibrated(["exemplar_same_condition": 0.10])
        XCTAssertEqual(exemplarsAfterSecondCondition(SpeakerDatabase(path: tempDBPath(), thresholds: low)), 0)
    }

    func testDuplicateCleanupUsesTheDatabasesModelBar() throws {
        func survivors(_ db: SpeakerDatabase) -> Int {
            _ = db.addOrUpdateSpeaker(embedding: xAxis, existingId: nil)
            _ = db.addOrUpdateSpeaker(embedding: atCosine(0.80, axis: 1), existingId: nil)
            db.mergeDuplicates(protecting: [])
            return db.allSpeakers().count
        }
        // 0.80 apart clears WeSpeaker's 0.6 duplicate bar: merged into one.
        XCTAssertEqual(survivors(SpeakerDatabase(path: tempDBPath())), 1)
        let strict = try calibrated(["duplicate_profile_merge": 0.90])
        XCTAssertEqual(survivors(SpeakerDatabase(path: tempDBPath(), thresholds: strict)), 2)
    }

    // MARK: - Naming

    func testTheAutoAcceptLadderComesFromThresholds() throws {
        let sam = person("Sam Lee", confirmedMeetings: 5)
        // Below WeSpeaker's 0.92 bar.
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(
            profile: sam, similarity: 0.85, secondBestSimilarity: 0.60, recentOutcomes: []))
        let low = try calibrated(["auto_accept_similarity": 0.80])
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(
            profile: sam, similarity: 0.85, secondBestSimilarity: 0.60, recentOutcomes: [], thresholds: low))

        // 0.10 margin is inside WeSpeaker's 0.12.
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(
            profile: sam, similarity: 0.95, secondBestSimilarity: 0.85, recentOutcomes: []))
        let narrow = try calibrated(["auto_accept_margin_min": 0.08])
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(
            profile: sam, similarity: 0.95, secondBestSimilarity: 0.85, recentOutcomes: [], thresholds: narrow))

        // The mapping the pipeline saves follows the same bar.
        XCTAssertNil(SpeakerNamingPolicy.initialMapping(
            speakerId: "0", profile: sam, similarity: 0.85, secondBestSimilarity: 0.60).identifiedName)
        XCTAssertEqual(SpeakerNamingPolicy.initialMapping(
            speakerId: "0", profile: sam, similarity: 0.85, secondBestSimilarity: 0.60, thresholds: low).identifiedName,
                       "Sam Lee")
    }

    func testInviteeBarsComeFromThresholds() throws {
        let sam = person("Sam Lee", confirmedMeetings: 2)
        let invited: Set<String> = [SpeakerNamingPolicy.nameKey("Sam Lee")]
        func autoAccept(similarity: Double, runnerUp: Double, _ thresholds: SpeakerEmbeddingThresholds) -> Bool {
            SpeakerNamingPolicy.shouldAutoAccept(
                profile: sam, similarity: similarity, secondBestSimilarity: runnerUp, recentOutcomes: [],
                inviteeBars: SpeakerNamingPolicy.inviteeBars(for: sam, invitedNameKeys: invited, thresholds: thresholds),
                thresholds: thresholds)
        }
        // 0.72 is under WeSpeaker's 0.80 lineup bar.
        XCTAssertFalse(autoAccept(similarity: 0.72, runnerUp: 0.30, .weSpeaker))
        let low = try calibrated(["invitee_similarity": 0.65])
        XCTAssertTrue(autoAccept(similarity: 0.72, runnerUp: 0.30, low))
        XCTAssertEqual(SpeakerNamingPolicy.inviteeBars(for: sam, invitedNameKeys: invited, thresholds: low),
                       SpeakerNamingPolicy.InviteeBars(requiredConfirmedMeetings: 2, similarity: 0.65, marginMin: 0.10))

        // 0.06 to the runner-up is inside WeSpeaker's 0.10 lineup margin.
        XCTAssertFalse(autoAccept(similarity: 0.90, runnerUp: 0.84, .weSpeaker))
        let narrow = try calibrated(["invitee_margin_min": 0.05])
        XCTAssertTrue(autoAccept(similarity: 0.90, runnerUp: 0.84, narrow))
    }

    func testHighConfidenceComesFromThresholds() throws {
        XCTAssertEqual(SpeakerNamingPolicy.confidence(similarity: 0.80, callCount: 10), .medium)
        let low = try calibrated(["high_confidence_similarity": 0.75])
        XCTAssertEqual(SpeakerNamingPolicy.confidence(similarity: 0.80, callCount: 10, thresholds: low), .high)
    }

    // MARK: - Separation

    func testSeparationMergesFingerprintsAtTheModelsBar() throws {
        let low = try calibrated(["separation_merge": 0.45])
        XCTAssertEqual(SpeakerSeparationOptions.labTuned(maxSpeakers: nil, thresholds: low).mergeSimilarity, 0.45)
        XCTAssertEqual(
            SpeakerSeparationOptions.tuned(for: .pyannote, invitedPeople: nil, thresholds: low).mergeSimilarity, 0.45)
        XCTAssertEqual(SpeakerSeparationOptions.tuned(for: .pyannote, invitedPeople: nil).mergeSimilarity, 0.6)

        // Two long voices 0.50 alike stay apart at WeSpeaker's 0.6 and merge at 0.45.
        func segment(_ id: Int, _ embedding: [Float], _ start: Double) -> SpeakerSegment {
            SpeakerSegment(speakerId: id, startTime: start, endTime: start + 10, embedding: embedding, qualityScore: 0.9)
        }
        let input = [segment(1, xAxis, 0), segment(2, atCosine(0.50, axis: 1), 10)]
        func voices(_ thresholds: SpeakerEmbeddingThresholds) -> Int {
            let options = SpeakerSeparationOptions(mergeSimilarity: thresholds.separationMerge)
            return Set(SpeakerSeparation.apply(input, options: options).map(\.speakerId)).count
        }
        XCTAssertEqual(voices(.weSpeaker), 2)
        XCTAssertEqual(voices(low), 1)
    }
}
