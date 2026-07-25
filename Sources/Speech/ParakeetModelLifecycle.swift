// ParakeetModelLifecycle.swift
// Model load/download/warmup/teardown paths for ParakeetEngine, split out of
// ParakeetEngine.swift (codebase audit 2026-07-08 wave 2, spec W2-C).
//
// These are internal collaborator methods on ParakeetEngine — ParakeetEngine
// remains the public-API owner and MainActor home for this state; this file
// just groups the model-lifecycle slice of its implementation.

@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import TranscriptedCore

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

    private func startModelDownloadTask() -> Task<URL, Error> {
        let progressTracker = ParakeetModelDownloadProgressTracker()
        let generation = beginModelDownloadAttempt(progressTracker: progressTracker)
        let progressTarget = ParakeetModelDownloadProgressTarget(engine: self)
        let task = Task.detached(priority: .utility) {
            try await AsrModels.download(version: .v3) { progress in
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
                        generation: generation
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

    private func recordModelDownloadProgress(_ progress: Double, generation: UInt64) {
        guard ParakeetModelDownloadAttemptPolicy.isCurrent(
            expectedGeneration: generation,
            currentGeneration: modelDownloadAttemptGeneration
        ), modelFilePrefetchTask != nil else { return }
        modelDownloadState = .downloading(progress: max(0, min(1, progress)))
    }

    private func scheduleModelDownloadWatchdog(
        generation: UInt64,
        progressTracker: ParakeetModelDownloadProgressTracker
    ) {
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
            guard ParakeetModelDownloadAttemptPolicy.shouldTimeOut(
                expectedGeneration: generation,
                currentGeneration: self.modelDownloadAttemptGeneration,
                hasActiveTask: self.modelFilePrefetchTask != nil,
                taskCancelled: Task.isCancelled
            ) else {
                return
            }

            self.modelDownloadAttemptGeneration &+= 1
            self.modelFilePrefetchTask?.cancel()
            self.modelFilePrefetchTask = nil
            self.modelInitializationGeneration &+= 1
            self.modelInitializationTask?.cancel()
            self.modelInitializationTask = nil
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
    /// Bundle path: Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/
    func initialize() async {
        guard !isShuttingDown, !Task.isCancelled else { return }

        if let modelInitializationTask {
            await modelInitializationTask.value
            return
        }

        modelInitializationGeneration &+= 1
        let generation = modelInitializationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialize(generation: generation)
        }
        modelInitializationTask = task
        await task.value
    }

    /// Await the in-flight model initialization task, if any. Returns true
    /// when a task was joined. Unlike polling `modelDownloadState`, this
    /// resumes the moment initialization settles (ready or failed).
    func joinModelInitialization() async -> Bool {
        guard let modelInitializationTask else { return false }
        await modelInitializationTask.value
        return true
    }

    private func performInitialize(generation: UInt64) async {
        defer {
            if generation == modelInitializationGeneration {
                modelInitializationTask = nil
            }
        }
        guard !isShuttingDown, !Task.isCancelled else { return }
        scheduleInputDeviceNameRefresh()
        markCachedRuntimeModelIfAvailable()

        guard asrManager == nil else {
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
        Self.migrateLegacyParakeetCacheIfNeeded()
        // FluidAudio 0.15.x resolves bundled models as <parent>/<repo folderName>, and the
        // folder name lost its -coreml suffix. Gate on JointDecisionv3.mlmodelc (new required
        // file) so an incomplete bundle can't trigger a download into the signed app bundle.
        let bundledModelPath = bundledModelPath(subdirectory: "parakeet-tdt-0.6b-v3", checkFile: "JointDecisionv3.mlmodelc")
        let bundledModelPresent = bundledModelPath != nil

        do {
            let models: AsrModels
            let loadSourceName: String

            // Try loading from app bundle first (bundled by build.sh)
            if let bundlePath = bundledModelPath {
                failureStage = .bundleLoad
                loadSource = .bundle
                AppLogger.transcription.info("PARAKEET | loading from bundle: \(bundlePath.path)")
                models = try await AsrModels.load(from: bundlePath, version: .v3)
                guard !Task.isCancelled, !isShuttingDown else { return }
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
                    guard finishModelDownloadAttempt(generation: generation) else { return }
                    prefetchedModelPath = downloadedPath
                    self.modelFilePrefetchTask = nil
                } else if let prefetchedModelPath {
                    downloadedPath = prefetchedModelPath
                } else if let cachedModelPath = ModelCacheInventory.activeParakeetModelDirectory() {
                    prefetchedModelPath = cachedModelPath
                    downloadedPath = cachedModelPath
                } else {
                    AppLogger.transcription.info("PARAKEET | models not bundled, downloading (~600MB)...")
                    let task = startModelDownloadTask()
                    let generation = modelDownloadAttemptGeneration
                    downloadedPath = try await task.value
                    guard finishModelDownloadAttempt(generation: generation) else { return }
                    modelFilePrefetchTask = nil
                    prefetchedModelPath = downloadedPath
                }
                guard !Task.isCancelled, !isShuttingDown else { return }
                modelDownloadState = .loading
                AppLogger.transcription.info("PARAKEET | loading downloaded models from: \(downloadedPath.path)")
                models = try await AsrModels.load(from: downloadedPath, version: .v3)
                guard !Task.isCancelled, !isShuttingDown else { return }
                loadSourceName = loadSource.rawValue
            }

            failureStage = .managerInitialize
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            guard !Task.isCancelled, !isShuttingDown else {
                Task { await manager.cleanup() }
                return
            }

            asrManager = manager
            asrManagerReady = true
            modelDownloadState = .ready
            AppLogger.transcription.info("PARAKEET | TDT V3 models loaded (source: \(loadSourceName))")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "models_loaded",
                message: "Parakeet ASR models initialized successfully",
                context: ["load_source": loadSourceName])

        } catch {
            guard !Task.isCancelled, !isShuttingDown else { return }
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

    func prefetchModelFilesIfNeeded() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        guard asrManager == nil else { return }

        guard bundledModelPath(
            subdirectory: "parakeet-tdt-0.6b-v3-coreml",
            checkFile: "Encoder.mlmodelc"
        ) == nil else {
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

        do {
            let downloadedPath = try await task.value
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
        guard let cachedModelPath = ModelCacheInventory.activeParakeetModelDirectory() else {
            return false
        }

        prefetchedModelPath = cachedModelPath
        if !asrManagerReady {
            modelDownloadState = .cached
        }
        return true
    }

    /// FluidAudio 0.15.x renamed the v3 cache folder from `parakeet-tdt-0.6b-v3-coreml`
    /// to `parakeet-tdt-0.6b-v3` (ModelNames.folderName strips the suffix). Rename a
    /// 0.7.9-era cache in place so existing users keep their ~600MB download; FluidAudio
    /// then only fetches the one file new in 0.15.x (JointDecisionv3.mlmodelc). A failed
    /// rename is harmless — the loader falls back to a fresh download.
    private static func migrateLegacyParakeetCacheIfNeeded() {
        let newDir = AsrModels.defaultCacheDirectory(for: .v3)
        guard !newDir.lastPathComponent.hasSuffix("-coreml") else { return }
        let legacyDir = newDir.deletingLastPathComponent()
            .appendingPathComponent(newDir.lastPathComponent + "-coreml", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyDir.path),
              !fileManager.fileExists(atPath: newDir.path) else { return }
        do {
            try fileManager.moveItem(at: legacyDir, to: newDir)
            AppLogger.transcription.info("PARAKEET | migrated legacy model cache to \(newDir.lastPathComponent)")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "model_cache_migrated",
                message: "Renamed pre-0.15 FluidAudio model cache folder")
        } catch {
            AppLogger.transcription.warning("PARAKEET | legacy model cache migration failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "model_cache_migration_failed",
                message: error.localizedDescription)
        }
    }

    /// Check for a Parakeet model bundled in the app at build time.
    /// Expected layout: Contents/Resources/parakeet-models/{subdirectory}/{checkFile}
    func bundledModelPath(subdirectory: String, checkFile: String) -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("parakeet-models")
            .appendingPathComponent(subdirectory)
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent(checkFile).path) else { return nil }
        return path
    }

    // MARK: - Model teardown

    /// Cancel in-flight model init/prefetch work. Called from `cleanup()`.
    func cancelModelWork() {
        modelDownloadAttemptGeneration &+= 1
        modelDownloadWatchdogTask?.cancel()
        modelDownloadWatchdogTask = nil
        modelInitializationGeneration &+= 1
        modelInitializationTask?.cancel()
        modelInitializationTask = nil
        modelFilePrefetchTask?.cancel()
        modelFilePrefetchTask = nil
    }

    /// Tear down the loaded ASR model state. Deferred (instead of an
    /// immediate `asrManager = nil`) while transcription work is still
    /// in-flight, so an active `AsrManager.transcribe()` call doesn't get its
    /// backing object released out from under it. Called from `cleanup()`.
    func teardownModel() {
        let cleanupDecision = ParakeetASRManagerCleanupPolicy.decision(
            isTranscribing: isTranscribing || hasActiveASRWork
        )
        let mgr = asrManager
        if cleanupDecision == .cleanupNow {
            asrManager = nil
        }
        asrManagerReady = false
        modelDownloadState = .notLoaded
        if cleanupDecision == .cleanupNow {
            Task { await mgr?.cleanup() }
        } else {
            AppLogger.transcription.info("PARAKEET | deferring ASR manager cleanup while transcription is active")
        }
    }
}
