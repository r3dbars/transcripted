// ParakeetModelLifecycle.swift
// Model load/download/warmup/teardown paths for ParakeetEngine, split out of
// ParakeetEngine.swift (codebase audit 2026-07-08 wave 2, spec W2-C).
//
// These are internal collaborator methods on ParakeetEngine — ParakeetEngine
// remains the public-API owner and MainActor home for this state; this file
// just groups the model-lifecycle slice of its implementation.

@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import TranscriptedCore

extension ParakeetModelVariant {
    var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        }
    }
}

private final class ParakeetModelDownloadProgressTarget: @unchecked Sendable {
    weak var engine: ParakeetEngine?

    @MainActor
    init(engine: ParakeetEngine) {
        self.engine = engine
    }
}

extension ParakeetEngine {
    // MARK: - Model Initialization

    private static let stalledDownloadMessage =
        "The model download stopped making progress. Check your connection and retry the download."
    /// Slow downloads remain valid while bytes are moving. A silent task
    /// fails into the existing Retry Download path instead of waiting forever.
    private static let modelDownloadNoProgressTimeout: TimeInterval = 300
    /// Local benchmark override. Production keeps FluidAudio's power-efficient
    /// default unless the benchmark script explicitly selects another path.
    private static var benchmarkEncoderComputeUnits: MLComputeUnits? {
        switch ProcessInfo.processInfo.environment[
            "TRANSCRIPTED_PARAKEET_ENCODER_COMPUTE_UNITS"
        ] {
        case "cpu_and_gpu":
            return .cpuAndGPU
        case "all":
            return .all
        default:
            return nil
        }
    }

    private func startModelDownloadTask() -> Task<URL, Error> {
        let variant = modelVariant
        let progressTracker = ParakeetModelDownloadProgressTracker()
        let generation = beginModelDownloadAttempt(progressTracker: progressTracker)
        let token = ParakeetModelWorkToken(variant: variant, generation: generation)
        let progressTarget = ParakeetModelDownloadProgressTarget(engine: self)
        let task = Task.detached(priority: .utility) {
            try await AsrModels.download(version: variant.fluidAudioVersion) { progress in
                let beginsNewStage: Bool
                switch progress.phase {
                case .listing:
                    beginsNewStage = true
                case .downloading, .compiling:
                    beginsNewStage = false
                }
                guard let overallProgress = progressTracker.progressToPublish(
                    rawProgress: progress.fractionCompleted,
                    beginsNewStage: beginsNewStage
                ) else { return }
                Task { @MainActor in
                    progressTarget.engine?.recordModelDownloadProgress(
                        overallProgress,
                        token: token
                    )
                }
            }
        }
        modelFilePrefetchTask = task
        return task
    }

    private func beginModelDownloadAttempt(
        progressTracker: ParakeetModelDownloadProgressTracker
    ) -> UInt64 {
        modelDownloadAttemptGeneration &+= 1
        modelDownloadState = .downloading(progress: 0)
        scheduleModelDownloadWatchdog(
            generation: modelDownloadAttemptGeneration,
            progressTracker: progressTracker
        )
        return modelDownloadAttemptGeneration
    }

    private func recordModelDownloadProgress(_ progress: Double, token: ParakeetModelWorkToken) {
        guard token.isCurrent(
            variant: modelVariant,
            generation: modelDownloadAttemptGeneration
        ), modelFilePrefetchTask != nil else { return }
        modelDownloadState = .downloading(progress: max(0, min(1, progress)))
    }

    // Internal so the executor integration harness can supply an aged progress
    // tracker without shortening the production five-minute timeout.
    func scheduleModelDownloadWatchdog(
        generation: UInt64,
        progressTracker: ParakeetModelDownloadProgressTracker
    ) {
        let token = ParakeetModelWorkToken(variant: modelVariant, generation: generation)
        modelDownloadWatchdogTask?.cancel()
        modelDownloadWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let remaining = progressTracker.remainingNoProgressInterval(
                    timeout: Self.modelDownloadNoProgressTimeout
                )
                guard remaining > 0 else { break }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
            guard let self else { return }
            guard token.isCurrent(variant: self.modelVariant, generation: self.modelDownloadAttemptGeneration),
                ParakeetModelDownloadAttemptPolicy.shouldTimeOut(
                expectedGeneration: generation,
                currentGeneration: self.modelDownloadAttemptGeneration,
                hasActiveTask: self.modelFilePrefetchTask != nil,
                taskCancelled: Task.isCancelled
            ) else {
                return
            }

            self.cancelModelWork()
            self.modelDownloadState = .failed(Self.stalledDownloadMessage)
            EventReporter.shared.capture(
                level: .error,
                engine: "parakeet",
                event: "model_download_stalled",
                message: "Local speech model download stopped making progress",
                context: [
                    "failure_kind": "no_progress_timeout",
                    "stall_stage": "model_download",
                ]
            )
        }
    }

    @discardableResult
    private func finishModelDownloadAttempt(generation: UInt64) -> Bool {
        guard ParakeetModelDownloadAttemptPolicy.isCurrent(
            expectedGeneration: generation,
            currentGeneration: modelDownloadAttemptGeneration
        ) else { return false }
        modelDownloadWatchdogTask?.cancel()
        modelDownloadWatchdogTask = nil
        return true
    }

    /// Load Parakeet models from the app bundle (preferred) or download from HuggingFace (fallback).
    /// Bundle path: Contents/Resources/parakeet-models/<variant directory>/
    func initialize(variant: ParakeetModelVariant = .v3) async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        guard selectModelVariant(variant) else { return }
        guard !isModelLoaded(for: variant) else { return }

        if let modelInitializationTask {
            await modelInitializationTask.value
            return
        }

        modelInitializationGeneration &+= 1
        let token = ParakeetModelWorkToken(variant: variant, generation: modelInitializationGeneration)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialize(token: token)
        }
        modelInitializationTask = task
        await task.value
    }

    private func isCurrent(_ token: ParakeetModelWorkToken) -> Bool {
        !isShuttingDown && !Task.isCancelled
            && token.isCurrent(variant: modelVariant, generation: modelInitializationGeneration)
    }

    @discardableResult
    func prepareModelVariantForRecording(_ variant: ParakeetModelVariant) -> Bool {
        // Establish the concrete identity before audio capture begins. Cached
        // dictation can record before asynchronous CoreML warmup has started.
        selectModelVariant(variant)
    }

    @discardableResult
    private func selectModelVariant(_ variant: ParakeetModelVariant) -> Bool {
        // Keep the existing ready state intact when a caller bypasses router
        // ownership. Publishing a failure here would also disrupt its capture.
        guard ParakeetModelSelectionPolicy.canSelect(
            variant,
            current: modelVariant,
            hasActiveWork: isRecording || isTranscribing || hasActiveASRWork
        ) else { return false }
        guard variant != modelVariant else { return true }
        cancelModelWork()
        teardownModel()
        modelVariant = variant
        prefetchedModelPath = nil
        markCachedRuntimeModelIfAvailable()
        return true
    }

    private func performInitialize(token: ParakeetModelWorkToken) async {
        defer {
            if token.isCurrent(variant: modelVariant, generation: modelInitializationGeneration) {
                modelInitializationTask = nil
            }
        }
        guard isCurrent(token) else { return }
        // A canceled inference still owns its decoder until it actually ends.
        // Drain it before installing a different manager; selection alone is
        // not permission to release CoreML resources under active work.
        finishDeferredModelTeardownIfIdle()
        guard await modelTeardownGate.wait(), isCurrent(token) else { return }
        if let modelCleanupTask { await modelCleanupTask.value }
        guard isCurrent(token) else { return }
        scheduleInputDeviceNameRefresh()
        markCachedRuntimeModelIfAvailable()

        guard !isModelLoaded(for: token.variant) else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "already_initialized",
                message: "initialize() called but ASR manager already exists — ignoring")
            modelDownloadState = .ready
            return
        }

        switch modelDownloadState {
        case .downloading:
            break
        case .loading:
            return
        case .notLoaded, .cached, .ready, .failed:
            break
        }

        // Keep background model warmup quiet. The onboarding/settings surfaces
        // own microphone permission requests so launch-time initialization does
        // not surprise users with a hidden or out-of-context prompt.

        modelDownloadState = .loading
        AppLogger.transcription.info("PARAKEET | initializing models...")

        var failureStage: ParakeetModelInitStage = .authorizationRequest
        var loadSource: ParakeetModelLoadSource = .unresolved
        Self.migrateLegacyParakeetCacheIfNeeded(variant: token.variant)
        // FluidAudio 0.15.x resolves bundled models as <parent>/<repo folderName>, and the
        // folder name lost its -coreml suffix. Require the requested variant's complete
        // layout so an incomplete bundle can't trigger a download into the signed bundle.
        let bundledModelPath = bundledParakeetModelPath(variant: token.variant)
        let bundledModelPresent = bundledModelPath != nil
        let encoderComputeUnits = Self.benchmarkEncoderComputeUnits

        do {
            let models: AsrModels
            let loadSourceName: String

            // Try loading from app bundle first (bundled by build.sh)
            if let bundlePath = bundledModelPath {
                failureStage = .bundleLoad
                loadSource = .bundle
                AppLogger.transcription.info("PARAKEET | loading from bundle: \(bundlePath.path)")
                models = try await AsrModels.load(
                    from: bundlePath,
                    version: token.variant.fluidAudioVersion,
                    encoderComputeUnits: encoderComputeUnits
                )
                guard isCurrent(token) else { return }
                loadSourceName = loadSource.rawValue
            } else {
                // Fallback: download from HuggingFace (~600MB on first run).
                //
                // SECURITY: AsrModels.download() pulls model artifacts from HuggingFace
                // through FluidAudio. Transcripted does not currently re-verify the
                // downloaded artifacts against pinned SHA-256 digests. Trust here rests
                // on the system TLS chain plus HuggingFace's CDN integrity. A targeted
                // TLS interception or CDN compromise could swap the model files, with
                // a worst-case impact of bad transcriptions or — much less likely —
                // exploitation of a Core ML deserialization bug.
                //
                // To close this gap we'd ship a static `[filename: sha256]` table for
                // each supported Parakeet variant and verify it after download, before
                // calling AsrModels.load(...). The hashes need to be computed from a
                // trusted release of the model bundle; without that source of truth a
                // verification stub would be worse than no check at all.
                failureStage = .downloadModels
                loadSource = .download
                let downloadedPath: URL
                if let modelFilePrefetchTask {
                    AppLogger.transcription.info("PARAKEET | waiting for background Parakeet model cache...")
                    let generation = modelDownloadAttemptGeneration
                    downloadedPath = try await modelFilePrefetchTask.value
                    guard isCurrent(token) else { return }
                    guard finishModelDownloadAttempt(generation: generation) else { return }
                    prefetchedModelPath = downloadedPath
                    self.modelFilePrefetchTask = nil
                } else if let prefetchedModelPath {
                    downloadedPath = prefetchedModelPath
                } else if let cachedModelPath = ModelCacheInventory.activeParakeetModelDirectory(variant: token.variant) {
                    prefetchedModelPath = cachedModelPath
                    downloadedPath = cachedModelPath
                } else {
                    AppLogger.transcription.info("PARAKEET | models not bundled, downloading \(token.variant.rawValue)...")
                    let task = startModelDownloadTask()
                    let generation = modelDownloadAttemptGeneration
                    downloadedPath = try await task.value
                    guard isCurrent(token) else { return }
                    guard finishModelDownloadAttempt(generation: generation) else { return }
                    modelFilePrefetchTask = nil
                    prefetchedModelPath = downloadedPath
                }
                guard isCurrent(token) else { return }
                modelDownloadState = .loading
                AppLogger.transcription.info("PARAKEET | loading downloaded models from: \(downloadedPath.path)")
                models = try await AsrModels.load(
                    from: downloadedPath,
                    version: token.variant.fluidAudioVersion,
                    encoderComputeUnits: encoderComputeUnits
                )
                guard isCurrent(token) else { return }
                loadSourceName = loadSource.rawValue
            }

            failureStage = .managerInitialize
            let manager = AsrManager(config: .default)
            do {
                try await manager.loadModels(models)
            } catch {
                await manager.cleanup()
                throw error
            }
            guard isCurrent(token) else {
                await manager.cleanup()
                return
            }

            asrManager = manager
            loadedModelVariant = token.variant
            asrManagerReady = true
            modelDownloadState = .ready
            AppLogger.transcription.info("PARAKEET | TDT \(token.variant.rawValue) models loaded (source: \(loadSourceName))")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "models_loaded",
                message: "Parakeet ASR models initialized successfully",
                context: ["load_source": loadSourceName])

        } catch {
            guard isCurrent(token) else { return }
            finishModelDownloadAttempt(generation: modelDownloadAttemptGeneration)
            modelFilePrefetchTask = nil
            prefetchedModelPath = nil
            let friendlyMessage = ModelDownloadService.classifyError(error).detail
            modelDownloadState = .failed(friendlyMessage)
            AppLogger.transcription.error("PARAKEET | model initialization failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "model_init_failed",
                message: error.localizedDescription,
                context: ParakeetModelInitDiagnostics.failureContext(
                    stage: failureStage,
                    loadSource: loadSource,
                    bundledModelPresent: bundledModelPresent,
                    microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio)
                ))
        }
    }

    func prefetchModelFilesIfNeeded(variant: ParakeetModelVariant = .v3) async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        // Prefetch is disposable and must not change a runtime in use.
        guard ParakeetModelSelectionPolicy.canPrefetch(
            hasManager: asrManager != nil,
            hasActiveWork: isRecording || isTranscribing || hasActiveASRWork
        ) else { return }
        guard selectModelVariant(variant) else { return }

        guard bundledParakeetModelPath(variant: variant) == nil else {
            return
        }

        if markCachedRuntimeModelIfAvailable() {
            return
        }

        switch modelDownloadState {
        case .downloading, .cached, .loading, .ready:
            return
        case .notLoaded, .failed:
            break
        }

        let task: Task<URL, Error>
        if let modelFilePrefetchTask {
            task = modelFilePrefetchTask
        } else {
            task = startModelDownloadTask()
        }
        let generation = modelDownloadAttemptGeneration
        let token = ParakeetModelWorkToken(variant: variant, generation: generation)

        do {
            let downloadedPath = try await task.value
            guard token.isCurrent(variant: modelVariant, generation: modelDownloadAttemptGeneration) else { return }
            guard finishModelDownloadAttempt(generation: generation) else { return }
            guard !Task.isCancelled, !isShuttingDown else { return }
            guard modelInitializationTask == nil, asrManager == nil, !asrManagerReady else {
                if modelFilePrefetchTask != nil {
                    modelFilePrefetchTask = nil
                }
                return
            }
            prefetchedModelPath = downloadedPath
            modelDownloadState = .cached
            if modelFilePrefetchTask != nil {
                modelFilePrefetchTask = nil
            }
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "model_files_prefetched",
                message: "Parakeet model files are cached for first use",
                context: ["load_source": ParakeetModelLoadSource.download.rawValue]
            )
        } catch {
            guard token.isCurrent(variant: modelVariant, generation: modelDownloadAttemptGeneration) else { return }
            guard !Task.isCancelled, !isShuttingDown else { return }
            guard finishModelDownloadAttempt(generation: generation) else { return }
            if modelFilePrefetchTask != nil {
                modelFilePrefetchTask = nil
            }
            if case .failed(let message) = modelDownloadState,
               message == Self.stalledDownloadMessage {
                return
            }
            let friendlyMessage = ModelDownloadService.classifyError(error).detail
            modelDownloadState = .failed(friendlyMessage)
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "model_file_prefetch_failed",
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    func markCachedRuntimeModelIfAvailable() -> Bool {
        guard let cachedModelPath = ModelCacheInventory.activeParakeetModelDirectory(variant: modelVariant) else {
            return false
        }

        prefetchedModelPath = cachedModelPath
        if !asrManagerReady {
            modelDownloadState = .cached
        }
        return true
    }

    /// Reuse the pinned 0.7.9 caches under FluidAudio 0.15.x's canonical names.
    /// v2 already used the current model files; v3 may need its new joint model.
    /// Missing files are filled in by FluidAudio after a successful rename.
    private static func migrateLegacyParakeetCacheIfNeeded(variant: ParakeetModelVariant) {
        let newDir = AsrModels.defaultCacheDirectory(for: variant.fluidAudioVersion)
        guard !newDir.lastPathComponent.hasSuffix("-coreml") else { return }
        do {
            guard try ModelCacheInventory.migrateLegacyParakeetModelDirectory(
                variant: variant,
                fluidAudioModelsDirectory: newDir.deletingLastPathComponent()
            ) else { return }
            AppLogger.transcription.info("PARAKEET | migrated legacy model cache to \(newDir.lastPathComponent)")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "model_cache_migrated",
                message: "Renamed pre-0.15 FluidAudio model cache folder")
        } catch {
            AppLogger.transcription.warning("PARAKEET | legacy model cache migration failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "model_cache_migration_failed",
                message: error.localizedDescription)
        }
    }

    func bundledParakeetModelPath(variant: ParakeetModelVariant = .v3) -> URL? {
        ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
            resourcePath: Bundle.main.resourcePath,
            variant: variant
        )
    }

    // MARK: - Model teardown

    /// Cancel in-flight model init/prefetch work. Called from `cleanup()`.
    func cancelModelWork() {
        modelDownloadAttemptGeneration &+= 1
        modelDownloadWatchdogTask?.cancel()
        modelDownloadWatchdogTask = nil
        modelInitializationGeneration &+= 1
        let previousInitialization = modelInitializationTask
        previousInitialization?.cancel()
        modelInitializationTask = nil
        // Cancellation does not stop a native CoreML load immediately. Keep
        // its lifetime in the drain chain so the successor cannot allocate a
        // second model until the stale load (and manager cleanup) has ended.
        if let previousInitialization {
            modelCleanupTask = ParakeetModelTaskDrain.draining(
                previousInitialization, after: modelCleanupTask
            )
        }
        modelFilePrefetchTask?.cancel()
        modelFilePrefetchTask = nil
    }

    /// Tear down the loaded ASR model state. Deferred (instead of an
    /// immediate `asrManager = nil`) while transcription work is still
    /// in-flight, so an active `AsrManager.transcribe()` call doesn't get its
    /// backing object released out from under it. Called from `cleanup()`.
    func teardownModel() {
        asrManagerReady = false
        loadedModelVariant = nil
        modelDownloadState = .notLoaded
        modelTeardownGate.begin()
        finishDeferredModelTeardownIfIdle()
    }

    func finishDeferredModelTeardownIfIdle() {
        guard modelTeardownGate.isPending,
              ParakeetASRManagerCleanupPolicy.decision(
                isTranscribing: isTranscribing || hasActiveASRWork
              ) == .cleanupNow else { return }
        let manager = asrManager
        asrManager = nil
        let previousCleanup = modelCleanupTask
        modelCleanupTask = Task {
            await previousCleanup?.value
            await manager?.cleanup()
        }
        // Publish the drain task before waking initialization waiters so they
        // always await native cleanup before allocating a replacement manager.
        modelTeardownGate.finish()
    }
}
