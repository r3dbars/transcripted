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

    private typealias Resolution = (
        mappings: [String: SpeakerMapping], sources: [String: String], databaseIDs: [String: UUID]
    )

    private func resolve(profile: SpeakerProfile, similarity: Double = 0.97) -> Resolution {
        MeetingImportSpeakerMapping.resolve(
            result: makeResult(context: context(profile: profile, similarity: similarity)),
            originalProfiles: [profile], store: MappingSpeakerStore()
        )
    }

    private func assertPending(
        _ resolved: Resolution, profileID: UUID, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(resolved.mappings["system_2"]?.displayName, "Speaker 2", file: file, line: line)
        XCTAssertEqual(resolved.mappings["system_2"]?.isConfirmedIdentity, false, file: file, line: line)
        XCTAssertEqual(resolved.sources["system_2"], "db_pending", file: file, line: line)
        XCTAssertEqual(resolved.databaseIDs["system_2"], profileID, file: file, line: line)
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
