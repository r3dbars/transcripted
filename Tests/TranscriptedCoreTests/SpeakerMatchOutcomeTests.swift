import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerMatchOutcomeTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerMatchOutcomeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Store

    func testRecordAndReadRecentOutcomesNewestFirst() {
        let profileId = UUID()
        let transcriptId = UUID()
        let base = Date(timeIntervalSince1970: 1_750_000_000)

        database.recordMatchOutcome(SpeakerMatchOutcome(
            profileId: profileId,
            kind: .named,
            channel: "system",
            transcriptId: transcriptId,
            recordedAt: base
        ))
        database.recordMatchOutcome(SpeakerMatchOutcome(
            profileId: profileId,
            kind: .confirmed,
            similarity: 0.83,
            secondSimilarity: 0.61,
            callCountAtMatch: 3,
            channel: "system",
            transcriptId: transcriptId,
            recordedAt: base.addingTimeInterval(3600)
        ))
        database.recordMatchOutcome(SpeakerMatchOutcome(
            profileId: profileId,
            kind: .autoAccepted,
            similarity: 0.95,
            callCountAtMatch: 6,
            channel: "mic",
            recordedAt: base.addingTimeInterval(7200)
        ))

        let recent = database.recentMatchOutcomes(profileId: profileId, limit: 10)
        XCTAssertEqual(recent.map(\.kind), [.autoAccepted, .confirmed, .named])
        XCTAssertEqual(recent[1].similarity ?? 0, 0.83, accuracy: 0.0001)
        XCTAssertEqual(recent[1].secondSimilarity ?? 0, 0.61, accuracy: 0.0001)
        XCTAssertEqual(recent[1].callCountAtMatch, 3)
        XCTAssertEqual(recent[0].channel, "mic")
        XCTAssertNil(recent[0].transcriptId)
        XCTAssertEqual(recent[2].transcriptId, transcriptId)

        let limited = database.recentMatchOutcomes(profileId: profileId, limit: 1)
        XCTAssertEqual(limited.map(\.kind), [.autoAccepted])

        XCTAssertTrue(database.recentMatchOutcomes(profileId: UUID(), limit: 5).isEmpty)
    }

    func testOutcomesByTranscriptAndAutoAcceptCount() {
        let profileA = UUID()
        let profileB = UUID()
        let meetingOne = UUID()
        let meetingTwo = UUID()

        // Batch write path — one transaction, same rows as individual records.
        database.recordMatchOutcomes([
            SpeakerMatchOutcome(profileId: profileA, kind: .autoAccepted, transcriptId: meetingOne),
            SpeakerMatchOutcome(profileId: profileB, kind: .corrected, transcriptId: meetingOne),
        ])
        database.recordMatchOutcome(SpeakerMatchOutcome(profileId: profileA, kind: .autoAccepted, transcriptId: meetingTwo))

        let meetingOneOutcomes = database.matchOutcomes(transcriptId: meetingOne)
        XCTAssertEqual(meetingOneOutcomes.count, 2)
        XCTAssertEqual(Set(meetingOneOutcomes.map(\.profileId)), [profileA, profileB])

        XCTAssertEqual(database.autoAcceptedOutcomeCount(profileId: profileA), 2)
        XCTAssertEqual(database.autoAcceptedOutcomeCount(profileId: profileB), 0)
    }

    // MARK: - Health

    func testHealthProbationRules() {
        XCTAssertEqual(SpeakerProfileHealth.assess(disputeCount: 0, recentOutcomes: []), .trusted)
        XCTAssertEqual(SpeakerProfileHealth.assess(disputeCount: 1, recentOutcomes: []), .probation)

        // Latest user verdict was a correction — demoted even with disputes reset.
        XCTAssertEqual(
            SpeakerProfileHealth.assess(disputeCount: 0, recentOutcomes: [.autoAccepted, .corrected, .confirmed]),
            .probation
        )
        // A fresh confirmation restores trust after one old correction.
        XCTAssertEqual(
            SpeakerProfileHealth.assess(disputeCount: 0, recentOutcomes: [.confirmed, .corrected]),
            .trusted,
            "one re-confirmation should lift probation"
        )
        // Two corrections inside the window mark a chronically confusable profile.
        XCTAssertEqual(
            SpeakerProfileHealth.assess(
                disputeCount: 0,
                recentOutcomes: [.confirmed, .corrected, .autoAccepted, .corrected, .autoAccepted]
            ),
            .probation
        )
        // Corrections older than the window are forgiven.
        XCTAssertEqual(
            SpeakerProfileHealth.assess(
                disputeCount: 0,
                recentOutcomes: [.confirmed, .autoAccepted, .autoAccepted, .autoAccepted, .autoAccepted, .corrected, .corrected]
            ),
            .trusted
        )
    }

    func testAutoAcceptDemotionForUnhealthyProfile() {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Known Voice",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 8,
            confidence: 0.9,
            disputeCount: 0
        )

        // Sanity: this profile clears every existing auto-accept gate.
        XCTAssertTrue(SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile,
            similarity: 0.96,
            secondBestSimilarity: -1,
            recentOutcomes: [.confirmed, .autoAccepted]
        ))

        // A recent correction demotes it back to confirm mode.
        XCTAssertFalse(SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile,
            similarity: 0.96,
            secondBestSimilarity: -1,
            recentOutcomes: [.corrected, .autoAccepted]
        ))

        // And the demoted profile renders a generic label, not the saved name.
        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0",
            profile: profile,
            similarity: 0.96,
            secondBestSimilarity: -1,
            recentOutcomes: [.corrected]
        )
        XCTAssertNil(mapping.identifiedName)
    }

    // MARK: - Review prioritization

    func testReviewPrioritizerPutsDoubtfulSuggestionsFirst() {
        func entry(_ diarizerId: String, name: String?, similarity: Double?, needsNaming: Bool) -> SpeakerNamingEntry {
            SpeakerNamingEntry(
                id: UUID(),
                diarizerSpeakerId: diarizerId,
                clipURL: URL(fileURLWithPath: "/tmp/clip-\(diarizerId).wav"),
                sampleText: "sample",
                currentName: name,
                matchSimilarity: similarity,
                needsNaming: needsNaming,
                needsConfirmation: name != nil
            )
        }

        let strongSuggestion = entry("0", name: "A", similarity: 0.89, needsNaming: false)
        let unknownVoice = entry("1", name: nil, similarity: nil, needsNaming: true)
        let doubtfulSuggestion = entry("2", name: "B", similarity: 0.71, needsNaming: false)
        let anotherUnknown = entry("3", name: nil, similarity: nil, needsNaming: true)

        let ranked = SpeakerReviewPrioritizer.ranked([
            strongSuggestion, unknownVoice, doubtfulSuggestion, anotherUnknown,
        ])

        XCTAssertEqual(
            ranked.map(\.diarizerSpeakerId),
            ["2", "0", "1", "3"],
            "doubtful suggestion first, then stronger suggestion, then unknowns in stable order"
        )
    }

    // MARK: - Coordinator outcome mapping

    func testPlannedMatchOutcomesMapVerdictsAndAttributeCorrections() {
        let transcriptId = UUID()
        let suggestedProfile = SpeakerProfile(
            id: UUID(),
            displayName: "Suggested",
            nameSource: NameSource.userManual,
            embedding: [0.5],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 4,
            confidence: 0.8,
            disputeCount: 0
        )
        let rowId = UUID()
        let entry = SpeakerNamingEntry(
            id: rowId,
            diarizerSpeakerId: "0",
            channel: .system,
            clipURL: URL(fileURLWithPath: "/tmp/clip.wav"),
            sampleText: "sample",
            currentName: "Suggested",
            matchSimilarity: 0.81,
            matchSecondSimilarity: 0.66,
            needsNaming: false,
            needsConfirmation: true,
            matchedProfileSnapshot: suggestedProfile
        )
        let clipsByKey = ["system_0": entry]

        let corrected = SpeakerNameUpdate(
            persistentSpeakerId: rowId,
            diarizerSpeakerId: "0",
            channel: .system,
            newName: "Actually Someone Else",
            previousName: "Suggested",
            action: .corrected
        )
        let collapsed = SpeakerNameUpdate(
            persistentSpeakerId: UUID(),
            diarizerSpeakerId: "1",
            channel: .mic,
            newName: "You",
            action: .collapsedToMe
        )

        let outcomes = TranscriptionTaskManager.plannedMatchOutcomes(
            for: [corrected, collapsed],
            clipsBySpeakerId: clipsByKey,
            transcriptId: transcriptId
        )

        XCTAssertEqual(outcomes.count, 1, "collapse rows are bookkeeping, not match verdicts")
        XCTAssertEqual(outcomes[0].kind, .corrected)
        XCTAssertEqual(
            outcomes[0].profileId,
            suggestedProfile.id,
            "a correction should land on the profile that was wrongly suggested"
        )
        XCTAssertEqual(outcomes[0].similarity ?? 0, 0.81, accuracy: 0.0001)
        XCTAssertEqual(outcomes[0].secondSimilarity ?? 0, 0.66, accuracy: 0.0001)
        XCTAssertEqual(outcomes[0].callCountAtMatch, 4)
        XCTAssertEqual(outcomes[0].channel, "system")
        XCTAssertEqual(outcomes[0].transcriptId, transcriptId)
    }
}
