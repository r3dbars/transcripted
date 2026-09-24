import AVFoundation
import Foundation

/// Admission happens before any cancellation or readiness mutation. A picker
/// change is not permission to interrupt a recording or an active decoder.
enum ParakeetModelSelectionPolicy {
    static func canSelect(
        _ requested: ParakeetModelVariant,
        current: ParakeetModelVariant,
        hasActiveWork: Bool
    ) -> Bool {
        requested == current || !hasActiveWork
    }

    /// Prefetch is network-only: even an idle loaded manager must survive it.
    static func canPrefetch(hasManager: Bool, hasActiveWork: Bool) -> Bool {
        !hasManager && !hasActiveWork
    }
}

/// Wait for decoder ownership to drain without polling. Each canceled waiter
/// removes only its own continuation; it cannot open the gate for a successor.
@MainActor
final class ParakeetModelTeardownGate {
    private(set) var isPending = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func begin() { isPending = true }

    func finish() {
        isPending = false
        let completed = Array(waiters.values)
        waiters.removeAll()
        for waiter in completed { waiter.resume(returning: true) }
    }

    func wait() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isPending else { return true }
        let id = UUID()
        let finished = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation may have arrived before registration.
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
        return finished && !Task.isCancelled
    }
}

/// A canceled task may still own native resources. Its successor waits for
/// actual completion, not just the cancellation flag.
enum ParakeetModelTaskDrain {
    static func draining(
        _ initialization: Task<Void, Never>,
        after cleanup: Task<Void, Never>?
    ) -> Task<Void, Never> {
        Task {
            await cleanup?.value
            await initialization.value
        }
    }
}

/// Both dimensions are needed: switching away and back creates a new attempt
/// even when the variant matches again. Used at every asynchronous model seam.
struct ParakeetModelWorkToken: Equatable {
    let variant: ParakeetModelVariant
    let generation: UInt64

    func isCurrent(variant: ParakeetModelVariant, generation: UInt64) -> Bool {
        self.variant == variant && self.generation == generation
    }
}

final class ParakeetModelDownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let stageCount: Int
    private var stageIndex = 0
    private var stageProgress = 0.0
    private var maximumPublishedProgress = 0.0
    private var lastCallbackProgress = -1.0
    private var lastActivityUptime: TimeInterval

    init(
        stageCount: Int = 4,
        initialActivityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.stageCount = max(1, stageCount)
        self.lastActivityUptime = initialActivityUptime
    }

    /// FluidAudio reports each Parakeet model component as a separate 0...1
    /// operation. Fold those updates into one monotonic 0...1 value so the UI
    /// never jumps backward between component downloads.
    func overallProgress(rawProgress: Double, beginsNewStage: Bool) -> Double {
        lock.withLock {
            updateLocked(rawProgress: rawProgress, beginsNewStage: beginsNewStage)
        }
    }

    /// Keep byte-level callbacks useful without scheduling tens of thousands
    /// of main-actor UI updates during a large download.
    func progressToPublish(
        rawProgress: Double,
        beginsNewStage: Bool,
        activityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double? {
        lock.withLock {
            lastActivityUptime = max(lastActivityUptime, activityUptime)
            let overall = updateLocked(
                rawProgress: rawProgress,
                beginsNewStage: beginsNewStage
            )
            guard beginsNewStage
                || overall >= 1
                || overall - lastCallbackProgress >= 0.002
            else {
                return nil
            }
            lastCallbackProgress = overall
            return overall
        }
    }

    func remainingNoProgressInterval(
        timeout: TimeInterval,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        lock.withLock {
            max(0, timeout - max(0, nowUptime - lastActivityUptime))
        }
    }

    private func updateLocked(rawProgress: Double, beginsNewStage: Bool) -> Double {
        let clamped = max(0, min(1, rawProgress))
        // FluidAudio emits `.listing` only for the first component. Each later
        // component restarts its own 0...1 progress range, commonly at 0.5.
        let restartedCompletedStage = stageProgress >= 0.99
            && clamped < stageProgress - 0.25
        if stageProgress >= 0.99, beginsNewStage || restartedCompletedStage {
            stageIndex = min(stageIndex + 1, stageCount - 1)
            stageProgress = 0
        }

        stageProgress = max(stageProgress, clamped)
        let overall = min(
            1,
            (Double(stageIndex) + stageProgress) / Double(stageCount)
        )
        maximumPublishedProgress = max(maximumPublishedProgress, overall)
        return maximumPublishedProgress
    }
}

enum ParakeetModelDownloadAttemptPolicy {
    static func isCurrent(expectedGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        expectedGeneration == currentGeneration
    }

    static func shouldTimeOut(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        hasActiveTask: Bool,
        taskCancelled: Bool
    ) -> Bool {
        isCurrent(
            expectedGeneration: expectedGeneration,
            currentGeneration: currentGeneration
        )
            && hasActiveTask
            && !taskCancelled
    }
}

enum ParakeetModelInitStage: String, Equatable {
    case authorizationRequest = "authorization_request"
    case bundleLoad = "bundle_load"
    case downloadModels = "download_models"
    case managerInitialize = "manager_initialize"
}

enum ParakeetModelLoadSource: String, Equatable {
    case unresolved
    case bundle
    case download
}

struct ParakeetBundledModelLayout: Equatable {
    let subdirectory: String
    let checkFile: String
}

enum ParakeetBundledModelLayoutPolicy {
    static let runtime = ParakeetBundledModelLayout(
        subdirectory: "parakeet-tdt-0.6b-v3",
        checkFile: "JointDecisionv3.mlmodelc"
    )

    // FluidAudio reloads v3 from its canonical folder name, so a legacy-only
    // bundled directory is not actually loadable and must fail closed here.
    static func resolveBundledModelPath(
        resourcePath: String?,
        variant: ParakeetModelVariant = .v3,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        guard let resourcePath, !variant.isLocalInstallOnly else { return nil }

        let root = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("parakeet-models")
        let path = root.appendingPathComponent(variant.directoryName)
        let required = variant.requiredModelDirectoryNames.map { "\($0)/coremldata.bin" }
            + variant.requiredFileNames
        guard required.allSatisfy({ fileExists(path.appendingPathComponent($0).path) }) else {
            return nil
        }
        return path
    }
}

enum ParakeetLocalModelError: LocalizedError, Equatable, CaseIterable {
    case notInstalled
    case loadFailed
    case replacedDuringLoad

    /// Stable, path-free label for local event context.
    var reason: String {
        switch self {
        case .notInstalled: return "not_installed"
        case .loadFailed: return "load_failed"
        case .replacedDuringLoad: return "replaced_during_load"
        }
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Parakeet Ultra isn't installed on this Mac. Run the Parakeet Ultra install script, or pick Parakeet V3."
        case .loadFailed:
            return "Parakeet Ultra is installed, but its model files didn't load. If trying again doesn't help, run its install script again."
        case .replacedDuringLoad:
            return "Parakeet Ultra's files changed while it was loading. Run its install script again, or pick Parakeet V3."
        }
    }
}

/// Local-only models load through `ParakeetLocalModelLoader`, never through
/// FluidAudio's `AsrModels.load`: that answers a failed load by deleting the
/// folder and downloading stock v3 into it, which would destroy the install
/// and run v3 under the experimental model's name. The marker check after a
/// load is a second layer in case the folder changes underneath it.
enum ParakeetLocalModelPolicy {
    /// The compiled Core ML models and vocabulary a local-only install holds,
    /// named as FluidAudio's v3 layout names them (unchanged from 0.15.x
    /// through 0.17.0 for the default int8 encoder).
    static let preprocessorFileName = "Preprocessor.mlmodelc"
    static let encoderFileName = "Encoder.mlmodelc"
    static let decoderFileName = "Decoder.mlmodelc"
    static let jointFileName = "JointDecisionv3.mlmodelc"
    static let vocabularyFileName = "parakeet_vocab.json"
    static var loadedFileNames: [String] {
        [preprocessorFileName, encoderFileName, decoderFileName, jointFileName, vocabularyFileName]
    }

    /// FluidAudio's v3 vocabulary format: a JSON object keyed by token id.
    static func parseVocabulary(_ data: Data) throws -> [Int: String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ParakeetLocalModelError.loadFailed
        }
        var vocabulary: [Int: String] = [:]
        for (key, token) in object {
            guard let id = Int(key) else { throw ParakeetLocalModelError.loadFailed }
            vocabulary[id] = token
        }
        guard !vocabulary.isEmpty else { throw ParakeetLocalModelError.loadFailed }
        return vocabulary
    }

    static func verifyLoadedFromLocalInstall(
        variant: ParakeetModelVariant,
        directory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws {
        guard variant.isLocalInstallOnly else { return }
        let marker = directory.appendingPathComponent(ParakeetModelVariant.localInstallMarkerFileName)
        guard fileExists(marker.path) else {
            throw ParakeetLocalModelError.replacedDuringLoad
        }
    }
}

enum ParakeetModelInitDiagnostics {
    static func failureContext(
        stage: ParakeetModelInitStage,
        loadSource: ParakeetModelLoadSource,
        bundledModelPresent: Bool,
        microphoneStatus: AVAuthorizationStatus
    ) -> [String: String] {
        [
            "failure_stage": stage.rawValue,
            "load_source": loadSource.rawValue,
            "model_bundle_present": bundledModelPresent ? "true" : "false",
            "mic_status": microphoneStatus.diagnosticName,
        ]
    }
}
