#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import Foundation
import XCTest
import TranscriptedCore
@testable import transcripted_cli

final class MeetingImportSpeakerMappingTests: XCTestCase {
    func testTrustedKnownSpeakerUsesOriginalNameAndDatabaseID() {
        let profile = makeProfile()
        let resolved = resolve(profile: profile)

        XCTAssertEqual(resolved.mappings["system_2"]?.displayName, "Fixture Speaker")
        XCTAssertEqual(resolved.mappings["system_2"]?.isConfirmedIdentity, true)
        XCTAssertEqual(resolved.sources["system_2"], "db")
        XCTAssertEqual(resolved.databaseIDs["system_2"], profile.id)
    }

    func testPreRunMaturityCannotBePromotedByChangedSnapshot() {
        let profile = makeProfile(confirmedMeetingCount: 4)
        var changedSnapshot = profile
        changedSnapshot.confirmedMeetingCount = 10
        changedSnapshot.displayName = "Changed During Import"
        let result = makeResult(context: context(profile: changedSnapshot))
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: result, originalProfiles: [profile], store: MappingSpeakerStore()
        )

        assertPending(resolved, profileID: profile.id)
    }

    func testPreRunNameIsUsedEvenWhenTemporaryProfileNameChanges() {
        let profile = makeProfile()
        var changedSnapshot = profile
        changedSnapshot.displayName = "Changed During Import"
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: changedSnapshot)),
            originalProfiles: [profile], store: MappingSpeakerStore()
        )

        XCTAssertEqual(resolved.mappings["system_2"]?.displayName, "Fixture Speaker")
    }

    func testAmbiguousAverageMarginBlocksLuckyExemplarName() {
        let profile = makeProfile()
        let match = context(
            profile: profile, similarity: 0.99, secondSimilarity: 0.70,
            averageSimilarity: 0.82, secondAverageSimilarity: 0.79
        )
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: match), originalProfiles: [profile], store: MappingSpeakerStore()
        )

        assertPending(resolved, profileID: profile.id)
    }

    func testBelowAutoAcceptThresholdStaysGeneric() {
        let profile = makeProfile()
        assertPending(resolve(profile: profile, similarity: 0.92), profileID: profile.id)
    }

    func testDisputedProfileStaysGeneric() {
        let profile = makeProfile(disputeCount: 1)
        assertPending(resolve(profile: profile), profileID: profile.id)
    }

    func testRecentCorrectionDemotesOtherwiseTrustedProfile() {
        let profile = makeProfile()
        let store = MappingSpeakerStore(outcomes: [
            profile.id: [
                SpeakerMatchOutcome(profileId: profile.id, kind: .autoAccepted),
                SpeakerMatchOutcome(profileId: profile.id, kind: .corrected),
            ]
        ])
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: profile)),
            originalProfiles: [profile], store: store
        )

        assertPending(resolved, profileID: profile.id)
    }

    func testUtteranceOnlyFallbackWithUnknownMarginStaysGeneric() {
        let profile = makeProfile()
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: nil, utteranceProfileID: profile.id, utteranceSimilarity: 0.99),
            originalProfiles: [profile], store: MappingSpeakerStore()
        )

        assertPending(resolved, profileID: profile.id)
    }

    func testNewSnapshotProfileNeverExposesPhantomDatabaseID() {
        let original = makeProfile()
        let temporary = makeProfile()
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: temporary)),
            originalProfiles: [original], store: MappingSpeakerStore()
        )

        assertUnknown(resolved)
    }

    func testUnnamedOriginalProfileNeverExposesDatabaseID() {
        for name in [nil, "", " \n "] as [String?] {
            let profile = makeProfile(name: name)
            assertUnknown(resolve(profile: profile))
        }
    }

    func testPipelineRejectedMatchIsNotRematchedFromEmbedding() {
        let original = makeProfile()
        let temporaryID = UUID()
        let rejected = ChannelSpeakerContext(
            persistentSpeakerId: temporaryID,
            sessionEmbedding: original.embedding,
            matchedProfileSnapshot: nil,
            matchSimilarity: nil
        )
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: rejected),
            originalProfiles: [original], store: MappingSpeakerStore()
        )

        // A negative-exemplar veto (or other matcher rejection) has already
        // occurred in Core. The mapping helper must not override that decision.
        assertUnknown(resolved)
    }

    func testMicrophoneSpeakersAreExcluded() {
        let profile = makeProfile()
        let utterance = TranscriptionUtterance(
            start: 0, end: 2, channel: 0, speakerId: 2,
            persistentSpeakerId: profile.id, matchSimilarity: 0.99, transcript: "Fixture"
        )
        let result = TranscriptionResult(
            micUtterances: [utterance], systemUtterances: [],
            micSpeakerContexts: ["2": context(profile: profile)], duration: 2, processingTime: 0
        )
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: result, originalProfiles: [profile], store: MappingSpeakerStore()
        )

        XCTAssertTrue(resolved.mappings.isEmpty)
        XCTAssertTrue(resolved.sources.isEmpty)
        XCTAssertTrue(resolved.databaseIDs.isEmpty)
    }

    // MARK: - Voiceprint bars, reasons, and likely names

    func testReDimNet2MatchUsesReDimNet2Bars() {
        let profile = makeProfile()
        // 0.93 clears WeSpeaker's 0.92 bar but not ReDimNet2's 0.946: the CLI must
        // never be looser than the app for the model it ran.
        XCTAssertEqual(resolve(profile: profile, similarity: 0.93).mappings["system_2"]?.displayName, "Fixture Speaker")
        let redimnet = resolve(profile: profile, similarity: 0.93, thresholds: .reDimNet2B4)
        assertPending(redimnet, profileID: profile.id)
        XCTAssertEqual(redimnet.reasons["system_2"],
                       "matched Fixture Speaker, but similarity 0.930 is not above the 0.946 silent-naming bar")
        XCTAssertEqual(resolve(profile: profile, similarity: 0.97, thresholds: .reDimNet2B4).mappings["system_2"]?.displayName,
                       "Fixture Speaker")
    }

    func testBelowFiveConfirmationsStaysNumberedAndSaysWhy() {
        let profile = makeProfile(confirmedMeetingCount: 2)
        let resolved = resolve(profile: profile, thresholds: .reDimNet2B4)
        assertPending(resolved, profileID: profile.id)
        XCTAssertEqual(resolved.reasons["system_2"], "matched Fixture Speaker, but only 2 of 5 confirmed meetings")
    }

    func testSilentlyNamedSpeakerHasNoReason() {
        XCTAssertTrue(resolve(profile: makeProfile(), thresholds: .reDimNet2B4).reasons.isEmpty)
    }

    func testEveryNumberedSpeakerGetsAReason() {
        let named = makeProfile()
        let unnamed = makeProfile(name: nil)
        XCTAssertEqual(resolve(profile: unnamed).reasons["system_2"], "matched a saved voice that has no name yet")
        let stranger = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: makeProfile())), originalProfiles: [named], store: MappingSpeakerStore())
        XCTAssertEqual(stranger.reasons["system_2"], "didn't match anyone saved in this voiceprint database")
        let unavailable = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: named)), originalProfiles: [named], store: MappingSpeakerStore(),
            unavailableReason: "there's no saved speaker database for ReDimNet2")
        assertUnknown(unavailable)
        XCTAssertEqual(unavailable.reasons["system_2"], "there's no saved speaker database for ReDimNet2")
    }

    func testLikelyNamesAreOptInHedgedAndNeverConfirmed() {
        let profile = makeProfile(confirmedMeetingCount: 2)
        assertPending(resolve(profile: profile, thresholds: .reDimNet2B4), profileID: profile.id)
        let likely = resolve(profile: profile, thresholds: .reDimNet2B4, nameLikely: true)
        XCTAssertEqual(likely.mappings["system_2"]?.displayName, "Fixture Speaker (likely)")
        XCTAssertEqual(likely.mappings["system_2"]?.isConfirmedIdentity, false)
        XCTAssertEqual(likely.sources["system_2"], "db_pending", "a likely name is never recorded as a confirmed identity")
        XCTAssertEqual(likely.databaseIDs["system_2"], profile.id)
        XCTAssertEqual(likely.reasons["system_2"], "named Fixture Speaker as likely: 2 of 5 confirmed meetings (--name-likely-speakers)")
    }

    func testLikelyNamesIncludeMatchesBelowTheSilentSimilarityBar() {
        // Tester case: 0.891 clears ReDimNet2's invitee/suggest bar (0.815) but
        // not the 0.946 silent-naming bar. The flag's job is to write that name.
        let profile = makeProfile()
        assertPending(resolve(profile: profile, similarity: 0.891, thresholds: .reDimNet2B4),
                      profileID: profile.id)
        let likely = resolve(profile: profile, similarity: 0.891, thresholds: .reDimNet2B4, nameLikely: true)
        XCTAssertEqual(likely.mappings["system_2"]?.displayName, "Fixture Speaker (likely)")
        XCTAssertEqual(likely.mappings["system_2"]?.isConfirmedIdentity, false)
        XCTAssertEqual(likely.sources["system_2"], "db_pending")
        XCTAssertEqual(likely.databaseIDs["system_2"], profile.id)
        XCTAssertEqual(
            likely.reasons["system_2"],
            "named Fixture Speaker as likely: similarity 0.891 is not above the 0.946 silent-naming bar (--name-likely-speakers)"
        )
    }

    func testLikelyNamesUseTheInviteeSimilarityFloor() {
        // Below the model's invitee bar stays numbered even with the flag.
        // 0.860 (tester's second match) is above ReDimNet2's 0.815 invitee bar.
        let profile = makeProfile()
        assertPending(resolve(profile: profile, similarity: 0.814, thresholds: .reDimNet2B4, nameLikely: true),
                      profileID: profile.id)
        let aboveFloor = resolve(profile: profile, similarity: 0.860, thresholds: .reDimNet2B4, nameLikely: true)
        XCTAssertEqual(aboveFloor.mappings["system_2"]?.displayName, "Fixture Speaker (likely)")
        XCTAssertEqual(aboveFloor.mappings["system_2"]?.isConfirmedIdentity, false)
        XCTAssertEqual(aboveFloor.sources["system_2"], "db_pending")
    }

    func testLikelyNamesStayNumberedWhenTheRunnerUpIsAmbiguous() {
        // 0.891 vs 0.85: above the invitee floor, but the 0.041 gap loses
        // to ReDimNet2's inviteeMarginMin (0.106).
        let profile = makeProfile()
        let match = context(
            profile: profile, similarity: 0.891, secondSimilarity: 0.85,
            averageSimilarity: 0.891, secondAverageSimilarity: 0.85
        )
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: match), originalProfiles: [profile], store: MappingSpeakerStore(),
            thresholds: .reDimNet2B4, nameLikelySpeakers: true
        )
        assertPending(resolved, profileID: profile.id)
        XCTAssertTrue(resolved.reasons["system_2"]?.contains("another saved person scored too close") == true)
    }

    func testLikelyNamesWhenTheRunnerUpIsClearlyBeaten() {
        // 0.891 vs 0.70: same floor, 0.191 gap clears inviteeMarginMin.
        let profile = makeProfile()
        let match = context(
            profile: profile, similarity: 0.891, secondSimilarity: 0.70,
            averageSimilarity: 0.891, secondAverageSimilarity: 0.70
        )
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: match), originalProfiles: [profile], store: MappingSpeakerStore(),
            thresholds: .reDimNet2B4, nameLikelySpeakers: true
        )
        XCTAssertEqual(resolved.mappings["system_2"]?.displayName, "Fixture Speaker (likely)")
        XCTAssertEqual(resolved.mappings["system_2"]?.isConfirmedIdentity, false)
        XCTAssertEqual(resolved.sources["system_2"], "db_pending")
    }

    func testLikelyNamesWhenConfirmationsAndSimilarityAreBothShort() {
        let profile = makeProfile(confirmedMeetingCount: 2)
        let likely = resolve(profile: profile, similarity: 0.891, thresholds: .reDimNet2B4, nameLikely: true)
        XCTAssertEqual(likely.mappings["system_2"]?.displayName, "Fixture Speaker (likely)")
        XCTAssertEqual(likely.mappings["system_2"]?.isConfirmedIdentity, false)
        XCTAssertEqual(likely.sources["system_2"], "db_pending")
        XCTAssertEqual(
            likely.reasons["system_2"],
            "named Fixture Speaker as likely: 2 of 5 confirmed meetings; similarity 0.891 is not above the 0.946 silent-naming bar (--name-likely-speakers)"
        )
    }

    func testLikelyNamesDoNotCreateWikiLinksTagsOrPersonPages() {
        let profile = makeProfile(confirmedMeetingCount: 2)
        let likely = resolve(profile: profile, thresholds: .reDimNet2B4, nameLikely: true)
        let mapping = likely.mappings["system_2"]
        XCTAssertEqual(mapping?.displayName, "Fixture Speaker (likely)")
        XCTAssertEqual(mapping?.isConfirmedIdentity, false)

        let utterance = TranscriptionUtterance(
            start: 0, end: 2, channel: 1, speakerId: 2,
            persistentSpeakerId: profile.id, matchSimilarity: 0.97, transcript: "Fixture"
        )
        let result = TranscriptionResult(
            micUtterances: [], systemUtterances: [utterance],
            systemSpeakerContexts: ["2": context(profile: profile)],
            duration: 2, processingTime: 0, microphoneAudioOutcome: .notProvided
        )
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-00000000A011")!,
            speakerMappings: likely.mappings,
            speakerSources: likely.sources,
            date: Date(timeIntervalSince1970: 1_775_000_000),
            formatOptions: TranscriptFormatOptions(
                audioSources: [.systemAudio],
                includeObsidianMetadata: true
            )
        )
        XCTAssertTrue(markdown.contains("[System/Fixture Speaker (likely)]"), markdown)
        XCTAssertFalse(markdown.contains("[[Fixture Speaker (likely)]]"), markdown)
        XCTAssertFalse(markdown.contains("speaker/fixture-speaker-(likely)"), markdown)
        XCTAssertFalse(markdown.contains("**Participants:**"), markdown)
    }

    func testLikelyNamesNeverRelaxHealthMarginOrNeverConfirmed() {
        assertPending(resolve(profile: makeProfile(confirmedMeetingCount: 0), thresholds: .reDimNet2B4, nameLikely: true),
                      profileID: nil)
        assertPending(resolve(profile: makeProfile(confirmedMeetingCount: 2, disputeCount: 1),
                              thresholds: .reDimNet2B4, nameLikely: true), profileID: nil)
        let close = makeProfile(confirmedMeetingCount: 2)
        let match = context(profile: close, similarity: 0.99, secondSimilarity: 0.70,
                            averageSimilarity: 0.90, secondAverageSimilarity: 0.85)
        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: match), originalProfiles: [close], store: MappingSpeakerStore(),
            thresholds: .reDimNet2B4, nameLikelySpeakers: true)
        assertPending(resolved, profileID: close.id)
        XCTAssertTrue(resolved.reasons["system_2"]?.contains("another saved person scored too close") == true)
    }

    /// A person the app saved in its ReDimNet2 database, confirmed in five
    /// meetings, is named by the CLI's default resolution: the database the plan
    /// points at, read through the read-only snapshot, with ReDimNet2's bars.
    func testPersonSavedInTheReDimNet2DatabaseIsNamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-redimnet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("redimnet2-voiceprint/Model.mlmodelc"), withIntermediateDirectories: true)
        let plan = MeetingImportModels.voiceprintPlan(
            choice: "app", environment: [:], appDefaults: nil, resourceDirectories: [resources],
            homeDirectory: root, stateDirectory: state, appBuildKey: .some(nil))
        XCTAssertEqual(plan.databaseURL.lastPathComponent, "speakers_redimnet2-b4.sqlite")

        // Seed the app-side database as the app would, with a 192-d voiceprint.
        var vector = [Float](repeating: 0, count: 192); vector[0] = 1
        let live = SpeakerDatabase(path: plan.databaseURL.path, thresholds: .reDimNet2B4)
        let seeded = live.addOrUpdateSpeaker(embedding: vector)
        live.setDisplayName(id: seeded.id, name: "Fixture Speaker")
        try live.recordUserConfirmations((0..<5).map { _ in
            SpeakerUserConfirmation(profileId: seeded.id, transcriptId: UUID(), kind: .confirmed)
        })
        // A decoy in the legacy WeSpeaker file must not be what the CLI reads.
        _ = SpeakerDatabase(path: state.appendingPathComponent("speakers.sqlite").path)

        let snapshotURL = root.appendingPathComponent("snapshot.sqlite")
        try SpeakerDatabaseSnapshot.create(sourceURL: plan.databaseURL, destinationURL: snapshotURL)
        let snapshot = SpeakerDatabase(path: snapshotURL.path, thresholds: .reDimNet2B4)
        let profiles = snapshot.allSpeakers()
        let profile = try XCTUnwrap(profiles.first { $0.id == seeded.id })
        XCTAssertEqual(profile.confirmedMeetingCount, 5)

        let resolved = MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: profile, similarity: 0.98, secondSimilarity: -1,
                                                averageSimilarity: 0.98, secondAverageSimilarity: -1)),
            originalProfiles: profiles, store: snapshot, thresholds: .reDimNet2B4)
        XCTAssertEqual(resolved.mappings["system_2"]?.displayName, "Fixture Speaker")
        XCTAssertEqual(resolved.sources["system_2"], "db")
        XCTAssertEqual(resolved.databaseIDs["system_2"], seeded.id)
    }

    private typealias Resolution = MeetingImportSpeakerMapping.Resolution

    private func resolve(
        profile: SpeakerProfile, similarity: Double = 0.97,
        thresholds: SpeakerEmbeddingThresholds = .weSpeaker, nameLikely: Bool = false
    ) -> Resolution {
        MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: profile, similarity: similarity)),
            originalProfiles: [profile], store: MappingSpeakerStore(),
            thresholds: thresholds, nameLikelySpeakers: nameLikely
        )
    }

    private func assertPending(
        _ resolved: Resolution, profileID: UUID?, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(resolved.mappings["system_2"]?.displayName, "Speaker 2", file: file, line: line)
        XCTAssertEqual(resolved.mappings["system_2"]?.isConfirmedIdentity, false, file: file, line: line)
        XCTAssertEqual(resolved.sources["system_2"], "db_pending", file: file, line: line)
        if let profileID {
            XCTAssertEqual(resolved.databaseIDs["system_2"], profileID, file: file, line: line)
        }
    }

    private func assertUnknown(
        _ resolved: Resolution, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(resolved.mappings["system_2"]?.displayName, "Speaker 2", file: file, line: line)
        XCTAssertEqual(resolved.sources["system_2"], "unknown", file: file, line: line)
        XCTAssertTrue(resolved.databaseIDs.isEmpty, file: file, line: line)
    }

    private func makeProfile(
        name: String? = "Fixture Speaker", confirmedMeetingCount: Int = 5, disputeCount: Int = 0
    ) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(), displayName: name, nameSource: NameSource.userManual,
            embedding: [1, 0, 0], firstSeen: .distantPast, lastSeen: .distantPast,
            callCount: 10, confidence: 0.9, disputeCount: disputeCount,
            confirmedMeetingCount: confirmedMeetingCount
        )
    }

    private func context(
        profile: SpeakerProfile, similarity: Double = 0.97, secondSimilarity: Double? = 0.70,
        averageSimilarity: Double? = 0.96, secondAverageSimilarity: Double? = 0.70
    ) -> ChannelSpeakerContext {
        ChannelSpeakerContext(
            persistentSpeakerId: profile.id, sessionEmbedding: profile.embedding,
            matchedProfileSnapshot: profile, matchSimilarity: similarity,
            matchSecondSimilarity: secondSimilarity, matchAverageSimilarity: averageSimilarity,
            matchSecondBestAverageSimilarity: secondAverageSimilarity
        )
    }

    private func makeResult(
        context: ChannelSpeakerContext?, utteranceProfileID: UUID? = nil, utteranceSimilarity: Double? = nil
    ) -> TranscriptionResult {
        let utterance = TranscriptionUtterance(
            start: 0, end: 2, channel: 1, speakerId: 2,
            persistentSpeakerId: context?.persistentSpeakerId ?? utteranceProfileID,
            matchSimilarity: context?.matchSimilarity ?? utteranceSimilarity, transcript: "Fixture"
        )
        return TranscriptionResult(
            micUtterances: [], systemUtterances: [utterance],
            systemSpeakerContexts: context.map { ["2": $0] } ?? [:],
            duration: 2, processingTime: 0, microphoneAudioOutcome: .notProvided
        )
    }
}

private struct MappingSpeakerStore: SpeakerStore {
    var outcomes: [UUID: [SpeakerMatchOutcome]] = [:]

    func recentMatchOutcomes(profileId: UUID, limit: Int) -> [SpeakerMatchOutcome] {
        XCTAssertEqual(limit, SpeakerProfileHealth.recentOutcomeWindow)
        return Array((outcomes[profileId] ?? []).prefix(limit))
    }

    func matchSpeaker(embedding: [Float], threshold: Double) -> SpeakerMatchResult? {
        XCTFail("Mapping must not rerun matching")
        return nil
    }
    func getSpeaker(id: UUID) -> SpeakerProfile? {
        XCTFail("Mapping must use pre-run profiles")
        return nil
    }
    func allSpeakers() -> [SpeakerProfile] {
        XCTFail("Mapping must use pre-run profiles")
        return []
    }
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile {
        fatalError("Mapping must not mutate profiles")
    }
    func setDisplayName(id: UUID, name: String, source: String) { XCTFail("Unexpected mutation") }
    func restoreProfile(_ profile: SpeakerProfile) { XCTFail("Unexpected mutation") }
    func deleteSpeaker(id: UUID) { XCTFail("Unexpected mutation") }
    func mergeProfiles(sourceId: UUID, into targetId: UUID) throws { XCTFail("Unexpected mutation") }
    func mergeDuplicates() { XCTFail("Unexpected mutation") }
    func pruneWeakProfiles() { XCTFail("Unexpected mutation") }
    func incrementDisputeCount(id: UUID) { XCTFail("Unexpected mutation") }
    func resetDisputeCount(id: UUID) { XCTFail("Unexpected mutation") }
    func recordMatchOutcome(_ outcome: SpeakerMatchOutcome) { XCTFail("Unexpected mutation") }
}
#endif
