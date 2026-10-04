// DictationStoppedAudioRecovery.swift
// Durable audio checkpoint for a stopped dictation awaiting transcription.

import Foundation

struct DictationStoppedAudioRecovery: Equatable, Sendable {
    let url: URL
    let sessionID: UUID
    let createdAt: Date
}

struct DictationStoppedAudioRecoveryRetryRegistry {
    private var recoveries: [UUID: DictationStoppedAudioRecovery] = [:]

    mutating func retain(_ recovery: DictationStoppedAudioRecovery, for failedMeetingID: UUID) {
        recoveries[failedMeetingID] = recovery
    }

    func recovery(for failedMeetingID: UUID) -> DictationStoppedAudioRecovery? {
        recoveries[failedMeetingID]
    }

    mutating func remove(for failedMeetingID: UUID) -> DictationStoppedAudioRecovery? {
        recoveries.removeValue(forKey: failedMeetingID)
    }
}

enum DictationStoppedAudioRecoveryCommitPolicy {
    static func shouldPersist(
        taskCancelled: Bool,
        isDictating: Bool,
        taskSessionID: UUID,
        currentSessionID: UUID
    ) -> Bool {
        !taskCancelled && isDictating && taskSessionID == currentSessionID
    }

    static func shouldRetainPersistedRecovery(
        taskSessionID: UUID,
        preservationSessionID: UUID?
    ) -> Bool {
        taskSessionID == preservationSessionID
    }
}

enum DictationStoppedAudioRecoveryStore {
    static let sampleRate: UInt32 = 16_000

    private struct Metadata: Codable {
        let version: Int
        let sessionID: UUID
        let createdAt: Date
        let audioFilename: String
    }

    static var defaultDirectory: URL {
        FileManager.default.transcriptedStateDir
            .appendingPathComponent("dictation-audio-recovery", isDirectory: true)
    }

    static func persist(
        samples16k: [Float],
        sessionID: UUID,
        createdAt: Date = Date(),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> DictationStoppedAudioRecovery? {
        guard !samples16k.isEmpty else { return nil }

        let folder = directory ?? defaultDirectory
        try fileManager.createPrivateDirectory(at: folder)
        let url = folder.appendingPathComponent("dictation_\(sessionID.uuidString.lowercased()).wav")
        try wavData(samples16k: samples16k).write(to: url, options: .atomic)
        fileManager.restrictFileToOwnerOnly(at: url)
        let recovery = DictationStoppedAudioRecovery(url: url, sessionID: sessionID, createdAt: createdAt)
        do {
            try writeMetadata(for: recovery, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        return recovery
    }

    static func pendingRecoveries(
        limit: Int = 10,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [DictationStoppedAudioRecovery] {
        guard limit > 0 else { return [] }
        let folder = directory ?? defaultDirectory
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var recoveries: [DictationStoppedAudioRecovery] = []
        for case let metadataURL as URL in enumerator where metadataURL.pathExtension == "json" {
            guard let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL)),
                  metadata.version == 1 else { continue }
            let audioURL = folder.appendingPathComponent(metadata.audioFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: audioURL.path) else { continue }
            recoveries.append(DictationStoppedAudioRecovery(
                url: audioURL,
                sessionID: metadata.sessionID,
                createdAt: metadata.createdAt
            ))
        }
        return mostRecent(recoveries, limit: limit)
    }

    static func mostRecent(
        _ recoveries: [DictationStoppedAudioRecovery],
        limit: Int
    ) -> [DictationStoppedAudioRecovery] {
        guard limit > 0 else { return [] }
        return Array(
            recoveries
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
        )
    }

    @discardableResult
    static func cleanup(
        _ recovery: DictationStoppedAudioRecovery?,
        transcriptPersisted: Bool = false,
        explicitDiscard: Bool = false,
        fileManager: FileManager = .default
    ) -> Bool {
        guard transcriptPersisted || explicitDiscard,
              let recovery else { return false }

        do {
            if fileManager.fileExists(atPath: recovery.url.path) {
                try fileManager.removeItem(at: recovery.url)
            }
            let metadataURL = metadataURL(for: recovery.url)
            if fileManager.fileExists(atPath: metadataURL.path) {
                try fileManager.removeItem(at: metadataURL)
            }
            return true
        } catch {
            return false
        }
    }

    /// Retires a take's checkpoint once its transcript is saved. A failed
    /// save keeps the WAV; the next launch's `purgeLeftovers` removes it.
    @discardableResult
    static func retire(
        _ recovery: DictationStoppedAudioRecovery?,
        afterSaving result: DictationTranscriptPersistenceResult,
        fileManager: FileManager = .default
    ) -> Bool {
        cleanup(recovery, transcriptPersisted: result.saved != nil, fileManager: fileManager)
    }

    /// Deletes every recording saved before `cutoff`, with its metadata.
    /// Launch runs this with the launch time: nothing offers a saved
    /// recording after its own take ends, so a WAV from an earlier run (a
    /// failed take nobody transcribed, or one left by Quit or a crash) is
    /// just private audio sitting on disk. Files from this run are newer
    /// than `cutoff` and stay. Only `dictation_*.wav` and `dictation_*.json`
    /// directly inside `directory` are touched. Returns how many recordings
    /// were removed.
    @discardableResult
    static func purgeLeftovers(
        createdBefore cutoff: Date,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int {
        let folder = (directory ?? defaultDirectory).standardizedFileURL
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        // Both sides resolved the same way, so /var vs /private/var can't
        // make a file look like it lives somewhere else.
        func resolvedPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let folderPath = resolvedPath(folder)
        func isOwnedFile(_ url: URL, extension pathExtension: String) -> Bool {
            url.lastPathComponent.hasPrefix("dictation_")
                && url.pathExtension == pathExtension
                && resolvedPath(url.deletingLastPathComponent()) == folderPath
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        func modifiedBeforeCutoff(_ url: URL) -> Bool {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return false
            }
            return modified < cutoff
        }

        var removed = 0
        var claimedAudio: Set<String> = []
        for metadataURL in contents where isOwnedFile(metadataURL, extension: "json") {
            let audioURL: URL?
            let isOld: Bool
            if let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL)) {
                let candidate = folder.appendingPathComponent(metadata.audioFilename, isDirectory: false)
                audioURL = isOwnedFile(candidate, extension: "wav") ? candidate : nil
                isOld = metadata.createdAt < cutoff
            } else {
                // Unreadable metadata from an older or broken write. Its
                // WAV, if any, has the same name.
                let sibling = metadataURL.deletingPathExtension().appendingPathExtension("wav")
                audioURL = isOwnedFile(sibling, extension: "wav") ? sibling : nil
                isOld = modifiedBeforeCutoff(metadataURL)
            }
            if let audioURL { claimedAudio.insert(audioURL.lastPathComponent) }
            guard isOld else { continue }
            if let audioURL { try? fileManager.removeItem(at: audioURL) }
            try? fileManager.removeItem(at: metadataURL)
            removed += 1
        }
        // A WAV without metadata: the app stopped between the two writes.
        // Its file date says which run it came from.
        for audioURL in contents where isOwnedFile(audioURL, extension: "wav")
            && !claimedAudio.contains(audioURL.lastPathComponent)
            && !fileManager.fileExists(atPath: metadataURL(for: audioURL).path)
            && modifiedBeforeCutoff(audioURL) {
            try? fileManager.removeItem(at: audioURL)
            removed += 1
        }
        return removed
    }

    private static func writeMetadata(
        for recovery: DictationStoppedAudioRecovery,
        fileManager: FileManager
    ) throws {
        let metadata = Metadata(
            version: 1,
            sessionID: recovery.sessionID,
            createdAt: recovery.createdAt,
            audioFilename: recovery.url.lastPathComponent
        )
        try write(metadata, to: metadataURL(for: recovery.url), fileManager: fileManager)
    }

    private static func write(_ metadata: Metadata, to url: URL, fileManager: FileManager) throws {
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
        fileManager.restrictFileToOwnerOnly(at: url)
    }

    private static func metadataURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("json")
    }

    private static func wavData(samples16k: [Float]) -> Data {
        let bytesPerSample: UInt16 = 2
        let channelCount: UInt16 = 1
        let dataByteCount = UInt32(samples16k.count) * UInt32(bytesPerSample)
        var data = Data(capacity: 44 + Int(dataByteCount))

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + dataByteCount, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channelCount, to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * UInt32(channelCount) * UInt32(bytesPerSample), to: &data)
        append(channelCount * bytesPerSample, to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(dataByteCount, to: &data)

        // Convert into one contiguous Int16 block, then append it in a single
        // call. The per-sample `append(_:to:)` helper pays a `withUnsafeBytes`
        // closure plus a `Sequence` append for every sample, which dominated
        // this function: at the 5-minute dictation cap that is 4.8M round trips.
        // The arithmetic below is byte-for-byte the old expression — the NaN
        // guard, the clamp, `Float(Int16.max)`, and bare `.rounded()`
        // (schoolbook, half-away-from-zero) are all load-bearing for that.
        let pcm = [Int16](unsafeUninitializedCapacity: samples16k.count) { buffer, initializedCount in
            samples16k.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    let sample = source[index]
                    let finiteSample = sample.isFinite ? sample : 0
                    let clamped = max(-1, min(1, finiteSample))
                    buffer[index] = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
                }
            }
            initializedCount = samples16k.count
        }
        pcm.withUnsafeBufferPointer { data.append($0) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
