import Foundation
import CryptoKit
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

/// The trained next-word table is durable now. It is writing, so it lives in
/// the same owner-only encrypted store as the history log — same Keychain key,
/// same 0600 permissions, same delete-everything — and it names the log
/// position it covers so a restore knows exactly what it still has to replay.
@Suite("Encrypted trained model store", .serialized)
struct PersonalTrainedModelStoreTests {
    @Test("The trained table round-trips encrypted, owner-only, with no learned word on disk")
    func encryptedRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let event = fixture.event(id: "one", text: " PRIVATEWORD PRIVATEWORD ")
        let sequence = try await fixture.store.append([event])
        #expect(sequence == 1)
        let stored = fixture.trainedModel(
            text: " PRIVATEWORD FOLLOWER PRIVATEWORD FOLLOWER ",
            coveredThroughSequence: sequence
        )

        try await fixture.store.saveTrainedModel(stored)

        let replay = try await fixture.store.loadReplay(maximumBytes: .max)
        #expect(replay.trainedModel == stored)
        #expect(replay.events == [event])

        let raw = try Data(contentsOf: fixture.store.modelLocation)
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.hasPrefix("TILDE-PERSONAL-MODEL\t1\n"))
        #expect(!text.contains("PRIVATEWORD"))
        #expect(!text.contains("FOLLOWER"))
        #expect(!text.contains("com.example.Editor"))
        var info = stat()
        #expect(lstat(fixture.store.modelLocation.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o600)
    }

    @Test("Coverage names the records a restore still has to replay")
    func coverageSelectsTheUnlearnedTail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.event(id: "one", text: " already learned ")
        let second = fixture.event(id: "two", text: " not yet learned ")
        let covered = try await fixture.store.append([first])
        try await fixture.store.saveTrainedModel(
            fixture.trainedModel(text: " already learned ", coveredThroughSequence: covered)
        )
        let later = try await fixture.store.append([second])
        #expect(later == covered + 1)

        let replay = try await fixture.store.loadReplay(maximumBytes: .max)
        #expect(replay.events == [first, second])
        #expect(replay.trainedModel?.coveredThroughSequence == covered)
        #expect(replay.events(after: covered) == [second])
        #expect(replay.events(after: 0) == [first, second])
        // Positions start at 1, so a saved model can never claim to cover a
        // record written before positions existed.
        #expect(replay.records.allSatisfy { $0.sequence > 0 })
    }

    @Test("Saving replaces the previous table rather than appending to it")
    func savingReplaces() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: " one two ")])
        try await fixture.store.saveTrainedModel(
            fixture.trainedModel(text: " one two one two ", coveredThroughSequence: 1)
        )
        let newer = fixture.trainedModel(
            text: " three four three four ",
            coveredThroughSequence: 1
        )
        try await fixture.store.saveTrainedModel(newer)

        #expect(try await fixture.store.loadReplay(maximumBytes: .max).trainedModel == newer)
        let lines = try Data(contentsOf: fixture.store.modelLocation).split(separator: 0x0A)
        #expect(lines.count == 2)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(
                "Personal History/model.v1.enc.partial"
            ).path
        ))
    }

    @Test("Deleting personalization data deletes the trained table too")
    func deletionRemovesTheTrainedModel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: " learn this ")])
        try await fixture.store.saveTrainedModel(
            fixture.trainedModel(text: " learn this learn this ", coveredThroughSequence: 1)
        )
        #expect(FileManager.default.fileExists(atPath: fixture.store.modelLocation.path))

        try await fixture.store.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: fixture.store.modelLocation.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(fixture.keys.deleted)
        #expect(try await fixture.store.loadReplay(maximumBytes: .max).trainedModel == nil)
    }

    @Test("The storage meter owns up to the trained table's bytes")
    func summaryCountsTheTrainedModel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: " one two ")])
        let historyOnly = try await fixture.store.summary().approximateBytes
        try await fixture.store.saveTrainedModel(
            fixture.trainedModel(text: " one two one two ", coveredThroughSequence: 1)
        )

        let modelBytes = try Data(contentsOf: fixture.store.modelLocation).count
        #expect(modelBytes > 0)
        #expect(try await fixture.store.summary().approximateBytes
            == historyOnly + Int64(modelBytes))
    }

    @Test("An unreadable trained table falls back to a rebuild instead of failing the replay")
    func corruptModelFallsBackToRebuild() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let event = fixture.event(id: "one", text: " still replayable ")
        try await fixture.store.append([event])
        try await fixture.store.saveTrainedModel(
            fixture.trainedModel(text: " still replayable ", coveredThroughSequence: 1)
        )
        var corrupted = Data("TILDE-PERSONAL-MODEL\t1\n".utf8)
        corrupted.append(Data("bm90LWEtcmVjb3Jk".utf8))
        corrupted.append(0x0A)
        try corrupted.write(to: fixture.store.modelLocation)
        chmod(fixture.store.modelLocation.path, 0o600)

        let replay = try await fixture.store.loadReplay(maximumBytes: .max)
        #expect(replay.trainedModel == nil)
        #expect(replay.events == [event])
        #expect(fixture.diagnosticsText().contains("personal-model-unreadable"))
        #expect(!fixture.diagnosticsText().contains("replayable"))
    }

    @Test("A record sealed for the history log cannot be read back as a trained model")
    func modelRecordIsBoundToItsOwnLabel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.append([fixture.event(id: "one", text: " one two ")])
        let stored = fixture.trainedModel(text: " one two one two ", coveredThroughSequence: 1)
        let plaintext = try JSONEncoder().encode(stored)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: try fixture.keys.loadExistingKey()),
            authenticating: TildeProductProfile.current.personalHistoryAuthenticatedData
        )
        var raw = Data("TILDE-PERSONAL-MODEL\t1\n".utf8)
        raw.append(try #require(sealed.combined).base64EncodedData())
        raw.append(0x0A)
        try raw.write(to: fixture.store.modelLocation)
        chmod(fixture.store.modelLocation.path, 0o600)

        #expect(try await fixture.store.loadReplay(maximumBytes: .max).trainedModel == nil)
    }

    @Test("A table from another history, experiment, or exclusion scope is refused")
    func envelopeScopeIsChecked() {
        let model = Fixture.trainedModel(text: " one two one two ")
        let stored = PersonalNextWordStoredModel(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: ["com.example.Excluded"],
            coveredThroughSequence: 4,
            model: model
        )

        #expect(stored.matches(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: ["com.example.Excluded"]
        ))
        #expect(!stored.matches(
            historyIdentifier: "other",
            experimentIdentifier: "experiment",
            excludedApps: ["com.example.Excluded"]
        ))
        #expect(!stored.matches(
            historyIdentifier: "history",
            experimentIdentifier: "rotated",
            excludedApps: ["com.example.Excluded"]
        ))
        #expect(!stored.matches(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: []
        ))
    }

    private final class Keys: PersonalHistoryKeyProviding, @unchecked Sendable {
        private let lock = NSLock()
        private let keyData: Data
        private var removed = false

        init(keyData: Data) { self.keyData = keyData }

        var deleted: Bool { lock.withLock { removed } }

        func loadExistingKey() throws -> Data {
            try lock.withLock {
                guard !removed else { throw PersonalHistoryStorageError.missingKey }
                return keyData
            }
        }

        func loadOrCreateKey() throws -> Data {
            lock.withLock {
                removed = false
                return keyData
            }
        }

        func deleteKey() throws { lock.withLock { removed = true } }
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let keys: Keys
        let diagnosticsLog: URL
        let diagnostics: DiagnosticsLog
        let store: EncryptedPersonalHistoryStore

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("tilde-trained-model-tests-\(UUID().uuidString)")
            file = root.appendingPathComponent("Personal History/history.v1.enc")
            keys = Keys(keyData: Data(repeating: 0x5A, count: 32))
            diagnosticsLog = root.appendingPathComponent("diagnostics.log")
            diagnostics = DiagnosticsLog(logURL: diagnosticsLog)
            store = EncryptedPersonalHistoryStore(
                location: file,
                keyProvider: keys,
                diagnostics: diagnostics
            )
        }

        func diagnosticsText() -> String {
            diagnostics.flush()
            return (try? String(contentsOf: diagnosticsLog, encoding: .utf8)) ?? ""
        }

        func event(id: String, text: String) -> PersonalHistoryEvent {
            PersonalHistoryEvent(
                id: id,
                timestampMilliseconds: 1_786_485_600_000,
                historyIdentifier: "history",
                sessionIdentifier: "session",
                appBundleIdentifier: "com.example.Editor",
                source: .typed,
                text: text
            )!
        }

        static func trainedModel(text: String) -> PersonalNextWordTrainedModel {
            var shadow = PersonalNextWordShadow()
            shadow.consume([PersonalHistoryEvent(
                id: "training",
                timestampMilliseconds: 1_786_485_600_000,
                historyIdentifier: "history",
                sessionIdentifier: "session",
                appBundleIdentifier: "com.example.Editor",
                source: .typed,
                text: text
            )!], scoring: false)
            return shadow.trainedModel
        }

        func trainedModel(
            text: String,
            coveredThroughSequence: Int64
        ) -> PersonalNextWordStoredModel {
            PersonalNextWordStoredModel(
                historyIdentifier: "history",
                experimentIdentifier: "experiment",
                excludedApps: [],
                coveredThroughSequence: coveredThroughSequence,
                model: Self.trainedModel(text: text)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
