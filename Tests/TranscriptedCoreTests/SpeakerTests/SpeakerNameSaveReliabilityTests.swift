import XCTest
import Combine
import SQLite3
@testable import TranscriptedCore

/// Regression coverage for speaker review saves that failed or silently corrupted
/// saved people (Sentry APPLE-MACOS-1R). One test per root cause:
/// - relabeling a recognized person to another saved person merged them away
/// - rows sharing one profile with different verdicts contradicted each other
/// - another meeting's cleanup merged or deleted a profile an open review needed
/// - failures that remain carry a coarse reason for telemetry
@available(macOS 14.0, *)
final class SpeakerNameSaveReliabilityTests: XCTestCase {

    // MARK: - Relabel of a recognized person

    @MainActor
    func testRelabelingRecognizedPersonToAnotherSavedPersonKeepsBothPeople() async throws {
        let harness = try makeHarness()
        let alice = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.11), existingId: nil)
        harness.speakerDB.setDisplayName(id: alice.id, name: "Alice", source: NameSource.userManual)
        let bob = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.52), existingId: nil)
        harness.speakerDB.setDisplayName(id: bob.id, name: "Bob", source: NameSource.userManual)
        let aliceBeforeMeeting = try XCTUnwrap(harness.speakerDB.getSpeaker(id: alice.id))
        let bobBeforeSave = try XCTUnwrap(harness.speakerDB.getSpeaker(id: bob.id))
        // The meeting recognized this voice as Alice and blended it into her profile.
        let meetingVoice = embedding(0.13)
        _ = harness.speakerDB.addOrUpdateSpeaker(embedding: meetingVoice, existingId: alice.id)

        let row = ReviewRow(
            diarizerSpeakerId: "1",
            persistentSpeakerId: alice.id,
            currentName: "Alice",
            text: "I think we should ship it.",
            sessionEmbedding: meetingVoice,
            matchedProfileSnapshot: aliceBeforeMeeting
        )
        let meeting = try writeMeeting(harness: harness, rows: [row])

        submit(
            harness: harness,
            meeting: meeting,
            updates: [row.update(name: "Bob", action: .merged(targetProfileId: bob.id))]
        )
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        let aliceAfter = try XCTUnwrap(
            harness.speakerDB.getSpeaker(id: alice.id),
            "picking a different saved person must never merge the recognized person away"
        )
        XCTAssertEqual(aliceAfter.displayName, "Alice")
        XCTAssertEqual(aliceAfter.callCount, aliceBeforeMeeting.callCount, "the wrong match is rolled back")
        XCTAssertEqual(aliceAfter.disputeCount, aliceBeforeMeeting.disputeCount + 1)
        XCTAssertEqual(harness.speakerDB.negativeExemplarsByProfile()[alice.id]?.count, 1)

        let bobAfter = try XCTUnwrap(harness.speakerDB.getSpeaker(id: bob.id))
        XCTAssertEqual(bobAfter.displayName, "Bob")
        XCTAssertEqual(bobAfter.callCount, bobBeforeSave.callCount + 1, "the voice is taught to the picked person")
        XCTAssertEqual(bobAfter.confirmedMeetingCount, 1)

        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Bob] I think we should ship it."), saved)
        XCTAssertTrue(saved.contains(bob.id.uuidString), saved)
    }

    @MainActor
    func testPickingSameNamedDuplicateStillMergesIt() async throws {
        let harness = try makeHarness()
        let duplicate = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.21), existingId: nil)
        harness.speakerDB.setDisplayName(id: duplicate.id, name: "Dana", source: NameSource.userManual)
        let keeper = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.22), existingId: nil)
        harness.speakerDB.setDisplayName(id: keeper.id, name: "Dana", source: NameSource.userManual)
        let snapshot = try XCTUnwrap(harness.speakerDB.getSpeaker(id: duplicate.id))

        let row = ReviewRow(
            diarizerSpeakerId: "1",
            persistentSpeakerId: duplicate.id,
            currentName: "Dana",
            text: "Same person, second profile.",
            sessionEmbedding: embedding(0.21),
            matchedProfileSnapshot: snapshot
        )
        let meeting = try writeMeeting(harness: harness, rows: [row])
        submit(
            harness: harness,
            meeting: meeting,
            updates: [row.update(name: "Dana", action: .merged(targetProfileId: keeper.id))]
        )
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: duplicate.id), "same-named duplicates still merge")
        XCTAssertNotNil(harness.speakerDB.getSpeaker(id: keeper.id))
    }

    // MARK: - Rows sharing one profile

    @MainActor
    func testRowsSharingOneProfileCanBePickedAndTypedDifferently() async throws {
        let harness = try makeHarness()
        let shared = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.31), existingId: nil)
        let quinn = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.61), existingId: nil)
        harness.speakerDB.setDisplayName(id: quinn.id, name: "Quinn", source: NameSource.userManual)

        let first = ReviewRow(
            diarizerSpeakerId: "1",
            persistentSpeakerId: shared.id,
            text: "First voice.",
            sessionEmbedding: embedding(0.31)
        )
        let second = ReviewRow(
            diarizerSpeakerId: "2",
            persistentSpeakerId: shared.id,
            text: "Second voice.",
            sessionEmbedding: embedding(0.33)
        )
        let meeting = try writeMeeting(harness: harness, rows: [first, second])
        submit(
            harness: harness,
            meeting: meeting,
            updates: [
                first.update(name: "Quinn", action: .merged(targetProfileId: quinn.id)),
                second.update(name: "Ann", action: .named),
            ]
        )
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertTrue(harness.failedManager.failedTranscriptions.isEmpty)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: shared.id), "the first row's merge stands")
        XCTAssertNotNil(harness.speakerDB.getSpeaker(id: quinn.id))
        let ann = try XCTUnwrap(harness.speakerDB.allSpeakers().first { $0.displayName == "Ann" })
        XCTAssertNotEqual(ann.id, shared.id)
        XCTAssertNotEqual(ann.id, quinn.id)

        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Quinn] First voice."), saved)
        XCTAssertTrue(saved.contains("[System/Ann] Second voice."), saved)
        XCTAssertTrue(saved.contains(ann.id.uuidString), saved)
    }

    @MainActor
    func testRowsSharingOneProfileCanBePickedAsDifferentPeople() async throws {
        let harness = try makeHarness()
        let shared = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.35), existingId: nil)
        let quinn = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.62), existingId: nil)
        harness.speakerDB.setDisplayName(id: quinn.id, name: "Quinn", source: NameSource.userManual)
        let riley = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.72), existingId: nil)
        harness.speakerDB.setDisplayName(id: riley.id, name: "Riley", source: NameSource.userManual)
        let rileyBefore = try XCTUnwrap(harness.speakerDB.getSpeaker(id: riley.id))

        let first = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: shared.id, text: "Hello there.", sessionEmbedding: embedding(0.35))
        let second = ReviewRow(diarizerSpeakerId: "2", persistentSpeakerId: shared.id, text: "Hi back.", sessionEmbedding: embedding(0.36))
        let meeting = try writeMeeting(harness: harness, rows: [first, second])
        submit(
            harness: harness,
            meeting: meeting,
            updates: [
                first.update(name: "Quinn", action: .merged(targetProfileId: quinn.id)),
                second.update(name: "Riley", action: .merged(targetProfileId: riley.id)),
            ]
        )
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved, "two different picks for one profile used to fail the plan")
        XCTAssertNotNil(harness.speakerDB.getSpeaker(id: quinn.id))
        let rileyAfter = try XCTUnwrap(harness.speakerDB.getSpeaker(id: riley.id))
        XCTAssertEqual(rileyAfter.callCount, rileyBefore.callCount + 1, "the second row's voice is still learned")
        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Quinn] Hello there."), saved)
        XCTAssertTrue(saved.contains("[System/Riley] Hi back."), saved)
    }

    @MainActor
    func testRowsSharingOneProfileTypedAsDifferentNamesBecomeTwoPeople() async throws {
        let harness = try makeHarness()
        let shared = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.41), existingId: nil)
        let first = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: shared.id, text: "One.", sessionEmbedding: embedding(0.41))
        let second = ReviewRow(diarizerSpeakerId: "2", persistentSpeakerId: shared.id, text: "Two.", sessionEmbedding: embedding(0.44))
        let meeting = try writeMeeting(harness: harness, rows: [first, second])
        submit(
            harness: harness,
            meeting: meeting,
            updates: [
                first.update(name: "Casey", action: .named),
                second.update(name: "Drew", action: .named),
            ]
        )
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: shared.id)?.displayName, "Casey", "the first name keeps the profile")
        let drew = try XCTUnwrap(harness.speakerDB.allSpeakers().first { $0.displayName == "Drew" })
        XCTAssertNotEqual(drew.id, shared.id, "a second name must not rename the first person")
    }

    // MARK: - Profiles that changed while the review was open

    @MainActor
    func testPickedPersonMergedAwayBeforeSaveFollowsWhoAbsorbedThem() async throws {
        let harness = try makeHarness()
        let rowProfile = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.15), existingId: nil)
        let picked = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.81), existingId: nil)
        harness.speakerDB.setDisplayName(id: picked.id, name: "Morgan", source: NameSource.userManual)
        let keeper = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.82), existingId: nil)
        harness.speakerDB.setDisplayName(id: keeper.id, name: "Morgan", source: NameSource.userManual)

        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: rowProfile.id, text: "Morning all.", sessionEmbedding: embedding(0.15))
        let meeting = try writeMeeting(harness: harness, rows: [row])
        // Another meeting's duplicate cleanup folds the picked person into a keeper
        // while this review is still open.
        try harness.speakerDB.mergeProfiles(sourceId: picked.id, into: keeper.id)

        submit(
            harness: harness,
            meeting: meeting,
            updates: [row.update(name: "Morgan", action: .merged(targetProfileId: picked.id))]
        )
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: rowProfile.id))
        XCTAssertNotNil(harness.speakerDB.getSpeaker(id: keeper.id))
        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains(keeper.id.uuidString), saved)
        XCTAssertFalse(saved.contains(picked.id.uuidString), saved)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: keeper.id)?.confirmedMeetingCount, 1)
    }

    @MainActor
    func testPickedPersonDeletedBeforeSaveKeepsTheName() async throws {
        let harness = try makeHarness()
        let rowProfile = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.16), existingId: nil)
        let picked = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.83), existingId: nil)
        harness.speakerDB.setDisplayName(id: picked.id, name: "Jordan", source: NameSource.userManual)
        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: rowProfile.id, text: "Quick update.", sessionEmbedding: embedding(0.16))
        let meeting = try writeMeeting(harness: harness, rows: [row])
        harness.speakerDB.deleteSpeaker(id: picked.id)

        submit(
            harness: harness,
            meeting: meeting,
            updates: [row.update(name: "Jordan", action: .merged(targetProfileId: picked.id))]
        )
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: rowProfile.id)?.displayName, "Jordan")
        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Jordan] Quick update."), saved)
    }

    @MainActor
    func testRowProfilePrunedBeforeSaveIsRebuiltFromTheVoice() async throws {
        let harness = try makeHarness()
        let rowProfile = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.17), existingId: nil)
        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: rowProfile.id, text: "Let's begin.", sessionEmbedding: embedding(0.17))
        let meeting = try writeMeeting(harness: harness, rows: [row])
        harness.speakerDB.deleteSpeaker(id: rowProfile.id)

        submit(harness: harness, meeting: meeting, updates: [row.update(name: "Avery", action: .named)])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        let rebuilt = try XCTUnwrap(harness.speakerDB.getSpeaker(id: rowProfile.id), "the transcript link stays valid")
        XCTAssertEqual(rebuilt.displayName, "Avery")
        XCTAssertEqual(rebuilt.confirmedMeetingCount, 1)
    }

    @MainActor
    func testRowProfileGoneWithoutVoiceStillSavesTheName() async throws {
        let harness = try makeHarness()
        let rowProfile = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.18), existingId: nil)
        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: rowProfile.id, text: "No sample here.", sessionEmbedding: nil)
        let meeting = try writeMeeting(harness: harness, rows: [row])
        harness.speakerDB.deleteSpeaker(id: rowProfile.id)

        submit(harness: harness, meeting: meeting, updates: [row.update(name: "Blake", action: .named)])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved, "a missing confirmation row used to fail the save")
        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Blake] No sample here."), saved)
    }

    @MainActor
    func testOpenReviewProfilesAreProtectedUntilTheReviewFinishes() throws {
        let harness = try makeHarness()
        let rowProfile = UUID()
        let snapshotProfile = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.19), existingId: nil)
        let transcriptId = UUID()
        let request = SpeakerNamingRequest(
            speakers: [
                SpeakerNamingEntry(
                    id: rowProfile,
                    diarizerSpeakerId: "1",
                    clipURL: harness.paths.speakerClips.appendingPathComponent("protect.wav"),
                    sampleText: "Hello.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    matchedProfileSnapshot: snapshotProfile
                )
            ],
            transcriptURL: harness.paths.transcripts.appendingPathComponent("Protect.md"),
            transcriptId: transcriptId,
            systemAudioURL: harness.paths.audioCaptures.appendingPathComponent("protect-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        )

        harness.manager.enqueueSpeakerNamingRequest(request)
        XCTAssertEqual(
            harness.manager.speakerReviewProfileProtection.protectedProfileIds,
            [rowProfile, snapshotProfile.id]
        )

        // Save adds the people it is about to write to, only while the review is registered.
        let pickedTarget = UUID()
        harness.manager.speakerReviewProfileProtection.extend(requestId: request.id, transcriptId: transcriptId, with: [pickedTarget])
        harness.manager.speakerReviewProfileProtection.extend(requestId: UUID(), transcriptId: UUID(), with: [UUID()])
        XCTAssertEqual(
            harness.manager.speakerReviewProfileProtection.protectedProfileIds,
            [rowProfile, snapshotProfile.id, pickedTarget]
        )

        harness.manager.clearCompletedSpeakerNamingRequest(transcriptId: transcriptId, requestId: request.id)
        XCTAssertTrue(harness.manager.speakerReviewProfileProtection.protectedProfileIds.isEmpty)
        harness.manager.speakerReviewProfileProtection.extend(requestId: request.id, transcriptId: transcriptId, with: [pickedTarget])
        XCTAssertTrue(
            harness.manager.speakerReviewProfileProtection.protectedProfileIds.isEmpty,
            "a released review is never registered again"
        )
    }

    func testDuplicateCleanupAndPruneSkipProtectedProfiles() throws {
        let database = try makeHarnessDatabaseOnly()
        let protectedTwin = database.addOrUpdateSpeaker(embedding: embedding(0.5), existingId: nil)
        let otherTwin = database.addOrUpdateSpeaker(embedding: embedding(0.5), existingId: nil)
        database.mergeDuplicates(protecting: [protectedTwin.id])
        XCTAssertNotNil(database.getSpeaker(id: protectedTwin.id))
        XCTAssertNotNil(database.getSpeaker(id: otherTwin.id))

        // Age both profiles past the prune cutoff so only the protection keeps one.
        database.queue.sync {
            database.executeSQL("UPDATE speakers SET first_seen = '2020-01-01T00:00:00Z';")
        }
        database.pruneWeakProfiles(protecting: [protectedTwin.id])
        XCTAssertNotNil(database.getSpeaker(id: protectedTwin.id))
        XCTAssertNil(database.getSpeaker(id: otherTwin.id))
    }

    func testMergeSurvivorFollowsMergeChainToAnExistingProfile() throws {
        let database = try makeHarnessDatabaseOnly()
        let first = database.addOrUpdateSpeaker(embedding: embedding(0.1), existingId: nil)
        let middle = database.addOrUpdateSpeaker(embedding: embedding(0.1), existingId: nil)
        let last = database.addOrUpdateSpeaker(embedding: embedding(0.1), existingId: nil)
        try database.mergeProfiles(sourceId: first.id, into: middle.id)
        try database.mergeProfiles(sourceId: middle.id, into: last.id)

        XCTAssertEqual(database.mergeSurvivorId(of: first.id), last.id)
        XCTAssertEqual(database.mergeSurvivorId(of: middle.id), last.id)
        XCTAssertNil(database.mergeSurvivorId(of: last.id), "a profile that still exists was never merged")

        database.deleteSpeaker(id: last.id)
        XCTAssertNil(database.mergeSurvivorId(of: first.id), "no survivor when the end of the chain was deleted")
    }

    // MARK: - Rows that share one profile, planned in order

    @MainActor
    func testConfirmedRowFollowsSharedProfileMergedByAnEarlierRow() async throws {
        let harness = try makeHarness()
        let twin = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.31), existingId: nil)
        harness.speakerDB.setDisplayName(id: twin.id, name: "Casey", source: NameSource.userManual)
        let keeper = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.32), existingId: nil)
        harness.speakerDB.setDisplayName(id: keeper.id, name: "Casey", source: NameSource.userManual)
        let typed = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: twin.id, text: "First take.", sessionEmbedding: embedding(0.31))
        let confirmed = ReviewRow(
            diarizerSpeakerId: "2",
            persistentSpeakerId: twin.id,
            currentName: "Casey",
            text: "Second take.",
            sessionEmbedding: embedding(0.33)
        )
        let meeting = try writeMeeting(harness: harness, rows: [typed, confirmed])

        submit(harness: harness, meeting: meeting, updates: [
            typed.update(name: "Casey", action: .named),
            confirmed.update(name: "Casey", action: .confirmed),
        ])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: twin.id), "the first row merged the twin into the keeper")
        let caseys = harness.speakerDB.allSpeakers().filter { $0.displayName == "Casey" }
        XCTAssertEqual(caseys.map(\.id), [keeper.id], "the confirmed row must not mint a second Casey")
        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Casey] First take."), saved)
        XCTAssertTrue(saved.contains(keeper.id.uuidString), saved)
    }

    @MainActor
    func testConflictingNameWithoutVoiceIsSavedInTheTranscriptOnly() async throws {
        let harness = try makeHarness()
        let shared = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.34), existingId: nil)
        let first = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: shared.id, text: "Hi from one.", sessionEmbedding: embedding(0.34))
        let second = ReviewRow(diarizerSpeakerId: "2", persistentSpeakerId: shared.id, text: "Hi from two.", sessionEmbedding: nil)
        let meeting = try writeMeeting(harness: harness, rows: [first, second])
        let peopleBefore = harness.speakerDB.allSpeakers().count

        submit(harness: harness, meeting: meeting, updates: [
            first.update(name: "Casey", action: .named),
            second.update(name: "Drew", action: .named),
        ])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved, "a second name with no voice used to fail the whole save")
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: shared.id)?.displayName, "Casey")
        XCTAssertEqual(harness.speakerDB.allSpeakers().count, peopleBefore, "no voice, so no new saved person")
        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Casey] Hi from one."), saved)
        XCTAssertTrue(saved.contains("[System/Drew] Hi from two."), saved)
        XCTAssertEqual(persistedClipSpeakerIds(harness), [shared.id], "no review clip for a name with no saved person")
    }

    @MainActor
    func testTranscriptOnlyNameJoinsTheSamePersonTypedOnAnotherRow() async throws {
        let harness = try makeHarness()
        let shared = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.38), existingId: nil)
        let other = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.39), existingId: nil)
        let first = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: shared.id, text: "One here.", sessionEmbedding: embedding(0.38))
        let second = ReviewRow(diarizerSpeakerId: "2", persistentSpeakerId: shared.id, text: "Two here.", sessionEmbedding: nil)
        let third = ReviewRow(diarizerSpeakerId: "3", persistentSpeakerId: other.id, text: "Three here.", sessionEmbedding: embedding(0.39))
        let meeting = try writeMeeting(harness: harness, rows: [first, second, third])

        submit(harness: harness, meeting: meeting, updates: [
            first.update(name: "Casey", action: .named),
            second.update(name: "Drew", action: .named),
            third.update(name: "Drew", action: .named),
        ])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: other.id)?.displayName, "Drew")
        let saved = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Drew] Two here."), saved)
        XCTAssertEqual(
            saved.components(separatedBy: "db_id: \"\(other.id.uuidString)\"").count - 1,
            2,
            "both Drew rows link the one saved Drew\n\(saved)"
        )
    }

    @MainActor
    func testNoDialogPickOfARemovedPersonDoesNotRenameTheRowProfile() async throws {
        let harness = try makeHarness()
        let speaking = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.35), existingId: nil)
        let silent = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.36), existingId: nil)
        let removed = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.37), existingId: nil)
        harness.speakerDB.setDisplayName(id: removed.id, name: "Toby", source: NameSource.userManual)
        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: speaking.id, text: "Only I spoke.", sessionEmbedding: embedding(0.35))
        let meeting = try writeMeeting(harness: harness, rows: [row])
        harness.speakerDB.deleteSpeaker(id: removed.id)
        let silentUpdate = SpeakerNameUpdate(
            persistentSpeakerId: silent.id,
            diarizerSpeakerId: "9",
            newName: "Toby",
            previousName: nil,
            action: .merged(targetProfileId: removed.id)
        )

        submit(harness: harness, meeting: meeting, updates: [row.update(name: "Quinn", action: .named), silentUpdate])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: silent.id)?.displayName, "a speaker with no dialog must not take the removed person's name")
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: speaking.id)?.displayName, "Quinn")
    }

    @MainActor
    func testNoDialogRelabelToARemovedPersonDoesNotCreateAPerson() async throws {
        let harness = try makeHarness()
        let speaking = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.51), existingId: nil)
        let alice = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.52), existingId: nil)
        harness.speakerDB.setDisplayName(id: alice.id, name: "Alice", source: NameSource.userManual)
        let aliceSnapshot = try XCTUnwrap(harness.speakerDB.getSpeaker(id: alice.id))
        let removed = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.53), existingId: nil)
        harness.speakerDB.setDisplayName(id: removed.id, name: "Toby", source: NameSource.userManual)
        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: speaking.id, text: "Only I spoke.", sessionEmbedding: embedding(0.51))
        let written = try writeMeeting(harness: harness, rows: [row])
        let silentClip = harness.paths.speakerClips.appendingPathComponent("silent-9.wav")
        try Data().write(to: silentClip)
        let meeting = WrittenMeeting(
            transcriptId: written.transcriptId,
            transcriptURL: written.transcriptURL,
            micURL: written.micURL,
            systemURL: written.systemURL,
            rows: written.rows,
            entries: written.entries + [SpeakerNamingEntry(
                id: alice.id,
                diarizerSpeakerId: "9",
                clipURL: silentClip,
                sampleText: "",
                currentName: "Alice",
                matchSimilarity: 0.8,
                needsNaming: false,
                needsConfirmation: true,
                sessionEmbedding: embedding(0.54),
                matchedProfileSnapshot: aliceSnapshot
            )],
            result: written.result
        )
        harness.speakerDB.deleteSpeaker(id: removed.id)
        let relabel = SpeakerNameUpdate(
            persistentSpeakerId: alice.id,
            diarizerSpeakerId: "9",
            newName: "Toby",
            previousName: "Alice",
            action: .merged(targetProfileId: removed.id)
        )

        submit(harness: harness, meeting: meeting, updates: [row.update(name: "Quinn", action: .named), relabel])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertTrue(
            harness.speakerDB.allSpeakers().filter { $0.displayName == "Toby" }.isEmpty,
            "a silent voice must not become a new saved Toby"
        )
        let aliceAfter = try XCTUnwrap(harness.speakerDB.getSpeaker(id: alice.id))
        XCTAssertEqual(aliceAfter.displayName, "Alice")
        XCTAssertEqual(aliceAfter.disputeCount, aliceSnapshot.disputeCount + 1, "the rejection still counts")
    }

    // MARK: - People removed after planning, before the batch runs

    func testTeachingAVoiceNeverRecreatesARemovedPerson() throws {
        let database = try makeHarnessDatabaseOnly()
        let deleted = database.addOrUpdateSpeaker(embedding: embedding(0.41), existingId: nil)
        let absorbed = database.addOrUpdateSpeaker(embedding: embedding(0.42), existingId: nil)
        let survivor = database.addOrUpdateSpeaker(embedding: embedding(0.42), existingId: nil)
        try database.mergeProfiles(sourceId: absorbed.id, into: survivor.id)
        database.deleteSpeaker(id: deleted.id)
        let survivorCallsBefore = try XCTUnwrap(database.getSpeaker(id: survivor.id)).callCount

        try TranscriptionTaskManager.applyPlannedNamingMutations([
            .teachVoice(embedding: embedding(0.43), profileId: deleted.id),
            .teachVoice(embedding: embedding(0.43), profileId: absorbed.id),
        ], speakerDB: database)

        XCTAssertNil(database.getSpeaker(id: deleted.id), "a deleted person stays deleted")
        XCTAssertNil(database.getSpeaker(id: absorbed.id), "a merged-away person is not brought back")
        XCTAssertEqual(database.getSpeaker(id: survivor.id)?.callCount, survivorCallsBefore + 1, "the voice follows the merge")
    }

    func testMergeIntoARemovedPersonFollowsTheSurvivorOrIsSkipped() throws {
        let database = try makeHarnessDatabaseOnly()
        let rowToFollow = database.addOrUpdateSpeaker(embedding: embedding(0.44), existingId: nil)
        let rowToKeep = database.addOrUpdateSpeaker(embedding: embedding(0.45), existingId: nil)
        let absorbedTarget = database.addOrUpdateSpeaker(embedding: embedding(0.46), existingId: nil)
        let survivor = database.addOrUpdateSpeaker(embedding: embedding(0.46), existingId: nil)
        let deletedTarget = database.addOrUpdateSpeaker(embedding: embedding(0.47), existingId: nil)
        try database.mergeProfiles(sourceId: absorbedTarget.id, into: survivor.id)
        database.deleteSpeaker(id: deletedTarget.id)

        XCTAssertNoThrow(try TranscriptionTaskManager.applyPlannedNamingMutations([
            .merge(sourceId: rowToFollow.id, into: absorbedTarget.id),
            .merge(sourceId: rowToKeep.id, into: deletedTarget.id),
        ], speakerDB: database), "a target removed after planning used to throw and fail the save")

        XCTAssertNil(database.getSpeaker(id: rowToFollow.id), "merged into whoever absorbed the picked person")
        XCTAssertEqual(database.mergeSurvivorId(of: rowToFollow.id), survivor.id)
        XCTAssertNotNil(database.getSpeaker(id: rowToKeep.id), "nothing to merge into, so the row's person is left alone")
        XCTAssertNil(database.getSpeaker(id: deletedTarget.id))
    }

    func testVerdictsFollowAPersonMergedAfterPlanning() throws {
        let database = try makeHarnessDatabaseOnly()
        let absorbed = database.addOrUpdateSpeaker(embedding: embedding(0.48), existingId: nil)
        let survivor = database.addOrUpdateSpeaker(embedding: embedding(0.48), existingId: nil)
        try database.mergeProfiles(sourceId: absorbed.id, into: survivor.id)
        let disputesBefore = try XCTUnwrap(database.getSpeaker(id: survivor.id)).disputeCount

        try TranscriptionTaskManager.applyPlannedNamingMutations([
            .incrementDisputeCount(absorbed.id),
            .recordNegativeExemplar(profileId: absorbed.id, embedding: embedding(0.49)),
        ], speakerDB: database)

        XCTAssertEqual(database.getSpeaker(id: survivor.id)?.disputeCount, disputesBefore + 1)
        XCTAssertEqual(database.negativeExemplarsByProfile()[survivor.id]?.count, 1)
        XCTAssertNil(database.negativeExemplarsByProfile()[absorbed.id], "no exemplar for a person who is gone")
    }

    func testMergeStepThatTouchesNoRowIsReportedAsAMergeFailure() {
        let error = SpeakerFinalizationFailureReason.mergeError(
            from: SpeakerDatabase.SQLiteOperationError(operation: "step speaker confirmation move", code: SQLITE_NOTFOUND, detail: ""),
            sourceId: UUID(),
            targetId: UUID()
        )
        XCTAssertEqual(SpeakerFinalizationFailureReason.classify(databaseError: error), .mergeProfileMissing)

        let other = SpeakerFinalizationFailureReason.mergeError(
            from: SpeakerDatabase.SQLiteOperationError(operation: "step merge target update", code: SQLITE_FULL, detail: ""),
            sourceId: UUID(),
            targetId: UUID()
        )
        XCTAssertEqual(SpeakerFinalizationFailureReason.classify(databaseError: other), .databaseWriteFailed)
    }

    // MARK: - Failure reasons

    @MainActor
    func testDatabaseWriteFailureReportsItsReason() async throws {
        let harness = try makeHarness()
        let rowProfile = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.23), existingId: nil)
        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: rowProfile.id, text: "Denied write.", sessionEmbedding: embedding(0.23))
        let meeting = try writeMeeting(harness: harness, rows: [row])
        let original = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)

        let authorizerResult = harness.speakerDB.queue.sync {
            sqlite3_set_authorizer(harness.speakerDB.db, { _, action, tableName, _, _, _ in
                guard action == SQLITE_UPDATE,
                      let tableName,
                      String(cString: tableName) == "speakers" else {
                    return SQLITE_OK
                }
                return SQLITE_DENY
            }, nil)
        }
        XCTAssertEqual(authorizerResult, SQLITE_OK)
        defer {
            _ = harness.speakerDB.queue.sync {
                sqlite3_set_authorizer(harness.speakerDB.db, nil, nil)
            }
        }

        submit(harness: harness, meeting: meeting, updates: [row.update(name: "Emery", action: .named)])
        try await waitUntil {
            if case .failed = harness.manager.displayStatus,
               harness.manager.speakerNamingRequest == nil {
                return true
            }
            return false
        }

        XCTAssertEqual(
            harness.manager.lastSpeakerFinalizationFailure,
            SpeakerFinalizationFailure(reason: .databaseWriteFailed, reviewMode: .save, isRetry: false)
        )
        XCTAssertEqual(try String(contentsOf: meeting.transcriptURL, encoding: .utf8), original)
    }

    @MainActor
    func testCorrectionWithoutVoiceReportsMissingEmbeddingReason() async throws {
        let harness = try makeHarness()
        let recognized = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.24), existingId: nil)
        harness.speakerDB.setDisplayName(id: recognized.id, name: "Frankie", source: NameSource.userManual)
        let snapshot = try XCTUnwrap(harness.speakerDB.getSpeaker(id: recognized.id))
        let row = ReviewRow(
            diarizerSpeakerId: "1",
            persistentSpeakerId: recognized.id,
            currentName: "Frankie",
            text: "Not Frankie.",
            sessionEmbedding: nil,
            matchedProfileSnapshot: snapshot
        )
        let meeting = try writeMeeting(harness: harness, rows: [row])

        submit(harness: harness, meeting: meeting, updates: [row.update(name: "Gray", action: .corrected)])
        try await waitUntil {
            if case .failed = harness.manager.displayStatus,
               harness.manager.speakerNamingRequest == nil {
                return true
            }
            return false
        }

        XCTAssertEqual(harness.manager.lastSpeakerFinalizationFailure?.reason, .planMissingEmbedding)
    }

    @MainActor
    func testSuccessfulSaveClearsAnEarlierFailureReason() async throws {
        let harness = try makeHarness()
        let rowProfile = harness.speakerDB.addOrUpdateSpeaker(embedding: embedding(0.25), existingId: nil)
        let row = ReviewRow(diarizerSpeakerId: "1", persistentSpeakerId: rowProfile.id, text: "All good.", sessionEmbedding: embedding(0.25))
        let meeting = try writeMeeting(harness: harness, rows: [row])
        harness.manager.publishSpeakerFinalizationFailure(
            displayMessage: "Failed to finalize speaker names",
            failure: SpeakerFinalizationFailure(reason: .nameRewriteFailed, reviewMode: .save, isRetry: false)
        )

        submit(harness: harness, meeting: meeting, updates: [row.update(name: "Harper", action: .named)])
        try await waitForSave(harness)

        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertNil(harness.manager.lastSpeakerFinalizationFailure)
        XCTAssertNil(harness.manager.lastFailureDiagnosticMessage)
    }

    func testDatabaseErrorsMapToCoarseReasons() {
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(
                databaseError: SpeakerDatabase.ProfileMergeError.profileNotFound(sourceId: UUID(), targetId: UUID())
            ),
            .mergeProfileMissing
        )
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(
                databaseError: SpeakerDatabase.ProfileMergeError.invalidEmbeddingState(sourceId: UUID(), targetId: UUID())
            ),
            .mergeEmbeddingInvalid
        )
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(
                databaseError: SpeakerDatabase.SQLiteOperationError(operation: "record speaker confirmation", code: SQLITE_NOTFOUND, detail: "")
            ),
            .confirmationProfileMissing
        )
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(
                databaseError: SpeakerDatabase.SQLiteOperationError(operation: "step merge target update", code: SQLITE_NOTFOUND, detail: "")
            ),
            .mergeProfileMissing
        )
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(
                databaseError: SpeakerDatabase.SQLiteOperationError(operation: "step profile update", code: SQLITE_NOTFOUND, detail: "")
            ),
            .databaseWriteFailed
        )
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(
                databaseError: SpeakerDatabase.SQLiteOperationError(operation: "write", code: SQLITE_MISUSE, detail: "")
            ),
            .databaseUnavailable
        )
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(
                databaseError: SpeakerDatabase.SQLiteOperationError(operation: "write", code: SQLITE_FULL, detail: "")
            ),
            .databaseWriteFailed
        )
        XCTAssertEqual(
            SpeakerFinalizationFailureReason.classify(databaseError: CocoaError(.fileWriteUnknown)),
            .databaseWriteFailed
        )
        for reason in SpeakerFinalizationFailureReason.allCases {
            XCTAssertNotNil(
                reason.rawValue.range(of: "^[a-z_]+$", options: .regularExpression),
                "\(reason.rawValue) must stay a coarse snake_case code"
            )
        }
    }

    // MARK: - Harness

    private struct ReviewRow {
        let diarizerSpeakerId: String
        let persistentSpeakerId: UUID
        var currentName: String? = nil
        let text: String
        let sessionEmbedding: [Float]?
        var matchedProfileSnapshot: SpeakerProfile? = nil

        var label: String { currentName ?? "Speaker \(diarizerSpeakerId)" }

        func update(name: String, action: SpeakerNameUpdate.NamingAction) -> SpeakerNameUpdate {
            SpeakerNameUpdate(
                persistentSpeakerId: persistentSpeakerId,
                diarizerSpeakerId: diarizerSpeakerId,
                newName: name,
                previousName: currentName,
                action: action
            )
        }
    }

    private struct WrittenMeeting {
        let transcriptId: UUID
        let transcriptURL: URL
        let micURL: URL
        let systemURL: URL
        let rows: [ReviewRow]
        let entries: [SpeakerNamingEntry]
        let result: TranscriptionResult
    }

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNameSaveReliabilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    private func embedding(_ value: Float) -> [Float] {
        // Test voices only need to be valid, non-zero vectors; these tests do not rely on
        // cosine similarity telling them apart (they are all close in direction).
        (0..<256).map { index in index % 7 == 0 ? value : value * 0.5 + Float(index % 5) * 0.01 }
    }

    /// Speaker ids that have a persisted review clip (`<id>.wav`) in the clips folder.
    private func persistedClipSpeakerIds(_ harness: SaveReliabilityHarness) -> Set<UUID> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: harness.paths.speakerClips.path)) ?? []
        return Set(files.compactMap { file in
            guard file.hasSuffix(".wav") else { return nil }
            return UUID(uuidString: String(file.dropLast(4)))
        })
    }

    private func makeHarnessDatabaseOnly() throws -> SpeakerDatabase {
        SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers-only.sqlite").path)
    }

    @MainActor
    private func makeHarness() throws -> SaveReliabilityHarness {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )
        for directory in [paths.transcripts, paths.audioCaptures, paths.speakerClips, paths.logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let failedManager = FailedTranscriptionManager(paths: paths)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: failedManager,
            speechToText: SaveReliabilitySpeechStub(),
            diarization: SaveReliabilityDiarizationStub(),
            speakerStore: speakerDB,
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips]
        )
        return SaveReliabilityHarness(paths: paths, speakerDB: speakerDB, failedManager: failedManager, manager: manager)
    }

    private func writeMeeting(harness: SaveReliabilityHarness, rows: [ReviewRow]) throws -> WrittenMeeting {
        let transcriptId = UUID()
        let stem = UUID().uuidString
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Meeting-\(stem).md")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("\(stem)-mic.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("\(stem)-system.wav")

        let speakersYAML = rows.map { row in
            """
              - id: "\(row.diarizerSpeakerId)"
                db_id: "\(row.persistentSpeakerId.uuidString)"
                name: "\(row.label)"
                confidence: unknown
                source: db_pending
            """
        }.joined(separator: "\n")
        let body = rows.enumerated().map { index, row in
            "[00:0\(index + 1)] [System/\(row.label)] \(row.text)"
        }.joined(separator: "\n\n")
        let breakdown = rows.map { row in
            "- **\(row.label):** 1 utterances, ~\(row.text.split(separator: " ").count) words, 00:03"
        }.joined(separator: "\n")
        let totalWords = rows.reduce(0) { $0 + $1.text.split(separator: " ").count }

        let transcript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: \(rows.count)
        mic_speakers: 0
        system_speakers: \(rows.count)
        total_word_count: \(totalWords)
        speakers:
        \(speakersYAML)
        ---

        # Meeting Recording - Apr 10, 2026 at 3:01 PM

        **Duration:** 1:30 | **Words:** \(totalWords) | **Utterances:** \(rows.count)

        ---

        ## Channel & Speaker Analytics

        ### Microphone (You)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00

        ### Meeting Audio (Remote Participants)
        - **Utterances:** \(rows.count)
        - **Words:** ~\(totalWords)
        - **Speaking Time:** 00:03
        - **Speakers Detected:** \(rows.count)

        #### Remote Speaker Breakdown

        \(breakdown)

        ---

        ## Full Transcript

        \(body)

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 1:30 | \(totalWords) words | \(rows.count) speakers*
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        var entries: [SpeakerNamingEntry] = []
        for row in rows {
            let clipURL = harness.paths.speakerClips.appendingPathComponent("\(stem)-\(row.diarizerSpeakerId).wav")
            try Data().write(to: clipURL)
            entries.append(SpeakerNamingEntry(
                id: row.persistentSpeakerId,
                diarizerSpeakerId: row.diarizerSpeakerId,
                clipURL: clipURL,
                sampleText: row.text,
                currentName: row.currentName,
                matchSimilarity: row.matchedProfileSnapshot == nil ? nil : 0.8,
                needsNaming: row.currentName == nil,
                needsConfirmation: row.currentName != nil,
                sessionEmbedding: row.sessionEmbedding,
                matchedProfileSnapshot: row.matchedProfileSnapshot
            ))
        }

        let utterances = rows.enumerated().map { index, row in
            TranscriptionUtterance(
                start: Double(index + 1),
                end: Double(index + 1) + 3,
                channel: 1,
                speakerId: Int(row.diarizerSpeakerId) ?? 0,
                persistentSpeakerId: row.persistentSpeakerId,
                matchSimilarity: nil,
                transcript: row.text
            )
        }
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: utterances,
            duration: 90,
            processingTime: 3.0
        )
        return WrittenMeeting(
            transcriptId: transcriptId,
            transcriptURL: transcriptURL,
            micURL: micURL,
            systemURL: systemURL,
            rows: rows,
            entries: entries,
            result: result
        )
    }

    @MainActor
    private func submit(harness: SaveReliabilityHarness, meeting: WrittenMeeting, updates: [SpeakerNameUpdate]) {
        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: meeting.transcriptURL,
            transcriptId: meeting.transcriptId,
            systemAudioURL: meeting.systemURL,
            micAudioURL: meeting.micURL,
            onComplete: { _ in }
        )
        harness.manager.handleNamingComplete(
            updates: updates,
            transcriptURL: meeting.transcriptURL,
            transcriptId: meeting.transcriptId,
            transcriptionResult: meeting.result,
            micURL: meeting.micURL,
            systemURL: meeting.systemURL,
            clips: meeting.entries
        )
    }

    @MainActor
    private func waitForSave(_ harness: SaveReliabilityHarness) async throws {
        try await waitUntil {
            guard harness.manager.speakerNamingRequest == nil else { return false }
            switch harness.manager.displayStatus {
            case .transcriptSaved, .failed:
                return true
            default:
                return false
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 3.0,
        condition: @escaping @Sendable @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

@available(macOS 14.0, *)
private struct SaveReliabilityHarness {
    let paths: CoreStoragePaths
    let speakerDB: SpeakerDatabase
    let failedManager: FailedTranscriptionManager
    let manager: TranscriptionTaskManager
}

@available(macOS 14.0, *)
@MainActor
private final class SaveReliabilitySpeechStub: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true

    func initialize() async {}

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        ""
    }

    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class SaveReliabilityDiarizationStub: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true

    func initialize() async {}

    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        []
    }

    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        []
    }

    func cleanup() {}
}
