#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import CryptoKit
import Foundation
import Security

struct PersonalHistorySummary: Equatable, Sendable {
    let location: URL
    let approximateBytes: Int64
}

protocol PersonalHistoryStore: Sendable {
    var location: URL { get }
    /// Returns the log position of the record this batch became. The trained
    /// model is saved separately and can lag the log, so it names the
    /// position it covers and the next launch replays only what came after.
    @discardableResult
    func append(
        _ events: [PersonalHistoryEvent],
        checkpoint: PersonalNextWordStoredCheckpoint?
    ) async throws -> Int64
    func loadReplay(maximumBytes: Int64) async throws -> PersonalHistoryReplay
    /// Writes the trained next-word table into the same owner-only encrypted
    /// store, under the same key, replacing whatever was there.
    func saveTrainedModel(_ model: PersonalNextWordStoredModel) async throws
    func deleteAll() async throws
    func summary() async throws -> PersonalHistorySummary
}

/// One durable record: the events that were appended together, and the log
/// position they occupy.
struct PersonalHistoryRecord: Equatable, Sendable {
    let sequence: Int64
    let events: [PersonalHistoryEvent]
}

struct PersonalHistoryReplay: Equatable, Sendable {
    let records: [PersonalHistoryRecord]
    let checkpoint: PersonalNextWordStoredCheckpoint?
    let trainedModel: PersonalNextWordStoredModel?

    init(
        records: [PersonalHistoryRecord],
        checkpoint: PersonalNextWordStoredCheckpoint?,
        trainedModel: PersonalNextWordStoredModel? = nil
    ) {
        self.records = records
        self.checkpoint = checkpoint
        self.trainedModel = trainedModel
    }

    var events: [PersonalHistoryEvent] { records.flatMap(\.events) }

    /// The events a restored model has not already learned.
    func events(after sequence: Int64) -> [PersonalHistoryEvent] {
        records.filter { $0.sequence > sequence }.flatMap(\.events)
    }
}

extension PersonalHistoryStore {
    @discardableResult
    func append(_ events: [PersonalHistoryEvent]) async throws -> Int64 {
        try await append(events, checkpoint: nil)
    }

    func loadEvents() async throws -> [PersonalHistoryEvent] {
        try await loadReplay(maximumBytes: .max).events
    }
}

struct PersonalNextWordStoredCheckpoint: Codable, Equatable, Sendable {
    private static let version = 1

    let v: Int
    let historyIdentifier: String
    let experimentIdentifier: String
    let excludedApps: [String]
    let checkpoint: PersonalNextWordShadowCheckpoint

    init(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>,
        checkpoint: PersonalNextWordShadowCheckpoint
    ) {
        v = Self.version
        self.historyIdentifier = historyIdentifier
        self.experimentIdentifier = experimentIdentifier
        self.excludedApps = PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
        self.checkpoint = checkpoint
    }

    func matches(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>
    ) -> Bool {
        v == Self.version
            && self.historyIdentifier == historyIdentifier
            && self.experimentIdentifier == experimentIdentifier
            && self.excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
    }

    fileprivate var hasValidEnvelope: Bool {
        v > 0
            && PersonalHistoryEvent.validIdentifier(historyIdentifier)
            && PersonalHistoryEvent.validIdentifier(experimentIdentifier)
            && excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
    }

    var isCompatibleWithCurrentExperiment: Bool {
        v == Self.version && checkpoint.isCompatibleWithCurrentExperiment
    }
}

/// The trained table plus the scope it was trained under. The scope fields are
/// the checkpoint's, checked the same way: a rotated history or experiment
/// identifier, or a changed exclusion list, means this table was learned from
/// a corpus the owner has since redrawn, and it is discarded rather than
/// carried across the boundary.
struct PersonalNextWordStoredModel: Codable, Equatable, Sendable {
    private static let version = 1

    let v: Int
    let historyIdentifier: String
    let experimentIdentifier: String
    let excludedApps: [String]
    /// The log position (`PersonalHistoryStore.append`'s return value) the
    /// table has already consumed. Records after it still need replaying.
    let coveredThroughSequence: Int64
    let model: PersonalNextWordTrainedModel

    init(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>,
        coveredThroughSequence: Int64,
        model: PersonalNextWordTrainedModel
    ) {
        v = Self.version
        self.historyIdentifier = historyIdentifier
        self.experimentIdentifier = experimentIdentifier
        self.excludedApps = PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
        self.coveredThroughSequence = coveredThroughSequence
        self.model = model
    }

    func matches(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>
    ) -> Bool {
        v == Self.version
            && self.historyIdentifier == historyIdentifier
            && self.experimentIdentifier == experimentIdentifier
            && self.excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
            && coveredThroughSequence >= 0
            && model.isCompatibleWithCurrentRecipe
    }

    fileprivate var hasValidEnvelope: Bool {
        v > 0
            && PersonalHistoryEvent.validIdentifier(historyIdentifier)
            && PersonalHistoryEvent.validIdentifier(experimentIdentifier)
            && excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
            && coveredThroughSequence >= 0
    }
}

protocol PersonalHistoryKeyProviding: Sendable {
    func loadExistingKey() throws -> Data
    func loadOrCreateKey() throws -> Data
    func deleteKey() throws
}

enum PersonalHistoryStorageError: Error, Equatable {
    case corruptStore
    case invalidEvent
    case invalidKey
    case missingKey
    case keychain(OSStatus)
}

final class KeychainPersonalHistoryKeyProvider: PersonalHistoryKeyProviding, @unchecked Sendable {
    static let service = "com.justinbetker.draft.writing.personal-history"
    static let account = "aes-gcm-key-v1"
    private let serviceName: String

    init(serviceName: String = TildeProductProfile.current.personalHistoryKeychainService) {
        self.serviceName = serviceName
    }

    func loadExistingKey() throws -> Data {
        guard let key = try lookupKey() else {
            throw PersonalHistoryStorageError.missingKey
        }
        return key
    }

    func loadOrCreateKey() throws -> Data {
        if let key = try lookupKey() { return key }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw PersonalHistoryStorageError.keychain(randomStatus)
        }

        let add = baseQuery().merging([
            kSecValueData: key,
        ]) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem { return try loadExistingKey() }
        guard addStatus == errSecSuccess else {
            throw PersonalHistoryStorageError.keychain(addStatus)
        }
        return key
    }

    private func lookupKey() throws -> Data? {
        let query = baseQuery().merging([
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else {
                throw PersonalHistoryStorageError.invalidKey
            }
            return data
        }
        if status == errSecItemNotFound { return nil }
        throw PersonalHistoryStorageError.keychain(status)
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PersonalHistoryStorageError.keychain(status)
        }
    }

    static func baseQuery(service: String = service) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
    }

    private func baseQuery() -> [CFString: Any] { Self.baseQuery(service: serviceName) }
}

/// A versioned append-only log. Each event is independently authenticated and
/// encrypted with AES-GCM; only the format header and approximate file size are
/// visible without the non-synchronizing macOS Keychain key.
final class EncryptedPersonalHistoryStore: PersonalHistoryStore, @unchecked Sendable {
    private static let legacyHeader = Data("TILDE-PERSONAL-HISTORY\t1\n".utf8)
    private static let header = Data("TILDE-PERSONAL-HISTORY\t2\n".utf8)
    private static let modelHeader = Data("TILDE-PERSONAL-MODEL\t1\n".utf8)
    private static var authenticatedData: Data {
        TildeProductProfile.current.personalHistoryAuthenticatedData
    }
    /// A distinct label so a record from one file can never be replayed into
    /// the other, even though both are sealed with the same key.
    private static var modelAuthenticatedData: Data {
        authenticatedData + Data(".trained-model".utf8)
    }
    private static let maximumEncryptedRecordBytes = 64 * 1_024
    /// The trained table is a whole-file record rather than a line in the
    /// append log, so it gets its own, larger ceiling: the model's own
    /// capacity limits (8,192 contexts, 32,768 transitions) bound what can
    /// legitimately be written here.
    private static let maximumEncryptedModelBytes = 8 * 1_024 * 1_024

    let location: URL
    private let keyProvider: any PersonalHistoryKeyProviding
    private let diagnostics: DiagnosticsLog
    private let queue = DispatchQueue(label: "com.justinbetker.draft.writing.personal-history-store", qos: .utility)

    init(
        location: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(TildeProductProfile.current.supportDirectoryName)
            .appendingPathComponent("Personal History/history.v1.enc"),
        keyProvider: any PersonalHistoryKeyProviding = KeychainPersonalHistoryKeyProvider(),
        diagnostics: DiagnosticsLog = .shared
    ) {
        self.location = location
        self.keyProvider = keyProvider
        self.diagnostics = diagnostics
    }

    /// The trained model lives beside the history log: same directory, same
    /// owner-only permissions, same Keychain key, same delete-everything.
    var modelLocation: URL {
        location.deletingLastPathComponent().appendingPathComponent("model.v1.enc")
    }

    private var modelTemporaryLocation: URL {
        location.deletingLastPathComponent().appendingPathComponent("model.v1.enc.partial")
    }

    @discardableResult
    func append(
        _ events: [PersonalHistoryEvent],
        checkpoint: PersonalNextWordStoredCheckpoint?
    ) async throws -> Int64 {
        guard PersonalHistoryEvent.validBatch(events) else {
            throw PersonalHistoryStorageError.invalidEvent
        }
        return try await perform { try self.appendSynchronously(events, checkpoint: checkpoint) }
    }

    func loadReplay(maximumBytes: Int64) async throws -> PersonalHistoryReplay {
        try await perform { try self.loadSynchronously(maximumBytes: maximumBytes) }
    }

    func saveTrainedModel(_ model: PersonalNextWordStoredModel) async throws {
        try await perform { try self.saveTrainedModelSynchronously(model) }
    }

    /// Status reads authenticate only the newest record and decode only its
    /// aggregate checkpoint. They never replay or return the record's events.
    func loadLatestCheckpoint() throws -> PersonalNextWordStoredCheckpoint? {
        let handle: FileHandle
        switch SecureLocalStorage.openExistingOwnerOnlyFileForReadOnlyStatus(at: location) {
        case let .opened(opened): handle = opened
        case .missing: return nil
        case .rejected:
            throw PersonalHistoryStorageError.corruptStore
        }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let effectiveSize: UInt64
        let legacyFormat: Bool
        switch try validateHeaderAndTail(handle: handle, size: size) {
        case let .clean(legacy):
            effectiveSize = size
            legacyFormat = legacy
        case let .torn(validPrefixLength):
            effectiveSize = validPrefixLength
            legacyFormat = false
        }
        let bodyStart = UInt64(Self.header.count)
        guard effectiveSize > bodyStart else { return nil }
        guard !legacyFormat else { return nil }
        let keyData = try keyProvider.loadExistingKey()
        guard keyData.count == 32 else { throw PersonalHistoryStorageError.invalidKey }
        let plaintext = try decryptLastRecord(handle: handle, size: effectiveSize, keyData: keyData)
        guard let record = try? JSONDecoder().decode(
            StoredCheckpointRecord.self, from: plaintext
        ) else {
            throw PersonalHistoryStorageError.corruptStore
        }
        guard record.isValid else { throw PersonalHistoryStorageError.corruptStore }
        return record.checkpoint
    }

    func deleteAll() async throws {
        try await perform {
            // Everything the trained model knows was learned from this
            // history, so "delete everything" has to take it too — including
            // a partial save left behind by an interrupted write.
            let removedFile = SecureLocalStorage.removeOwnerOnlyFile(at: self.location)
            let removedModel = SecureLocalStorage.removeOwnerOnlyFile(at: self.modelLocation)
            let removedPartial = SecureLocalStorage.removeOwnerOnlyFile(
                at: self.modelTemporaryLocation
            )
            guard removedFile, removedModel, removedPartial else {
                throw CocoaError(.fileWriteUnknown)
            }
            try self.keyProvider.deleteKey()
        }
    }

    func summary() async throws -> PersonalHistorySummary {
        try await perform {
            // The storage meter must own up to the trained table too: it is
            // the same store, on the same delete path, and on a heavy
            // history it is not a rounding error.
            let modelBytes = self.modelFileBytes()
            var info = stat()
            if lstat(self.location.path, &info) != 0 {
                guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
                return PersonalHistorySummary(
                    location: self.location,
                    approximateBytes: modelBytes
                )
            }
            guard let handle = SecureLocalStorage.openExistingFileForReading(at: self.location) else {
                throw PersonalHistoryStorageError.corruptStore
            }
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            _ = try self.validateHeaderAndTail(handle: handle, size: size)
            // The reported size stays the raw on-disk byte count even when
            // the tail is torn (see `TailStatus.torn`) — this is a storage
            // usage number, not a claim about how many records replay.
            return PersonalHistorySummary(
                location: self.location,
                approximateBytes: Int64(size) + modelBytes
            )
        }
    }

    private func modelFileBytes() -> Int64 {
        var info = stat()
        guard lstat(modelLocation.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return 0 }
        return Int64(max(0, info.st_size))
    }

    private func appendSynchronously(
        _ events: [PersonalHistoryEvent],
        checkpoint: PersonalNextWordStoredCheckpoint?
    ) throws -> Int64 {
        var info = stat()
        let exists = lstat(location.path, &info) == 0
        if !exists, errno != ENOENT { throw CocoaError(.fileReadUnknown) }
        let newStoreKey = exists ? nil : try keyProvider.loadOrCreateKey()
        if let newStoreKey, newStoreKey.count != 32 {
            throw PersonalHistoryStorageError.invalidKey
        }
        guard let handle = SecureLocalStorage.openFileForReadingAndAppending(at: location) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { try? handle.close() }
        var size = try handle.seekToEnd()
        var legacyFormat = false
        if size > 0 {
            switch try validateHeaderAndTail(handle: handle, size: size) {
            case let .clean(legacy):
                legacyFormat = legacy
            case let .torn(validPrefixLength):
                // A prior write never finished (process killed or crashed
                // mid-append) — the header and every record up through
                // `validPrefixLength` are intact and authenticate fine;
                // only the incomplete trailing partial line needs to go.
                // Recover by dropping just that tail instead of treating
                // the whole corpus as unreadable, and say so once so the
                // event is legible instead of silently masquerading as an
                // ordinary append.
                try handle.truncate(atOffset: validPrefixLength)
                size = validPrefixLength
                diagnostics.record("personal-history-store-repaired")
            }
        }
        let keyData: Data
        if let newStoreKey {
            keyData = newStoreKey
        } else if size > UInt64(Self.header.count) {
            keyData = try keyProvider.loadExistingKey()
        } else {
            keyData = try keyProvider.loadOrCreateKey()
        }
        guard keyData.count == 32 else { throw PersonalHistoryStorageError.invalidKey }
        let carried = size > UInt64(Self.header.count)
            ? try authenticateLastRecord(handle: handle, size: size, keyData: keyData)
            : nil
        let checkpointToWrite = checkpoint ?? carried?.checkpoint
        // Log positions are per-store and monotonic. A legacy record decodes
        // as position 0, so the first record this build writes is 1 — and a
        // trained model can never claim to cover a record written before
        // positions existed.
        let sequence = (carried?.sequence ?? 0) + 1
        let key = SymmetricKey(data: keyData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encryptedLines = Data()
        let plaintext = try encoder.encode(
            StoredBatch(events: events, checkpoint: checkpointToWrite, sequence: sequence)
        )
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Self.authenticatedData
        )
        guard let combined = sealed.combined else {
            throw PersonalHistoryStorageError.corruptStore
        }
        encryptedLines.append(combined.base64EncodedData())
        encryptedLines.append(0x0A)
        guard encryptedLines.count <= Self.maximumEncryptedRecordBytes else {
            throw PersonalHistoryStorageError.invalidEvent
        }
        do {
            if size == 0 || legacyFormat {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.header)
            }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: encryptedLines)
        } catch {
            try? handle.truncate(atOffset: size)
            throw error
        }
        return sequence
    }

    private func authenticateLastRecord(
        handle: FileHandle,
        size: UInt64,
        keyData: Data
    ) throws -> (checkpoint: PersonalNextWordStoredCheckpoint?, sequence: Int64)? {
        let line = try encryptedLine(handle: handle, size: size)
        let replay = try Self.decode(line + Data([0x0A]), keyData: keyData)
        return (replay.checkpoint, replay.records.last?.sequence ?? 0)
    }

    private func decryptLastRecord(
        handle: FileHandle,
        size: UInt64,
        keyData: Data
    ) throws -> Data {
        let line = try encryptedLine(handle: handle, size: size)
        guard let combined = Data(base64Encoded: line),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(
                box,
                using: SymmetricKey(data: keyData),
                authenticating: Self.authenticatedData
              ) else {
            throw PersonalHistoryStorageError.corruptStore
        }
        return plaintext
    }

    private func encryptedLine(handle: FileHandle, size: UInt64) throws -> Data {
        let bodyStart = UInt64(Self.header.count)
        let window = min(size - bodyStart, UInt64(Self.maximumEncryptedRecordBytes))
        try handle.seek(toOffset: size - window)
        let tail = try handle.read(upToCount: Int(window)) ?? Data()
        let lines = tail.split(separator: 0x0A)
        guard let last = lines.last,
              last.count + 1 <= Self.maximumEncryptedRecordBytes else {
            throw PersonalHistoryStorageError.corruptStore
        }
        return Data(last)
    }

    /// Reads only a bounded recent tail. The encrypted corpus remains complete
    /// while replay work stays flat as Personal History grows.
    private func loadSynchronously(maximumBytes: Int64) throws -> PersonalHistoryReplay {
        let trainedModel = loadTrainedModelSynchronously()
        var info = stat()
        if lstat(location.path, &info) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
            return PersonalHistoryReplay(records: [], checkpoint: nil, trainedModel: trainedModel)
        }
        guard let handle = SecureLocalStorage.openExistingFileForReading(at: location) else {
            throw PersonalHistoryStorageError.corruptStore
        }
        defer { try? handle.close() }
        let rawSize = try handle.seekToEnd()
        let size: UInt64
        switch try validateHeaderAndTail(handle: handle, size: rawSize) {
        case .clean: size = rawSize
        case let .torn(validPrefixLength): size = validPrefixLength
        }
        let bodyStart = UInt64(Self.header.count)
        guard size > bodyStart else {
            return PersonalHistoryReplay(records: [], checkpoint: nil, trainedModel: trainedModel)
        }

        let keyData = try keyProvider.loadExistingKey()
        guard keyData.count == 32 else { throw PersonalHistoryStorageError.invalidKey }
        let bodySize = size - bodyStart
        let budget = maximumBytes == .max
            ? bodySize
            : UInt64(max(0, maximumBytes))
        guard budget > 0 else {
            return PersonalHistoryReplay(records: [], checkpoint: nil, trainedModel: trainedModel)
        }
        let start = bodySize > budget ? size - budget : bodyStart
        var startsMidLine = false
        if start > bodyStart {
            try handle.seek(toOffset: start - 1)
            startsMidLine = try handle.read(upToCount: 1) != Data([0x0A])
        }
        try handle.seek(toOffset: start)
        // Bounded to `size`, not simply "the rest of the file": when the
        // tail is torn (see `TailStatus.torn`), `size` already stops short
        // of the raw end-of-file, and reading past it would hand the
        // incomplete trailing partial line to `decode` as if it were a
        // record.
        var body = try handle.read(upToCount: Int(size - start)) ?? Data()
        if startsMidLine {
            guard let newline = body.firstIndex(of: 0x0A) else {
                return PersonalHistoryReplay(records: [], checkpoint: nil, trainedModel: trainedModel)
            }
            body.removeSubrange(...newline)
        }
        let decoded = try Self.decode(body, keyData: keyData)
        return PersonalHistoryReplay(
            records: decoded.records,
            checkpoint: decoded.checkpoint,
            trainedModel: trainedModel
        )
    }

    /// Reads the trained table, or reports nothing when it is missing,
    /// unreadable, or from another schema/recipe/scope. Nothing is thrown:
    /// this file is derived state, and the honest fallback is to rebuild
    /// from raw history exactly as Tilde did before it existed. The failure
    /// is still legible — a count-only diagnostic, never a path or a word.
    private func loadTrainedModelSynchronously() -> PersonalNextWordStoredModel? {
        let handle: FileHandle
        switch SecureLocalStorage.openExistingOwnerOnlyFileForReadOnlyStatus(at: modelLocation) {
        case let .opened(opened): handle = opened
        case .missing: return nil
        case .rejected:
            diagnostics.record("personal-model-unreadable", metadata: ["reason": "permissions"])
            return nil
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let headerSize = UInt64(Self.modelHeader.count)
            guard size > headerSize, size <= UInt64(Self.maximumEncryptedModelBytes) else {
                diagnostics.record("personal-model-unreadable", metadata: ["reason": "size"])
                return nil
            }
            try handle.seek(toOffset: 0)
            guard try handle.read(upToCount: Self.modelHeader.count) == Self.modelHeader else {
                diagnostics.record("personal-model-unreadable", metadata: ["reason": "header"])
                return nil
            }
            let body = try handle.read(upToCount: Int(size - headerSize)) ?? Data()
            let keyData = try keyProvider.loadExistingKey()
            guard keyData.count == 32,
                  let line = body.split(separator: 0x0A).last,
                  let combined = Data(base64Encoded: Data(line)),
                  let box = try? AES.GCM.SealedBox(combined: combined),
                  let plaintext = try? AES.GCM.open(
                    box,
                    using: SymmetricKey(data: keyData),
                    authenticating: Self.modelAuthenticatedData
                  ) else {
                diagnostics.record("personal-model-unreadable", metadata: ["reason": "authentication"])
                return nil
            }
            guard let stored = try? JSONDecoder().decode(
                PersonalNextWordStoredModel.self, from: plaintext
            ), stored.hasValidEnvelope else {
                diagnostics.record("personal-model-unreadable", metadata: ["reason": "schema"])
                return nil
            }
            return stored
        } catch {
            diagnostics.record("personal-model-unreadable", metadata: ["reason": "read"])
            return nil
        }
    }

    /// Replaces the trained table atomically: a full record is written to a
    /// sibling in the same owner-only directory and renamed over the live
    /// file, so an interrupted save leaves the previous model intact rather
    /// than a half-written one.
    private func saveTrainedModelSynchronously(_ model: PersonalNextWordStoredModel) throws {
        let keyData = try keyProvider.loadOrCreateKey()
        guard keyData.count == 32 else { throw PersonalHistoryStorageError.invalidKey }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(model)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: Self.modelAuthenticatedData
        )
        guard let combined = sealed.combined else {
            throw PersonalHistoryStorageError.corruptStore
        }
        var contents = Self.modelHeader
        contents.append(combined.base64EncodedData())
        contents.append(0x0A)
        guard contents.count <= Self.maximumEncryptedModelBytes else {
            throw PersonalHistoryStorageError.invalidEvent
        }
        guard let handle = SecureLocalStorage.openFileForReadingAndAppending(
            at: modelTemporaryLocation
        ) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: contents)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            _ = SecureLocalStorage.removeOwnerOnlyFile(at: modelTemporaryLocation)
            throw error
        }
        guard SecureLocalStorage.replaceOwnerOnlyFile(
            at: modelLocation,
            with: modelTemporaryLocation
        ) else {
            _ = SecureLocalStorage.removeOwnerOnlyFile(at: modelTemporaryLocation)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func decode(_ data: Data, keyData: Data) throws -> PersonalHistoryReplay {
        guard keyData.count == 32 else { throw PersonalHistoryStorageError.invalidKey }
        let key = SymmetricKey(data: keyData)
        let decoder = JSONDecoder()
        var records: [PersonalHistoryRecord] = []
        var checkpoint: PersonalNextWordStoredCheckpoint?
        for line in data.split(separator: 0x0A) {
            guard line.count + 1 <= maximumEncryptedRecordBytes,
                  let combined = Data(base64Encoded: Data(line)),
                  let box = try? AES.GCM.SealedBox(combined: combined),
                  let plaintext = try? AES.GCM.open(
                    box,
                    using: key,
                    authenticating: authenticatedData
                  ) else {
                throw PersonalHistoryStorageError.corruptStore
            }
            if let batch = try? decoder.decode(StoredBatch.self, from: plaintext),
               batch.isValid {
                records.append(PersonalHistoryRecord(
                    sequence: batch.sequence ?? 0,
                    events: batch.events
                ))
                if let stored = batch.checkpoint {
                    checkpoint = stored.isCompatibleWithCurrentExperiment ? stored : nil
                }
            } else if let legacy = try? decoder.decode(PersonalHistoryEvent.self, from: plaintext) {
                records.append(PersonalHistoryRecord(sequence: 0, events: [legacy]))
            } else {
                throw PersonalHistoryStorageError.corruptStore
            }
        }
        return PersonalHistoryReplay(records: records, checkpoint: checkpoint)
    }

    private struct StoredBatch: Codable {
        let v: Int
        let events: [PersonalHistoryEvent]
        let checkpoint: PersonalNextWordStoredCheckpoint?
        /// Absent in records written before log positions existed; those
        /// read as position 0, which no saved model can claim to cover.
        let sequence: Int64?

        init(
            events: [PersonalHistoryEvent],
            checkpoint: PersonalNextWordStoredCheckpoint?,
            sequence: Int64
        ) {
            v = 1
            self.events = events
            self.checkpoint = checkpoint
            self.sequence = sequence
        }

        var isValid: Bool {
            v == 1
                && PersonalHistoryEvent.validBatch(events)
                && (checkpoint?.hasValidEnvelope ?? true)
                && (sequence.map { $0 > 0 } ?? true)
        }
    }

    private struct StoredCheckpointRecord: Decodable {
        let v: Int
        let checkpoint: PersonalNextWordStoredCheckpoint?

        private enum CodingKeys: String, CodingKey {
            case v, events, checkpoint
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try container.decode(Int.self, forKey: .v)
            guard container.contains(.events) else {
                throw PersonalHistoryStorageError.corruptStore
            }
            _ = try container.superDecoder(forKey: .events).unkeyedContainer()
            checkpoint = try container.decodeIfPresent(
                PersonalNextWordStoredCheckpoint.self,
                forKey: .checkpoint
            )
        }

        var isValid: Bool {
            v == 1 && (checkpoint?.hasValidEnvelope ?? true)
        }
    }

    /// `.clean(legacyFormat:)` when the file is a well-formed sequence of
    /// newline-terminated records (`legacyFormat` true when the same-length
    /// v1 header should be upgraded before append). `.torn` when the header
    /// is fine and every record up to `validPrefixLength` is too, but the
    /// final line has no trailing newline — the signature of a write that
    /// never finished (the process was killed or crashed mid-append) rather
    /// than genuine corruption. Anything else still fails closed.
    private enum TailStatus {
        case clean(legacyFormat: Bool)
        case torn(validPrefixLength: UInt64)
    }

    private func validateHeaderAndTail(handle: FileHandle, size: UInt64) throws -> TailStatus {
        guard size >= UInt64(Self.header.count) else {
            throw PersonalHistoryStorageError.corruptStore
        }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: Self.header.count)
        guard header == Self.header || header == Self.legacyHeader else {
            throw PersonalHistoryStorageError.corruptStore
        }
        try handle.seek(toOffset: size - 1)
        guard try handle.read(upToCount: 1) == Data([0x0A]) else {
            guard let validPrefixLength = try lastCompleteRecordBoundary(handle: handle, size: size) else {
                throw PersonalHistoryStorageError.corruptStore
            }
            return .torn(validPrefixLength: validPrefixLength)
        }
        return .clean(legacyFormat: header == Self.legacyHeader)
    }

    /// Scans backward from `size` for the newline that ends the last
    /// complete record, bounded to twice the maximum single-record size —
    /// enough to always find it when exactly one trailing record was torn
    /// (the only case a normal interrupted write can produce, since every
    /// completed record is capped at `maximumEncryptedRecordBytes`).
    /// Returns `nil` — leaving the caller to fail closed — when no boundary
    /// turns up in that window, since that means more than a single trailing
    /// record is implicated and this is no longer safely attributable to an
    /// ordinary torn write.
    private func lastCompleteRecordBoundary(handle: FileHandle, size: UInt64) throws -> UInt64? {
        let bodyStart = UInt64(Self.header.count)
        guard size > bodyStart else { return nil }
        let scanCap = UInt64(Self.maximumEncryptedRecordBytes) * 2
        let scanStart = size - bodyStart > scanCap ? size - scanCap : bodyStart
        try handle.seek(toOffset: scanStart)
        let window = try handle.read(upToCount: Int(size - scanStart)) ?? Data()
        guard let lastNewlineOffset = window.lastIndex(of: 0x0A) else {
            // No newline anywhere in the scanned window. If the window
            // reached all the way back to the first byte of the body, the
            // very first record ever written was the one interrupted —
            // recovering to an empty (header-only) body is still safe.
            // Otherwise this is more than one record's worth of unbroken
            // bytes, which a torn write cannot produce; don't guess.
            return scanStart == bodyStart ? bodyStart : nil
        }
        return scanStart + UInt64(lastNewlineOffset) + 1
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
