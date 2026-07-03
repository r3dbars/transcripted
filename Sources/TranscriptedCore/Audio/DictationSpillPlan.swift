import Foundation

public struct DictationSpillPlan: Equatable, Sendable {
    public static let defaultChunkDuration: TimeInterval = 10
    public static let defaultMaximumRecoverableDuration: TimeInterval = 5 * 60

    public let sessionID: UUID
    public let directory: URL
    public let sampleRate: Double
    public let chunkDuration: TimeInterval
    public let maximumRecoverableDuration: TimeInterval

    public var journalURL: URL {
        directory.appendingPathComponent("\(sessionID.uuidString).dictation-recording.json")
    }

    public var maximumRecoverableChunks: Int {
        guard chunkDuration > 0, maximumRecoverableDuration > 0 else { return 0 }
        return Int(ceil(maximumRecoverableDuration / chunkDuration))
    }

    public init(
        sessionID: UUID = UUID(),
        directory: URL,
        sampleRate: Double,
        chunkDuration: TimeInterval = Self.defaultChunkDuration,
        maximumRecoverableDuration: TimeInterval = Self.defaultMaximumRecoverableDuration
    ) {
        self.sessionID = sessionID
        self.directory = directory
        self.sampleRate = sampleRate
        self.chunkDuration = max(1, chunkDuration)
        self.maximumRecoverableDuration = max(self.chunkDuration, maximumRecoverableDuration)
    }

    public func chunkURL(index: Int) -> URL {
        let safeIndex = max(0, index)
        let filename = "\(sessionID.uuidString)-chunk-\(String(format: "%05d", safeIndex)).pcm"
        return directory.appendingPathComponent(filename)
    }

    public func shouldRotateChunk(currentFrameCount: Int) -> Bool {
        guard sampleRate.isFinite, sampleRate > 0 else { return false }
        return currentFrameCount >= Int((sampleRate * chunkDuration).rounded())
    }
}
