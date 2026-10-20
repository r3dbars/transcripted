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
        print("Speaker settings model smoke: \(assertions) assertions passed")
    }
}
