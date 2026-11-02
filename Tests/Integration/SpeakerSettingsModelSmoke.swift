import Combine
import Foundation
import SQLite3
import TranscriptedCore

/// Actual model/store integration with a fresh database, Markdown and defaults
/// for each promise. It does not launch the app or use audio, Calendar or TCC.
@main struct SpeakerSettingsModelSmoke {
    @MainActor static var assertions = 0

    @MainActor static func check(_ condition: Bool, _ promise: String) {
        guard condition else { fatalError("FAIL: \(promise)") }
        assertions += 1
    }

    @MainActor final class Fixture {
        let root: URL
        let transcripts: URL
        let clips: URL
        let database: SpeakerDatabase
        let defaults: UserDefaults
        let suite: String
        var model: SpeakerPeopleSettingsViewModel?

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerSettingsModel-\(UUID().uuidString)", isDirectory: true)
            transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
            clips = root.appendingPathComponent("clips", isDirectory: true)
            try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            database = SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path, adoptCanonicalModelIdentity: false)
            suite = "SpeakerSettingsModel.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
        }

        func close() throws {
            model = nil
            defaults.removePersistentDomain(forName: suite)
            guard root.lastPathComponent.hasPrefix("SpeakerSettingsModel-"),
                  root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL
            else { fatalError("Refusing to clean outside the smoke's temporary root") }
            try FileManager.default.removeItem(at: root)
        }

        func voice(name: String? = nil, embedding: [Float] = [1, 0]) throws -> SpeakerProfile {
            let profile = database.addOrUpdateSpeaker(embedding: embedding, existingId: nil)
            if let name { database.setDisplayName(id: profile.id, name: name, source: NameSource.userManual) }
            try Data([0]).write(to: clips.appendingPathComponent("\(profile.id.uuidString).wav"))
            return database.getSpeaker(id: profile.id)!
        }

        func writeQuotedClip(for id: UUID, quote: String, bytes: Data = Data([1, 2, 3, 4, 5])) throws {
            let wav = clips.appendingPathComponent("\(id.uuidString).wav")
            try bytes.write(to: wav)
            let sidecar = SpeakerClipSidecar(
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [.init(start: 0, end: 1, text: quote)],
                sampleText: quote
            )
            guard let stamped = sidecar.stamped(withWavAt: wav) else {
                fatalError("quoted clip must stamp against its wav")
            }
            try stamped.write(nextTo: wav)
        }

        func clipURL(for id: UUID) -> URL {
            clips.appendingPathComponent("\(id.uuidString).wav")
        }

        func sidecarURL(for id: UUID) -> URL {
            SpeakerClipSidecar.url(nextTo: clipURL(for: id))
        }

        func meeting(voice: SpeakerProfile, id: UUID = UUID(), filename: String, rows: Int = 1) throws -> URL {
            let url = transcripts.appendingPathComponent(filename).appendingPathExtension("md")
            let speakers = (1...rows).map { index in
                """
                  - id: "\(index)"
                    channel: system
                    db_id: "\(voice.id.uuidString)"
                    name: "Speaker \(index)"
                    source: db_pending
                """
            }.joined(separator: "\n")
            let lines = (1...rows).map { "[00:0\($0)] [System/Speaker \($0)] Synthetic words." }.joined(separator: "\n")
            try """
            ---
            title: "Synthetic call"
            transcript_id: "\(id.uuidString)"
            capture_type: meeting
            date: "2026-01-01"
            duration: "00:30"
            speakers:
            \(speakers)
            ---
            ## Full Transcript
            \(lines)
            """.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func load() async -> SpeakerPeopleSettingsViewModel {
            let store = SpeakerSettingsStore(speakerDatabase: database, transcriptDirectory: transcripts,
                preferredClipsDirectory: clips, legacyClipsDirectory: clips)
            let loaded = SpeakerPeopleSettingsViewModel(speakerDatabase: store, transcriptDirectory: transcripts,
                preferredClipsDirectory: clips, legacyClipsDirectory: clips, reviewDefaults: defaults)
            model = loaded
            // @Published emits before its setter finishes. Resume the awaiting
            // actor after the whole snapshot has published, without sleeps.
            await withCheckedContinuation { continuation in
                var observation: AnyCancellable?
                observation = loaded.$profiles.dropFirst().sink { _ in
                    guard loaded.hasLoadedProfiles else { return }
                    observation?.cancel()
                    observation = nil
                    continuation.resume()
                }
            }
            return loaded
        }
    }

    @MainActor static func save(_ model: SpeakerPeopleSettingsViewModel, item: SpeakerPendingReviewItem, name: String) async -> SpeakerReviewNamedVoice? {
        await withCheckedContinuation { continuation in
            model.saveReviewName(item, to: name) { continuation.resume(returning: $0) }
        }
    }

    @MainActor static func newNameConfirmsAllDistinctMeetings() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice()
        let first = try fixture.meeting(voice: voice, filename: "first")
        let second = try fixture.meeting(voice: voice, filename: "second")
        let model = await fixture.load()
        check(model.reviewQueueItems.count == 2, "snapshot reads only the supplied synthetic meetings")
        let saved = await save(model, item: model.reviewQueueItems[0], name: "  Alex  ")
        check(saved?.name == "Alex" && saved?.personID == voice.id && saved?.isNewPerson == true,
            "new name is trimmed and keeps the reviewed identity")
        check(saved?.confirmedBefore == 0 && saved?.confirmedAfter == 2,
            "one answer returns the two distinct persisted confirmations")
        check(model.profiles.first?.displayName == "Alex" && model.reviewQueueItems.isEmpty,
            "completion runs after the named profile and empty queue publish")
        check(fixture.database.getSpeaker(id: voice.id)?.confirmedMeetingCount == 2,
            "returned progress matches the actual database")
        for file in [first, second] {
            let contents = try String(contentsOf: file, encoding: .utf8)
            check(contents.contains("Alex") && !SpeakerReviewQueueScanner.hasPendingSpeakers(in: contents),
                "each saved meeting names the voice and retires its review")
        }
    }

    @MainActor static func existingNameJoinsAndDeduplicatesMeetings() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice()
        let person = try fixture.voice(name: "Alex", embedding: [0, 1])
        let sharedMeeting = UUID()
        try fixture.database.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: person.id, transcriptId: sharedMeeting, kind: .confirmed),
            SpeakerUserConfirmation(profileId: person.id, transcriptId: UUID(), kind: .confirmed)
        ])
        let first = try fixture.meeting(voice: voice, id: sharedMeeting, filename: "duplicate-rows", rows: 2)
        let second = try fixture.meeting(voice: voice, filename: "new-meeting")
        let model = await fixture.load()
        check(model.reviewQueueItems.count == 3, "two rows in one meeting remain available to the transaction")
        let saved = await save(model, item: model.reviewQueueItems[0], name: " alex ")
        check(saved?.personID == person.id && saved?.name == "Alex" && saved?.isNewPerson == false,
            "typing an existing name joins the saved person")
        check(saved?.confirmedBefore == 2 && saved?.confirmedAfter == 3,
            "shared meetings and duplicate rows count once after joining")
        check(fixture.database.getSpeaker(id: voice.id) == nil && model.profiles.count == 1,
            "the source voice is merged before completion")
        check(model.reviewQueueItems.isEmpty && model.profiles[0].confirmedMeetingCount == 3,
            "completion sees the refreshed queue and kept person's progress")
        for file in [first, second] {
            let contents = try String(contentsOf: file, encoding: .utf8)
            check(contents.contains(person.id.uuidString) && !contents.contains(voice.id.uuidString),
                "all reviewed rows point at the kept person")
        }
    }

    @MainActor static func failedSaveReturnsNoCelebrationOrMutation() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice()
        let first = try fixture.meeting(voice: voice, filename: "present")
        let second = try fixture.meeting(voice: voice, filename: "moved")
        let original = try String(contentsOf: first, encoding: .utf8)
        let model = await fixture.load()
        let item = model.reviewQueueItems[0]
        try FileManager.default.removeItem(at: second)
        let saved = await save(model, item: item, name: "Alex")
        check(saved == nil, "a failed transcript transaction returns no saved card result")
        let unchanged = fixture.database.getSpeaker(id: voice.id)
        check(unchanged?.displayName == nil && unchanged?.confirmedMeetingCount == 0,
            "a failed save leaves identity and confirmation count unchanged")
        check(try String(contentsOf: first, encoding: .utf8) == original,
            "a failed save restores the other reviewed meeting")
        check(model.profiles.first?.displayName == nil && model.reviewQueueItems.count == 1,
            "failed completion also sees a refreshed snapshot")
    }

    @MainActor static func databaseRejectionRestoresWrittenMeetings() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice()
        let first = try fixture.meeting(voice: voice, filename: "first")
        let second = try fixture.meeting(voice: voice, filename: "second")
        let originals = try [first, second].map { try String(contentsOf: $0, encoding: .utf8) }
        let model = await fixture.load()
        var connection: OpaquePointer?
        let opened = sqlite3_open(fixture.root.appendingPathComponent("speakers.sqlite").path, &connection)
        check(opened == SQLITE_OK, "failure injection opens only the temporary database")
        defer { sqlite3_close(connection) }
        // Fail the identity step after production has rewritten the Markdown.
        // This exercises its real file rollback rather than faking a store.
        let trigger = sqlite3_exec(connection, """
            CREATE TRIGGER reject_test_name BEFORE UPDATE OF display_name ON speakers
            BEGIN SELECT RAISE(ABORT, 'synthetic identity rejection'); END;
            """, nil, nil, nil)
        check(trigger == SQLITE_OK, "synthetic database rejection is installed")
        let saved = await save(model, item: model.reviewQueueItems[0], name: "Alex")
        check(saved == nil, "identity rejection returns no saved result")
        check(fixture.database.getSpeaker(id: voice.id)?.displayName == nil
              && fixture.database.getSpeaker(id: voice.id)?.confirmedMeetingCount == 0,
            "rejected identity leaves the actual database unchanged")
        for (file, original) in zip([first, second], originals) {
            check(try String(contentsOf: file, encoding: .utf8) == original,
                "identity rejection restores every rewritten meeting")
        }
        check(model.reviewQueueItems.count == 2 && model.profiles.first?.displayName == nil,
            "rejected completion publishes the restored queue")
    }

    @MainActor static func thisIsMeJoinsExistingOwnerBeforeCompletion() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice()
        let owner = try fixture.voice(name: SpeakerNameSelectionPolicy.ownerLabel, embedding: [0, 1])
        _ = try fixture.meeting(voice: voice, filename: "mine")
        let model = await fixture.load()
        let saved = await withCheckedContinuation { continuation in
            model.markReviewVoiceAsMe(model.reviewQueueItems[0]) { continuation.resume(returning: $0) }
        }
        check(saved?.personID == owner.id && saved?.confirmedAfter == 1,
            "This is me reports the existing You after the voice joined it")
        check(fixture.database.getSpeaker(id: voice.id) == nil && model.profiles.count == 1,
            "This is me leaves a single You profile")
    }

    @MainActor static func failedDeleteKeepsVoiceClip() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice(name: "Alex")
        let clip = fixture.clips.appendingPathComponent("\(voice.id.uuidString).wav")
        let model = await fixture.load()
        var connection: OpaquePointer?
        let opened = sqlite3_open(fixture.root.appendingPathComponent("speakers.sqlite").path, &connection)
        check(opened == SQLITE_OK, "failure injection opens only the temporary database")
        defer { sqlite3_close(connection) }
        let trigger = sqlite3_exec(connection, """
            CREATE TRIGGER reject_test_delete BEFORE DELETE ON speakers
            BEGIN SELECT RAISE(ABORT, 'synthetic delete rejection'); END;
            """, nil, nil, nil)
        check(trigger == SQLITE_OK, "synthetic delete rejection is installed")
        let didDelete = await withCheckedContinuation { continuation in
            model.delete(profile: model.profiles[0]) { continuation.resume(returning: $0) }
        }
        check(!didDelete && fixture.database.getSpeaker(id: voice.id) != nil,
            "a rejected delete reports failure and keeps the person")
        check(FileManager.default.fileExists(atPath: clip.path), "a rejected delete keeps the voice clip")
    }

    @MainActor static func failedMergeKeepsSourceProfileAndClip() async throws {
        let fixture = try Fixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.clips.path
            )
            try? fixture.close()
        }
        let source = try fixture.voice(name: "Alex")
        let target = try fixture.voice(name: "Blake", embedding: [0, 1])
        let sourceClip = fixture.clips.appendingPathComponent("\(source.id.uuidString).wav")
        let targetClip = fixture.clips.appendingPathComponent("\(target.id.uuidString).wav")
        try FileManager.default.removeItem(at: targetClip)
        check(FileManager.default.fileExists(atPath: sourceClip.path), "source starts with a clip")
        check(!FileManager.default.fileExists(atPath: targetClip.path), "kept person has no clip to inherit")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.clips.path
        )
        let model = await fixture.load()
        let sourceRow = model.profiles.first { $0.id == source.id }
        let targetRow = model.profiles.first { $0.id == target.id }
        check(sourceRow != nil && targetRow != nil, "both people are in the Speakers snapshot")
        let didMerge = await withCheckedContinuation { continuation in
            model.merge(source: sourceRow!, into: targetRow!) { continuation.resume(returning: $0) }
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.clips.path
        )
        check(!didMerge, "a failed clip copy must not merge the people")
        check(
            fixture.database.getSpeaker(id: source.id) != nil,
            "the source person stays when the clip cannot move"
        )
        check(
            FileManager.default.fileExists(atPath: sourceClip.path),
            "the source clip stays with the source person"
        )
        check(
            !FileManager.default.fileExists(atPath: targetClip.path),
            "a failed copy must not leave a partial clip on the kept person"
        )
        check(
            model.profiles.contains { $0.id == source.id },
            "the refreshed snapshot still lists the source person"
        )
    }

    @MainActor static func failedDatabaseMergeRollsBackACopiedClip() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let source = try fixture.voice(name: "Alex")
        let target = try fixture.voice(name: "Blake", embedding: [0, 1])
        let sourceQuote = "Words from the source clip."
        try fixture.writeQuotedClip(for: source.id, quote: sourceQuote)
        try FileManager.default.removeItem(at: fixture.clipURL(for: target.id))
        try? FileManager.default.removeItem(at: fixture.sidecarURL(for: target.id))
        check(
            SpeakerClipLibrary.sampleText(nextTo: fixture.clipURL(for: source.id)) == sourceQuote,
            "source starts with a matching clip and quote"
        )
        check(
            SpeakerClipExtractor.persistentClipURL(for: target.id, clipsDirectory: fixture.clips) == nil,
            "kept person has no clip to inherit"
        )

        var connection: OpaquePointer?
        let opened = sqlite3_open(fixture.root.appendingPathComponent("speakers.sqlite").path, &connection)
        check(opened == SQLITE_OK, "failure injection opens only the temporary database")
        defer { sqlite3_close(connection) }
        let trigger = sqlite3_exec(connection, """
            CREATE TRIGGER reject_test_merge BEFORE DELETE ON speakers
            BEGIN SELECT RAISE(ABORT, 'synthetic merge rejection'); END;
            """, nil, nil, nil)
        check(trigger == SQLITE_OK, "synthetic merge rejection is installed")

        let store = SpeakerSettingsStore(
            speakerDatabase: fixture.database,
            transcriptDirectory: fixture.transcripts,
            preferredClipsDirectory: fixture.clips,
            legacyClipsDirectory: fixture.clips
        )
        let didMerge = store.merge(sourceId: source.id, targetId: target.id)

        check(!didMerge, "a rejected people merge must report failure")
        check(
            fixture.database.getSpeaker(id: source.id) != nil
                && fixture.database.getSpeaker(id: target.id) != nil,
            "both people stay separate when the database merge fails"
        )
        check(
            FileManager.default.fileExists(atPath: fixture.clipURL(for: source.id).path)
                && SpeakerClipLibrary.sampleText(nextTo: fixture.clipURL(for: source.id)) == sourceQuote,
            "the source still has its clip and quote"
        )
        check(
            SpeakerClipExtractor.persistentClipURL(for: target.id, clipsDirectory: fixture.clips) == nil
                && !FileManager.default.fileExists(atPath: fixture.sidecarURL(for: target.id).path)
                && SpeakerClipLibrary.sampleText(nextTo: fixture.clipURL(for: target.id)) == nil,
            "the kept person must not play or quote the copied clip after a failed merge"
        )
        print("failedDatabaseMergeRollsBackACopiedClip: source kept clip and quote; target has neither")
    }

    /// Waits until the "Who spoke?" visit has no card saving or waiting on Undo.
    @MainActor static func meetingSavesSettle(_ model: SpeakerPeopleSettingsViewModel) async {
        guard model.meetingReview.finished != nil || !model.meetingReview.heldOutCallKeys.isEmpty else { return }
        await withCheckedContinuation { continuation in
            var observation: AnyCancellable?
            observation = model.$meetingReview.dropFirst().sink { _ in
                // @Published emits before the setter lands; read it next turn.
                DispatchQueue.main.async {
                    guard model.meetingReview.heldOutCallKeys.isEmpty, observation != nil else { return }
                    observation?.cancel()
                    observation = nil
                    continuation.resume()
                }
            }
        }
    }

    @MainActor static func whoSpokeDoneWaitsForUndoThenSaves() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice()
        _ = try fixture.meeting(voice: voice, filename: "weekly")
        let model = await fixture.load()
        guard let call = model.reviewStack.calls.first else { fatalError("FAIL: the meeting has a card") }
        let answer = SpeakerReviewUpdate(persistentSpeakerId: voice.id, diarizerSpeakerId: "1", newName: "Rosa Diaz", action: .named)

        model.finishMeeting(call, updates: [answer])
        check(model.reviewStack.calls.isEmpty && model.meetingReview.finished?.names == ["Rosa Diaz"],
            "Done takes the card off the stack and shows who was named")
        check(fixture.database.getSpeaker(id: voice.id)?.displayName == nil, "nothing saves while Undo is up")
        let finishedToken = model.meetingReview.finished?.token
        model.finishMeeting(call, updates: [answer])
        model.skipMeeting(call, updates: [answer])
        check(model.meetingReview.finished?.token == finishedToken && model.meetingReview.meetingsDone == 1,
            "a second Done or a Skip on the finished card changes nothing")
        check(fixture.database.getSpeaker(id: voice.id)?.displayName == nil, "a second Done doesn't save past Undo")

        model.undoFinishedMeeting()
        check(model.reviewStack.calls.map(\.id) == [call.id] && model.meetingReview.meetingsDone == 0,
            "Undo puts the card back and takes the meeting off the count")
        check(fixture.database.getSpeaker(id: voice.id)?.displayName == nil, "Undo saved nothing")

        model.finishMeeting(call, updates: [answer])
        // Quit right after Done: the answers save before the app goes.
        await SpeakerPeopleSettingsViewModel.finishMeetingSavesForTermination()
        check(fixture.database.getSpeaker(id: voice.id)?.displayName == "Rosa Diaz", "Quit saves a card still waiting on Undo before it returns")
        await meetingSavesSettle(model)
        check(model.reviewQueueItems.isEmpty && model.reviewStack.calls.isEmpty, "a fully named meeting leaves the queue")
        check(model.meetingReview.meetingsDone == 0, "with nothing left to name the next visit starts at Meeting 1")
        print("whoSpokeDoneWaitsForUndoThenSaves: Undo saved nothing; the save named the voice")
    }

    @MainActor static func whoSpokeTwoMeetingsNamingOneNewPersonMakeOnePerson() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let first = try fixture.voice(embedding: [1, 0])
        let second = try fixture.voice(embedding: [0, 1])
        _ = try fixture.meeting(voice: first, id: UUID(), filename: "first")
        _ = try fixture.meeting(voice: second, id: UUID(), filename: "second")
        let model = await fixture.load()
        check(model.reviewStack.calls.count == 2, "two meetings, two cards")
        let calls = model.reviewStack.calls
        let voiceOn: (SpeakerPendingMeetingGroup) -> UUID = { $0.voices[0].id }

        model.finishMeeting(calls[0], updates: [
            SpeakerReviewUpdate(persistentSpeakerId: voiceOn(calls[0]), diarizerSpeakerId: "1", newName: "Sam Ortiz", action: .named),
        ])
        // The second Done saves the first card now; leaving saves the second.
        model.finishMeeting(calls[1], updates: [
            SpeakerReviewUpdate(persistentSpeakerId: voiceOn(calls[1]), diarizerSpeakerId: "1", newName: "Sam Ortiz", action: .named),
        ])
        model.saveFinishedMeetingNow()
        await meetingSavesSettle(model)
        let named = fixture.database.allSpeakers().filter { $0.displayName == "Sam Ortiz" }
        check(named.count == 1, "the second meeting's Sam Ortiz joins the first instead of making a second person")
        print("whoSpokeTwoMeetingsNamingOneNewPersonMakeOnePerson: one Sam Ortiz")
    }

    @MainActor static func whoSpokeFailedSaveKeepsTheMeetingAndSaysSo() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let voice = try fixture.voice()
        _ = try fixture.meeting(voice: voice, filename: "retro")
        let moved = try fixture.meeting(voice: voice, filename: "moved")
        let model = await fixture.load()
        guard let call = model.reviewStack.calls.first else { fatalError("FAIL: the meeting has a card") }
        // One of the voice's meetings is gone, so its transaction can't save.
        try FileManager.default.removeItem(at: moved)
        model.skipMeeting(call, updates: [
            SpeakerReviewUpdate(persistentSpeakerId: voice.id, diarizerSpeakerId: "1", newName: "Dana Holt", action: .named),
        ])
        await meetingSavesSettle(model)
        check(model.meetingSaveError?.hasPrefix("Couldn't save 1 name") == true, "a save that fails says so")
        check(!SpeakerReviewSkippedCalls.load(defaults: fixture.defaults).contains(call.id), "a failed Skip doesn't skip the meeting")
        check(model.reviewStack.calls.map(\.id) == [call.id], "its card comes back to try again")
        print("whoSpokeFailedSaveKeepsTheMeetingAndSaysSo: error shown, meeting kept")
    }

    @MainActor static func whoSpokeSkipSavesAnswersAndSkipsTheRest() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let answered = try fixture.voice(embedding: [1, 0])
        let left = try fixture.voice(embedding: [0, 1])
        let url = fixture.transcripts.appendingPathComponent("standup.md")
        try """
        ---
        title: "Standup"
        transcript_id: "\(UUID().uuidString)"
        capture_type: meeting
        date: "2026-01-02"
        duration: "00:30"
        speakers:
          - id: "1"
            channel: system
            db_id: "\(answered.id.uuidString)"
            name: "Speaker 1"
            source: db_pending
          - id: "2"
            channel: system
            db_id: "\(left.id.uuidString)"
            name: "Speaker 2"
            source: db_pending
        ---
        ## Full Transcript
        [00:01] [System/Speaker 1] Synthetic words.
        [00:02] [System/Speaker 2] Other synthetic words.
        """.write(to: url, atomically: true, encoding: .utf8)
        let model = await fixture.load()
        guard let call = model.reviewStack.calls.first, call.voices.count == 2 else { fatalError("FAIL: one card, two voices") }

        await withCheckedContinuation { continuation in
            var observation: AnyCancellable?
            observation = model.$profiles.dropFirst().sink { _ in
                DispatchQueue.main.async {
                    guard observation != nil, model.currentProfile(id: answered.id)?.displayName == "Jordan Lee" else { return }
                    observation?.cancel()
                    observation = nil
                    continuation.resume()
                }
            }
            model.skipMeeting(call, updates: [
                SpeakerReviewUpdate(persistentSpeakerId: answered.id, diarizerSpeakerId: "1", newName: "Jordan Lee", action: .named),
            ])
        }
        check(SpeakerReviewSkippedCalls.load(defaults: fixture.defaults).contains(call.id), "Skip is saved, so the meeting stays skipped")
        check(model.reviewStack.calls.isEmpty, "a skipped meeting has no card")
        check(fixture.database.getSpeaker(id: left.id)?.displayName == nil, "the unanswered voice stays unnamed for later")
        check(model.directoryProfiles.contains { $0.id == left.id }, "and is listed under Not named yet")
        print("whoSpokeSkipSavesAnswersAndSkipsTheRest: answered voice named, the other left in the list")
    }

    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            fatalError("Smoke requires file logging disabled")
        }
        try await newNameConfirmsAllDistinctMeetings()
        try await existingNameJoinsAndDeduplicatesMeetings()
        try await failedSaveReturnsNoCelebrationOrMutation()
        try await databaseRejectionRestoresWrittenMeetings()
        try await thisIsMeJoinsExistingOwnerBeforeCompletion()
        try await failedDeleteKeepsVoiceClip()
        try await failedMergeKeepsSourceProfileAndClip()
        try await failedDatabaseMergeRollsBackACopiedClip()
        try await whoSpokeDoneWaitsForUndoThenSaves()
        try await whoSpokeSkipSavesAnswersAndSkipsTheRest()
        try await whoSpokeTwoMeetingsNamingOneNewPersonMakeOnePerson()
        try await whoSpokeFailedSaveKeepsTheMeetingAndSaysSo()
        print("Speaker settings model smoke: \(assertions) assertions passed")
    }
}
