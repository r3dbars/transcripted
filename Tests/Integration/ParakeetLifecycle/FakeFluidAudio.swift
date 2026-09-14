// Test-only module boundary. Compile as FluidAudio; never link into the app.
#if !FAKE_CORE
import Foundation
import CoreML

public enum AsrModelVersion: String, Sendable { case v2, v3 }
public struct DownloadProgress: Sendable {
    public enum Phase: Sendable { case listing, downloading, compiling }
    public let phase: Phase
    public let fractionCompleted: Double
}

/// Deliberately ignores task cancellation, as native CoreML work may do.
/// Tests explicitly release each suspension and prove stale work is drained.
public actor FakeFluidAudio {
    public static let shared = FakeFluidAudio()
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    private var callbacks: [String: @Sendable (DownloadProgress) -> Void] = [:]
    private var counts: [String: Int] = [:]
    private var holdNextCleanup = false
    public private(set) var events: [String] = []
    public func reset() {
        precondition(pending.isEmpty, "Unreleased fake operations")
        callbacks.removeAll(); counts.removeAll(); events.removeAll()
        holdNextCleanup = false
    }
    public func suspend(_ operation: String) async throws {
        counts[operation, default: 0] += 1
        let key = "\(operation)#\(counts[operation]!)"
        events.append(key)
        try await withCheckedThrowingContinuation { pending[key] = $0 }
    }
    public func download(_ version: AsrModelVersion, callback: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let key = "download-\(version.rawValue)#\(counts["download-\(version.rawValue)", default: 0] + 1)"
        callbacks[key] = callback
        try await suspend("download-\(version.rawValue)")
    }
    public func release(_ key: String, fail: Bool = false) {
        guard let continuation = pending.removeValue(forKey: key) else { preconditionFailure("No pending \(key)") }
        if fail { continuation.resume(throwing: NSError(domain: "fake-loader", code: 42)) }
        else { continuation.resume() }
    }
    public func progress(_ key: String, _ fraction: Double) {
        callbacks[key]?(DownloadProgress(phase: .downloading, fractionCompleted: fraction))
    }
    public func record(_ event: String) { events.append(event) }
    public func delayNextCleanup() { holdNextCleanup = true }
    public func cleanup(_ version: AsrModelVersion) async {
        events.append("cleanup-\(version.rawValue)")
        if holdNextCleanup {
            holdNextCleanup = false
            try? await suspend("cleanup-drain-\(version.rawValue)")
        }
    }
}

public struct AsrModels: Sendable {
    public let version: AsrModelVersion
    public static func defaultCacheDirectory(for version: AsrModelVersion) -> URL {
        URL(fileURLWithPath: "/nonexistent-parakeet-test-cache/\(version.rawValue)")
    }
    public static func download(version: AsrModelVersion, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        try await FakeFluidAudio.shared.download(version, callback: progress)
        return defaultCacheDirectory(for: version)
    }
    public static func load(from: URL, version: AsrModelVersion, encoderComputeUnits: MLComputeUnits?) async throws -> AsrModels {
        try await FakeFluidAudio.shared.suspend("load-\(version.rawValue)")
        return AsrModels(version: version)
    }
}

public actor AsrManager {
    public enum Config: Sendable { case `default` }
    private var version: AsrModelVersion = .v3
    public init(config: Config) {}
    public func loadModels(_ models: AsrModels) async throws {
        version = models.version
        try await FakeFluidAudio.shared.suspend("manager-\(version.rawValue)")
    }
    public func cleanup() async {
        await FakeFluidAudio.shared.cleanup(version)
    }
}
#endif
