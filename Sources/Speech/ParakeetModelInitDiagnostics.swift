import AVFoundation
import Foundation

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
