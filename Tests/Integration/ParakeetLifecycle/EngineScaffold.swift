import AVFoundation
import Foundation
import FluidAudio

// The production lifecycle extension is compiled unchanged against this state
// scaffold. Audio graph, cache IO, logging and external downloads are excluded.
// No lifecycle implementation belongs here: tests must exercise the real file.
@MainActor final class ParakeetEngine {
    var isShuttingDown = false
    var isRecording = false
    var isTranscribing = false
    var hasActiveASRWork = false
    var asrManager: AsrManager?
    var modelVariant: ParakeetModelVariant = .v3
    var loadedModelVariant: ParakeetModelVariant?
    var modelCleanupTask: Task<Void, Never>?
    let modelTeardownGate = ParakeetModelTeardownGate()
    var modelInitializationTask: Task<Void, Never>?
    var modelInitializationGeneration: UInt64 = 0
    var modelFilePrefetchTask: Task<URL, Error>?
    var prefetchedModelPath: URL?
    var modelDownloadWatchdogTask: Task<Void, Never>?
    var modelDownloadAttemptGeneration: UInt64 = 0
    var asrManagerReady = false
    var modelDownloadState: ParakeetModelState = .notLoaded
    func isModelLoaded(for variant: ParakeetModelVariant) -> Bool {
        asrManagerReady && loadedModelVariant == variant
    }
    func scheduleInputDeviceNameRefresh() {}
}

@MainActor enum ModelCacheInventory {
    // Fake only the cache collaborator. Whether and when migration is called
    // remains the production lifecycle executor's decision.
    static var legacyVariant: ParakeetModelVariant?
    static var cachedVariant: ParakeetModelVariant?
    static var migrationAttempts: [ParakeetModelVariant] = []

    static func reset() {
        legacyVariant = nil
        cachedVariant = nil
        migrationAttempts = []
    }

    static func activeParakeetModelDirectory(variant: ParakeetModelVariant) -> URL? {
        cachedVariant == variant ? AsrModels.defaultCacheDirectory(for: variant.fluidAudioVersion) : nil
    }

    static func defaultLocalModelsDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-lifecycle-local-models", isDirectory: true)
    }

    static func migrateLegacyParakeetModelDirectory(variant: ParakeetModelVariant, fluidAudioModelsDirectory: URL) throws -> Bool {
        migrationAttempts.append(variant)
        guard legacyVariant == variant, cachedVariant == nil else { return false }
        cachedVariant = variant
        legacyVariant = nil
        return true
    }
}
enum ModelDownloadService {
    struct Failure { let detail: String }
    static func classifyError(_ error: Error) -> Failure { Failure(detail: "fake load failed") }
}
struct SilentLogger {
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}
enum AppLogger { static let transcription = SilentLogger() }
@MainActor final class EventReporter {
    enum Level { case info, warning, error }
    static let shared = EventReporter()
    func capture(level: Level, engine: String, event: String, message: String, context: [String: String] = [:]) {}
}
extension AVAuthorizationStatus { var diagnosticName: String { "test" } }
