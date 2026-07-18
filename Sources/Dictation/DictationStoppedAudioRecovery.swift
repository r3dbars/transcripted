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
        let url = metadataURL(for: recovery.url)
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

        for sample in samples16k {
            let finiteSample = sample.isFinite ? sample : 0
            let clamped = max(-1, min(1, finiteSample))
            let pcm = Int16((clamped * Float(Int16.max)).rounded())
            append(UInt16(bitPattern: pcm), to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
