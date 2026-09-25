import Foundation
import CryptoKit
import Security
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Encrypted Personal History store", .serialized)
struct PersonalHistoryStoreTests {
    @Test("Key query stays in the non-synchronizing login Keychain")
    func keychainQueryShape() {
        let query = KeychainPersonalHistoryKeyProvider.baseQuery()

        #expect(query[kSecClass] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService] as? String == KeychainPersonalHistoryKeyProvider.service)
        #expect(query[kSecAttrAccount] as? String == KeychainPersonalHistoryKeyProvider.account)
        #expect(query[kSecAttrSynchronizable] as? Bool == false)
        #expect(query[kSecUseDataProtectionKeychain] == nil)
        #expect(query[kSecAttrAccessible] == nil)
    }

    @Test("Encrypted events round-trip without plaintext on disk")
    func encryptedRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let events = [
            fixture.event(id: "one", text: "PRIVATE_TYPED_SENTINEL", source: .typed),
            fixture.event(id: "two", text: " accepted words", source: .acceptedSuggestion),
        ]

        try await fixture.store.append(events)
        #expect(try await fixture.store.loadEvents() == events)
        let raw = try Data(contentsOf: fixture.file)
        #expect(!String(decoding: raw, as: UTF8.self).contains("PRIVATE_TYPED_SENTINEL"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("com.example.Editor"))
        let summary = try await fixture.store.summary()
        #expect(summary.approximateBytes == raw.count)

        var info = stat()
        #expect(lstat(fixture.file.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o600)
    }

    @Test("A legacy event log replays and upgrades before the first batch append")
    func legacyEventMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = fixture.event(id: "legacy", text: "legacy history")
        let plaintext = try JSONEncoder().encode(legacy)
        let key = SymmetricKey(data: try fixture.keys.loadExistingKey())
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data("com.justinbetker.draft.personal-history.v1".utf8)
        )
        let combined = try #require(sealed.combined)
        try FileManager.default.createDirectory(
            at: fixture.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        chmod(fixture.file.deletingLastPathComponent().path, 0o700)
        var raw = Data("TILDE-PERSONAL-HISTORY\t1\n".utf8)
        raw.append(combined.base64EncodedData())
        raw.append(0x0A)
        try raw.write(to: fixture.file)
        chmod(fixture.file.path, 0o600)

        #expect(try await fixture.store.loadEvents() == [legacy])
        let current = fixture.event(id: "current", text: "current history")
        try await fixture.store.append([current])

        #expect(try Data(contentsOf: fixture.file).starts(
            with: Data("TILDE-PERSONAL-HISTORY\t2\n".utf8)
        ))
        #expect(try await fixture.store.loadEvents() == [legacy, current])
    }

    @Test("A paired checkpoint is encrypted in the same append as its events")
    func encryptedCheckpointRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let events = [
            fixture.event(id: "paired-a", text: "PRIVATE_CHECKPOINT_SENTINEL"),
            fixture.event(id: "paired-b", text: "second event"),
        ]
        let stored = PersonalNextWordStoredCheckpoint(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: ["com.example.Excluded"],
            checkpoint: PersonalNextWordShadow().checkpoint
        )

        try await fixture.store.append(events, checkpoint: stored)

        let replay = try await fixture.store.loadReplay(maximumBytes: .max)
        #expect(replay.events == events)
        #expect(replay.checkpoint == stored)
        let raw = try Data(contentsOf: fixture.file)
        #expect(raw.split(separator: 0x0A).count == 2)
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.contains("PRIVATE_CHECKPOINT_SENTINEL"))
        #expect(!text.contains(PersonalNextWordShadow.candidateRecipeID))
    }

    @Test("An authenticated old-recipe checkpoint is dropped without losing its events")
    func oldRecipeCheckpointMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldEvent = fixture.event(id: "old-recipe", text: "retained history")
        let stored = PersonalNextWordStoredCheckpoint(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: [],
            checkpoint: PersonalNextWordShadow().checkpoint
        )
        try fixture.writeAuthenticatedBatch(events: [oldEvent], checkpoint: stored) {
            $0[2] = "retired-candidate-recipe"
        }

        let migrated = try await fixture.store.loadReplay(maximumBytes: .max)
        #expect(migrated.events == [oldEvent])
        #expect(migrated.checkpoint == nil)

        let current = fixture.event(id: "after-migration", text: "current history")
        try await fixture.store.append([current], checkpoint: nil)
        let replay = try await fixture.store.loadReplay(maximumBytes: .max)
        #expect(replay.events == [oldEvent, current])
        #expect(replay.checkpoint == nil)
    }

    @Test("A malformed authenticated checkpoint still makes the record corrupt")
    func malformedCheckpointFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let event = fixture.event(id: "malformed-checkpoint", text: "history")
        let stored = PersonalNextWordStoredCheckpoint(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: [],
            checkpoint: PersonalNextWordShadow().checkpoint
        )
        try fixture.writeAuthenticatedBatch(events: [event], checkpoint: stored) {
            $0.removeLast()
        }

        await #expect(throws: PersonalHistoryStorageError.corruptStore) {
            try await fixture.store.loadReplay(maximumBytes: .max)
        }
    }

    @Test("The maximum retained daily checkpoint stays within one appendable record")
    func maximumCheckpointRemainsAppendable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let daily = (0..<PersonalNextWordShadow.maximumActiveDays).map { day in
            PersonalNextWordDailyAggregate(
                utcDayStartMilliseconds: Int64(day) * PersonalNextWordShadow.dayMilliseconds,
                aggregate: PersonalNextWordPairedAggregate(
                    outcomeCells: PersonalNextWordOutcomeCells(
                        baselineSilentCandidateSilent: 1
                    )
                )
            )
        }
        let totals = PersonalNextWordPairedAggregate(
            outcomeCells: PersonalNextWordOutcomeCells(
                baselineSilentCandidateSilent: PersonalNextWordShadow.maximumActiveDays
            )
        )
        let checkpoint = try #require(PersonalNextWordShadowCheckpoint(
            evaluationStartMilliseconds: PersonalNextWordShadow.evaluationStartMilliseconds,
            totals: totals,
            activeDays: daily
        ))
        let stored = PersonalNextWordStoredCheckpoint(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: [],
            checkpoint: checkpoint
        )
        let first = fixture.event(id: "maximum-checkpoint", text: "history")
        let second = fixture.event(id: "after-maximum", text: "more history")

        try await fixture.store.append([first], checkpoint: stored)
        let firstRaw = try Data(contentsOf: fixture.file)
        #expect(firstRaw.split(separator: 0x0A).last!.count + 1 < 4 * 1_024)
        try await fixture.store.append([second])

        let replay = try await fixture.store.loadReplay(maximumBytes: .max)
        #expect(replay.events == [first, second])
        #expect(replay.checkpoint == stored)
    }

    @Test("A training-only append carries the last checkpoint into the bounded replay tail")
    func checkpointSurvivesTrainingOnlyTail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stored = PersonalNextWordStoredCheckpoint(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: [],
            checkpoint: PersonalNextWordShadow().checkpoint
        )
        let scored = fixture.event(id: "scored", text: "scored history")
        let trainingOnly = fixture.event(id: "training-only", text: "new history")

        try await fixture.store.append([scored], checkpoint: stored)
        try await fixture.store.append([trainingOnly], checkpoint: nil)
        let raw = try Data(contentsOf: fixture.file)
        let newestRecordBytes = try #require(raw.split(separator: 0x0A).last).count + 1

        let replay = try await fixture.store.loadReplay(
            maximumBytes: Int64(newestRecordBytes)
        )
        #expect(replay.events == [trainingOnly])
        #expect(replay.checkpoint == stored)
    }

    @Test("Delete removes the corpus and its encryption key")
    func deletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: "history")])

        try await fixture.store.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(fixture.keys.wasDeleted)
        #expect(try await fixture.store.loadEvents().isEmpty)
    }

    @Test("Unknown or corrupt formats fail without overwriting existing bytes")
    func corruptStoreFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        chmod(fixture.file.deletingLastPathComponent().path, 0o700)
        let original = Data("UNKNOWN-FORMAT\n".utf8)
        try original.write(to: fixture.file)
        chmod(fixture.file.path, 0o600)

        await #expect(throws: PersonalHistoryStorageError.self) {
            try await fixture.store.loadEvents()
        }
        await #expect(throws: PersonalHistoryStorageError.self) {
            try await fixture.store.append([fixture.event(id: "one", text: "new text")])
        }
        await #expect(throws: PersonalHistoryStorageError.self) {
            try await fixture.store.summary()
        }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("A torn trailing write self-heals by dropping only the incomplete record")
    func tornTrailingWriteSelfHeals() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: "first")])
        try await fixture.store.append([fixture.event(id: "two", text: "second")])
        let complete = try Data(contentsOf: fixture.file)

        // Simulate a process killed mid-append: a third record's bytes
        // landed on disk but its trailing newline never did.
        var torn = complete
        torn.append(Data("dGhpcyBpcyBub3QgYSBjb21wbGV0ZSByZWNvcmQ".utf8))
        chmod(fixture.file.deletingLastPathComponent().path, 0o700)
        try torn.write(to: fixture.file)
        chmod(fixture.file.path, 0o600)

        // Reads recover the two complete records instead of failing closed.
        let replayed = try await fixture.store.loadEvents()
        #expect(replayed.map(\.id) == ["one", "two"])
        _ = try await fixture.store.summary()

        // The next append repairs the tear in place and proceeds normally —
        // no manual delete-and-lose-everything required.
        try await fixture.store.append([fixture.event(id: "three", text: "third")])
        let repaired = try await fixture.store.loadEvents()
        #expect(repaired.map(\.id) == ["one", "two", "three"])
        #expect(fixture.diagnosticsText().contains("personal-history-store-repaired"))
    }

    @Test("A write torn on the very first record recovers to an empty store")
    func tornFirstWriteRecoversToEmpty() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        chmod(fixture.file.deletingLastPathComponent().path, 0o700)
        var torn = Data("TILDE-PERSONAL-HISTORY\t2\n".utf8)
        torn.append(Data("dGhpcyBpcyBub3QgYSBjb21wbGV0ZSByZWNvcmQ".utf8))
        try torn.write(to: fixture.file)
        chmod(fixture.file.path, 0o600)

        #expect(try await fixture.store.loadEvents().isEmpty)

        try await fixture.store.append([fixture.event(id: "one", text: "first")])
        #expect(try await fixture.store.loadEvents().map(\.id) == ["one"])
        #expect(fixture.diagnosticsText().contains("personal-history-store-repaired"))
    }

    @Test("Delete remains available when the corpus is corrupt")
    func corruptStoreCanBeDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        chmod(fixture.file.deletingLastPathComponent().path, 0o700)
        try Data("UNKNOWN-FORMAT\n".utf8).write(to: fixture.file)
        chmod(fixture.file.path, 0o600)

        try await fixture.store.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(fixture.keys.wasDeleted)
    }

    @Test("Delete remains available when the owner-owned corpus is read-only")
    func readOnlyStoreCanBeDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "read-only", text: "history")])
        #expect(chmod(fixture.file.path, 0o400) == 0)

        try await fixture.store.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(fixture.keys.wasDeleted)
    }

    @Test("Delete rejects an owner-only FIFO promptly without deleting its key")
    func deletionRejectsFIFO() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFIFO()
        let start = ContinuousClock.now

        await #expect(throws: Error.self) { try await fixture.store.deleteAll() }

        #expect(start.duration(to: .now) < .seconds(1))
        var info = stat()
        #expect(lstat(fixture.file.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFIFO)
        #expect(!fixture.keys.wasDeleted)
    }

    @Test("Replay, summary, and append reject an owner-only FIFO promptly")
    func storageOperationsRejectFIFO() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFIFO()
        let start = ContinuousClock.now

        await #expect(throws: Error.self) {
            try await fixture.store.loadReplay(maximumBytes: 4 * 1_024)
        }
        await #expect(throws: Error.self) { try await fixture.store.summary() }
        await #expect(throws: Error.self) {
            try await fixture.store.append([fixture.event(id: "fifo", text: "history")])
        }

        #expect(start.duration(to: .now) < .seconds(1))
        var info = stat()
        #expect(lstat(fixture.file.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFIFO)
    }

    @Test("Deletion refuses a history directory redirected by a symlink")
    func deletionRejectsRedirectedDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        chmod(fixture.root.path, 0o700)
        chmod(outside.path, 0o700)
        let outsideFile = outside.appendingPathComponent("history.v1.enc")
        let sentinel = Data("DO-NOT-DELETE".utf8)
        try sentinel.write(to: outsideFile)
        chmod(outsideFile.path, 0o600)
        try FileManager.default.createSymbolicLink(
            at: fixture.file.deletingLastPathComponent(),
            withDestinationURL: outside
        )

        await #expect(throws: Error.self) {
            try await fixture.store.deleteAll()
        }
        #expect(try Data(contentsOf: outsideFile) == sentinel)
        #expect(!fixture.keys.wasDeleted)
    }

    @Test("Replay reads only the most recent complete encrypted events")
    func boundedReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.event(id: "one", text: "older history")
        let second = fixture.event(id: "two", text: "recent history")
        try await fixture.store.append([first])
        try await fixture.store.append([second])
        let raw = try Data(contentsOf: fixture.file)
        let finalLineBytes = raw.split(separator: 0x0A).last!.count + 1

        let replay = try await fixture.store.loadReplay(
            maximumBytes: Int64(finalLineBytes)
        )
        #expect(replay.events == [second])
    }

    @Test("A missing key never replaces or mixes an existing corpus")
    func missingExistingKeyFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: "history")])
        let original = try Data(contentsOf: fixture.file)
        let missingKeys = MutableKeys(keyData: nil)
        let reopened = EncryptedPersonalHistoryStore(
            location: fixture.file,
            keyProvider: missingKeys
        )

        await #expect(throws: PersonalHistoryStorageError.missingKey) {
            try await reopened.loadEvents()
        }
        await #expect(throws: PersonalHistoryStorageError.missingKey) {
            try await reopened.append([fixture.event(id: "two", text: "new history")])
        }
        #expect(missingKeys.creationCount == 0)
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("A wrong existing key cannot mix new records into the corpus")
    func wrongExistingKeyFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: "history")])
        let original = try Data(contentsOf: fixture.file)
        let reopened = EncryptedPersonalHistoryStore(
            location: fixture.file,
            keyProvider: MutableKeys(keyData: Data(repeating: 0x5A, count: 32))
        )

        await #expect(throws: PersonalHistoryStorageError.corruptStore) {
            try await reopened.append([fixture.event(id: "two", text: "new history")])
        }
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("An invalid encryption key fails before creating the store")
    func invalidKeyFailsClosed() async throws {
        let fixture = try Fixture(keyData: Data(repeating: 0xA5, count: 31))
        defer { fixture.remove() }

        await #expect(throws: PersonalHistoryStorageError.invalidKey) {
            try await fixture.store.append([fixture.event(id: "one", text: "history")])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    private final class MutableKeys: PersonalHistoryKeyProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var keyData: Data?
        private var deleted = false
        private var creations = 0

        init(keyData: Data?) {
            self.keyData = keyData
        }

        var wasDeleted: Bool {
            lock.withLock { deleted }
        }

        var creationCount: Int {
            lock.withLock { creations }
        }

        func loadExistingKey() throws -> Data {
            try lock.withLock {
                guard let keyData else { throw PersonalHistoryStorageError.missingKey }
                return keyData
            }
        }

        func loadOrCreateKey() throws -> Data {
            lock.withLock {
                if let keyData { return keyData }
                creations += 1
                let created = Data(repeating: 0x5A, count: 32)
                keyData = created
                return created
            }
        }

        func deleteKey() throws {
            lock.withLock { deleted = true }
        }
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let keys: MutableKeys
        let diagnosticsLog: URL
        let diagnostics: DiagnosticsLog
        let store: EncryptedPersonalHistoryStore

        init(keyData: Data = Data(repeating: 0xA5, count: 32)) throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("tilde-history-tests-\(UUID().uuidString)")
            file = root.appendingPathComponent("Personal History/history.v1.enc")
            keys = MutableKeys(keyData: keyData)
            diagnosticsLog = root.appendingPathComponent("diagnostics.log")
            diagnostics = DiagnosticsLog(logURL: diagnosticsLog)
            store = EncryptedPersonalHistoryStore(location: file, keyProvider: keys, diagnostics: diagnostics)
        }

        func diagnosticsText() -> String {
            diagnostics.flush()
            return (try? String(contentsOf: diagnosticsLog, encoding: .utf8)) ?? ""
        }

        func event(
            id: String,
            text: String,
            source: PersonalHistoryEventSource = .typed
        ) -> PersonalHistoryEvent {
            PersonalHistoryEvent(
                id: id,
                timestampMilliseconds: 1_786_485_600_000,
                historyIdentifier: "history",
                sessionIdentifier: "session",
                appBundleIdentifier: "com.example.Editor",
                source: source,
                text: text
            )!
        }

        func writeAuthenticatedBatch(
            events: [PersonalHistoryEvent],
            checkpoint: PersonalNextWordStoredCheckpoint,
            mutateShadowCheckpoint: (inout [Any]) -> Void
        ) throws {
            let encoded = try JSONEncoder().encode(
                EncodedStoredBatch(events: events, checkpoint: checkpoint)
            )
            guard var batch = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  var stored = batch["checkpoint"] as? [String: Any],
                  var shadow = stored["checkpoint"] as? [Any] else {
                throw CocoaError(.coderInvalidValue)
            }
            mutateShadowCheckpoint(&shadow)
            stored["checkpoint"] = shadow
            batch["checkpoint"] = stored
            let plaintext = try JSONSerialization.data(
                withJSONObject: batch,
                options: [.sortedKeys]
            )
            let key = SymmetricKey(data: try keys.loadExistingKey())
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: Data("com.justinbetker.draft.personal-history.v1".utf8)
            )
            let combined = try #require(sealed.combined)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            chmod(file.deletingLastPathComponent().path, 0o700)
            var raw = Data("TILDE-PERSONAL-HISTORY\t2\n".utf8)
            raw.append(combined.base64EncodedData())
            raw.append(0x0A)
            try raw.write(to: file)
            chmod(file.path, 0o600)
        }

        func makeFIFO() throws {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            #expect(chmod(file.deletingLastPathComponent().path, 0o700) == 0)
            #expect(mkfifo(file.path, 0o600) == 0)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct EncodedStoredBatch: Encodable {
        let v = 1
        let events: [PersonalHistoryEvent]
        let checkpoint: PersonalNextWordStoredCheckpoint
    }
}
