import Foundation
import TranscriptedCore

/// Mandatory evaluator parity and integration fixtures run by the verification
/// matrix. These fail closed when the baseline simulation drifts from a
/// production policy/transition or when the chronological replay contract
/// changes unexpectedly.
func runAutoResearchSelfTests() {
    let profileId = deterministicProfileId(1)
    let embedding: [Float] = [1, 0]
    let profile = SpeakerProfile(
        id: profileId,
        displayName: "truth:test",
        nameSource: NameSource.userManual,
        embedding: embedding,
        firstSeen: Date(timeIntervalSince1970: 1),
        lastSeen: Date(timeIntervalSince1970: 1),
        callCount: 8,
        confidence: 0.9,
        disputeCount: 0,
        confirmedMeetingCount: SpeakerNamingPolicy.requiredConfirmedMeetings,
        exemplars: []
    )
    let confirmedMeetings = Set(
        (1...SpeakerNamingPolicy.requiredConfirmedMeetings).map { "meeting-\($0)" }
    )
    let speaker = FingerprintSpeaker(
        gtSpeaker: "test",
        embedding: embedding,
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    let match = Transcription.SnapshotMatchResult(
        profileId: profileId,
        similarity: 0.99,
        secondBestSimilarity: -1,
        averageSimilarity: 0.99,
        secondBestAverageSimilarity: -1
    )
    var correctedState = SimulatedProfile(
        value: profile,
        labelTruth: "test",
        appearanceCount: 8,
        confirmedMeetings: confirmedMeetings,
        recentOutcomes: [.corrected],
        negativeExemplars: [],
        exemplarCounts: [],
        observedTruths: ["test"]
    )
    guard !shouldAutoName(
        state: correctedState,
        match: match,
        speaker: speaker,
        config: .productionBaseline
    ) else {
        die("autoeval self-test failed: a recent correction did not force probation")
    }

    correctedState.recentOutcomes = [.confirmed, .corrected]
    guard shouldAutoName(
        state: correctedState,
        match: match,
        speaker: speaker,
        config: .productionBaseline
    ) else {
        die("autoeval self-test failed: a later confirmation did not restore trust")
    }

    correctedState.value.disputeCount = 2
    var profiles = [profileId: correctedState]
    applyConfirmedSuggestion(
        profileId: profileId,
        speaker: speaker,
        match: match,
        meeting: "repair-meeting",
        config: .productionBaseline,
        profiles: &profiles
    )
    guard profiles[profileId]?.value.disputeCount == 0,
          profiles[profileId]?.recentOutcomes.first == .confirmed else {
        die("autoeval self-test failed: confirmation did not repair profile state")
    }

    var mergeState = correctedState
    mergeState.value.confidence = 0.5
    mergeState.value.exemplars = [[0, 1]]
    mergeState.exemplarCounts = [2]
    profiles = [profileId: mergeState]
    let unmatchedSpeaker = FingerprintSpeaker(
        gtSpeaker: "test",
        embedding: [0, 1],
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    applyUserConfirmedMerge(
        profileId: profileId,
        speaker: unmatchedSpeaker,
        profiles: &profiles
    )
    let expectedMergeEmbedding = blend(embedding, unmatchedSpeaker.embedding, alpha: 1 / 9)
    guard let merged = profiles[profileId],
          merged.appearanceCount == 9,
          abs(merged.value.confidence - 0.65) < 0.0001,
          merged.value.exemplars.isEmpty,
          merged.exemplarCounts.isEmpty,
          zip(merged.value.embedding, expectedMergeEmbedding).allSatisfy({ pair in
              abs(pair.0 - pair.1) < 0.0001
          }) else {
        die("autoeval self-test failed: unmatched ASK did not mirror production merge semantics")
    }
    let collisionProfile = deterministicProfileId(2)
    let secondCollisionProfile = deterministicProfileId(3)
    let falseMerges = falseMergeIndicators([
        collisionProfile: [
            "A": Set(["meeting-1", "meeting-1", "meeting-2"]),
            "B": ["meeting-2", "meeting-3"],
            "C": ["meeting-3", "meeting-4"],
            "D": ["meeting-1", "meeting-4"],
        ],
        secondCollisionProfile: [
            "E": ["meeting-5"],
            "F": ["meeting-6"],
        ],
    ])
    var bucketMetrics = MutableMetrics()
    bucketMetrics.withinMeetingFalseMergeIndicators = falseMerges.withinMeeting
    bucketMetrics.crossMeetingFalseMergeIndicators = falseMerges.crossMeeting
    let bucketSnapshot = bucketMetrics.snapshot()
    guard falseMerges.withinMeeting == 4,
          falseMerges.crossMeeting == 3,
          bucketSnapshot.falseMergeIndicators == 7,
          bucketSnapshot.falseMergeIndicators
            == bucketSnapshot.withinMeetingFalseMergeIndicators
                + bucketSnapshot.crossMeetingFalseMergeIndicators else {
        die("autoeval self-test failed: false-merge buckets overlap or omit a truth pair")
    }

    testWriteBackAndExemplarParity()
    testProductionMergeParity()
    let replayFixture = makeFusedReplayFixture()
    testFusedReplayUsesFrozenMeetingState(replayFixture)
    testSplitKeepsCrossIdentityMeetingContext()
    testAutoResearchCommandReport(replayFixture)
    print("AUTOEVAL_SELF_TEST PASS")
}

private func testWriteBackAndExemplarParity() {
    for (similarity, secondBest) in [
        (0.95, -1.0),
        (0.85, 0.60),
        (0.95, 0.90),
        (0.60, -1.0),
    ] {
        let simulated = blendAlpha(
            similarity: similarity,
            secondBest: secondBest,
            config: .productionBaseline
        )
        let production = SpeakerWritePathPolicy.voiceprintBlendAlpha(
            similarity: similarity,
            secondBestSimilarity: secondBest
        )
        guard abs(simulated - production) < 0.000_001 else {
            die("autoeval self-test failed: baseline write-back alpha drifted from production")
        }
    }

    let profileId = deterministicProfileId(40)
    let average: [Float] = [1, 0]
    let incoming: [Float] = [0, 1]
    let profile = SpeakerProfile(
        id: profileId,
        displayName: "truth:exemplar",
        nameSource: NameSource.userManual,
        embedding: average,
        firstSeen: Date(timeIntervalSince1970: 1),
        lastSeen: Date(timeIntervalSince1970: 1),
        callCount: 3,
        confidence: 0.7,
        disputeCount: 0,
        exemplars: [[0, 0.99]]
    )
    var simulated = SimulatedProfile(
        value: profile,
        labelTruth: "exemplar",
        appearanceCount: 3,
        confirmedMeetings: [],
        recentOutcomes: [],
        negativeExemplars: [],
        exemplarCounts: [2],
        observedTruths: ["exemplar"]
    )
    updateExemplars(state: &simulated, incoming: incoming, config: .productionBaseline)
    let production = SpeakerExemplarPolicy.updated(
        current: [.init(embedding: [0, 0.99], segmentCount: 2)],
        newMean: incoming,
        average: average
    )
    guard simulated.value.exemplars.count == production.count,
          simulated.exemplarCounts == production.map(\.segmentCount),
          zip(simulated.value.exemplars, production.map(\.embedding)).allSatisfy({ lhs, rhs in
              vectorsEqual(lhs, rhs)
          }) else {
        die("autoeval self-test failed: baseline exemplar transition drifted from production")
    }
}

private func testProductionMergeParity() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakerAutoResearchMergeParity-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = SpeakerDatabase(path: directory.appendingPathComponent("speakers.sqlite").path)
        let target = database.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil)
        for _ in 1..<8 {
            _ = database.addOrUpdateSpeaker(
                embedding: [1, 0],
                existingId: target.id,
                blendAlpha: 0
            )
        }
        let source = database.addOrUpdateSpeaker(embedding: [0, 1], existingId: nil)
        let targetBefore = database.getSpeaker(id: target.id)!
        var simulatedProfiles = [
            target.id: SimulatedProfile(
                value: targetBefore,
                labelTruth: "merge-target",
                appearanceCount: targetBefore.callCount,
                confirmedMeetings: [],
                recentOutcomes: [],
                negativeExemplars: [],
                exemplarCounts: [],
                observedTruths: ["merge-target"]
            )
        ]
        applyUserConfirmedMerge(
            profileId: target.id,
            speaker: FingerprintSpeaker(
                gtSpeaker: "merge-target",
                embedding: source.embedding,
                durationSeconds: 10,
                segmentCount: 4,
                clusterCount: 1,
                purity: 1
            ),
            profiles: &simulatedProfiles
        )
        try database.mergeProfiles(sourceId: source.id, into: target.id)
        guard let simulated = simulatedProfiles[target.id],
              let production = database.getSpeaker(id: target.id),
              simulated.appearanceCount == production.callCount,
              abs(simulated.value.confidence - production.confidence) < 0.000_001,
              vectorsEqual(simulated.value.embedding, production.embedding),
              simulated.value.exemplars == production.exemplars else {
            die("autoeval self-test failed: ASK merge transition drifted from production")
        }
    } catch {
        die("autoeval self-test failed: production merge parity fixture: \(error)")
    }
}

private func makeFusedReplayFixture() -> FingerprintCache {
    let a = FingerprintSpeaker(
        gtSpeaker: "A",
        embedding: [1, 0],
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    let b = FingerprintSpeaker(
        gtSpeaker: "B",
        embedding: [1, 0],
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    return FingerprintCache(
        corpus: "synthetic_fused",
        meetings: [
            .init(meeting: "m1", order: 1, speakers: [a]),
            .init(meeting: "m2", order: 2, speakers: [a]),
            .init(meeting: "m3", order: 3, speakers: [a]),
            .init(meeting: "m4", order: 4, speakers: [a]),
            .init(meeting: "m5", order: 5, speakers: [a, b]),
            .init(meeting: "m6", order: 6, speakers: [a]),
        ]
    )
}

private func testFusedReplayUsesFrozenMeetingState(_ cache: FingerprintCache) {
    let result = evaluate(
        cache: cache,
        config: .productionBaseline,
        split: .all,
        includeEvents: true
    )
    let metrics = result.metrics.snapshot()
    let fusedDecisions = result.events
        .filter { $0.meeting == "m5" }
        .map(\.decision)
    guard fusedDecisions == ["suggest", "suggest"],
          metrics.automaticNames == 1,
          metrics.correctAutomaticNames == 1,
          metrics.falseAutomaticNamesAllPurities == 0,
          metrics.wrongSuggestions == 1,
          metrics.openSetWrongSuggestions == 1,
          metrics.withinMeetingFalseMergeIndicators == 1 else {
        die("autoeval self-test failed: fused rows mutated or classified from live meeting state")
    }
}

private func testSplitKeepsCrossIdentityMeetingContext() {
    let corpus = "synthetic_context"
    let family = corpusFamily(corpus)
    let target = (0...).lazy.map { "target-\($0)" }.first { _ in true }!
    let targetSplit = identitySplit(family: family, truth: target)
    let background = (0...).lazy.map { "background-\($0)" }.first {
        identitySplit(family: family, truth: $0) != targetSplit
    }!
    let backgroundSpeaker = FingerprintSpeaker(
        gtSpeaker: background,
        embedding: [1, 0],
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    let targetSpeaker = FingerprintSpeaker(
        gtSpeaker: target,
        embedding: [1, 0],
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    let result = evaluate(
        cache: FingerprintCache(
            corpus: corpus,
            meetings: [
                .init(meeting: "background-enrollment", order: 1, speakers: [backgroundSpeaker]),
                .init(meeting: "mixed", order: 2, speakers: [backgroundSpeaker, targetSpeaker]),
            ]
        ),
        config: .productionBaseline,
        split: targetSplit,
        includeEvents: true
    ).metrics.snapshot()
    guard result.observations == 1,
          result.wrongSuggestions == 1,
          result.openSetWrongSuggestions == 1,
          result.withinMeetingFalseMergeIndicators == 1 else {
        die("autoeval self-test failed: identity split removed cross-speaker meeting context")
    }
}

private func testAutoResearchCommandReport(_ cache: FingerprintCache) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakerAutoResearchCommand-\(UUID().uuidString)")
    do {
        let inputRoot = directory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = inputRoot.appendingPathComponent("fixture.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cache).write(to: cacheURL, options: .atomic)
        let manifestURL = directory.appendingPathComponent("manifest.sha256")
        try "\(sha256Hex(of: cacheURL))  fixture.json\n".write(
            to: manifestURL,
            atomically: true,
            encoding: .utf8
        )
        let outputURL = directory.appendingPathComponent("report.json")
        runAutoResearch([
            "--manifest", manifestURL.path,
            "--input-root", inputRoot.path,
            "--out", outputURL.path,
            "--split", ResearchSplit.all.rawValue,
        ])
        let report = try JSONDecoder().decode(
            AutoResearchReport.self,
            from: Data(contentsOf: outputURL)
        )
        guard report.schemaVersion == 3,
              report.reports.count == 1,
              report.reports[0].slices[cache.corpus] != nil,
              ResearchConditionSlice.allCases.allSatisfy({
                  report.reports[0].slices[$0.rawValue] != nil
              }),
              report.reports[0].metrics.falseAutomaticNamesAllPurities == 0 else {
            die("autoeval self-test failed: command report omitted frozen condition guardrails")
        }
    } catch {
        die("autoeval self-test failed: command report fixture: \(error)")
    }
}

private func vectorsEqual(_ lhs: [Float], _ rhs: [Float]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.000_1 }
}
