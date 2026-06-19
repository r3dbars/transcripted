// ParakeetEngine.swift
// FluidAudio-based STT engine — CoreML Parakeet TDT V3 for batch transcription.
// AVAudioEngine tap → NSLock-batched samples → resampled to 16kHz → AsrManager.transcribe()
// for final batch inference.

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreAudio
import FluidAudio
import Foundation
import TranscriptedCore

@MainActor
class ParakeetEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var liveTranscript: String = ""
    @Published var modelDownloadState: ParakeetModelState = .notLoaded
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true

    private var audioEngine = AVAudioEngine()
    private var audioEngineQueue = ParakeetEngine.makeAudioEngineQueue()
    private var audioGraphGeneration = 0
    private var audioStartInProgress = false
    private var inputTapInstalled = false
    private var sampleBuffer: [Float] = []
    private var recoveredRecordingTimeline = RecordedAudioTimeline()
    private var preservingRecordingAcrossRecovery = false
    private nonisolated(unsafe) var nativeSampleRate: Double = 48000
    private nonisolated(unsafe) var audioStartReferenceTime: CFAbsoluteTime?
    private let pendingSamplesLock = NSLock()
    private var pendingSamples: [Float] = []
    private nonisolated(unsafe) var lastLevelUpdate: CFAbsoluteTime = 0
    private var isEnginePrewarmed = false
    private var wakeObserver: NSObjectProtocol?
    private var inputDeviceChangeListener: AudioObjectPropertyListenerBlock?

    // Live streaming text is intentionally disabled — the product focuses on
    // stable capture and final transcription rather than provisional text.
    private let liveDisplayEnabled = false
    private nonisolated(unsafe) var eouManager: StreamingEouAsrManager?
    private var committedStreamText: String = ""
    // Protected by streamingSamplesLock — accessed from both the audio render thread and MainActor.
    private let streamingSamplesLock = NSLock()
    private var streamingSampleBuffer: [Float] = []
    // Feed EOU in ~320ms chunks (shift size). The manager buffers internally and processes
    // when it has a full chunk (10240 samples = 64 mel frames at hop=160).
    private let eouChunkSamples: Int = 5120
    // Cached format for makePCMBuffer — always 16kHz mono, no need to recreate per chunk
    private let eouPCMFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
    private var configChangeObserver: NSObjectProtocol?
    private var configChangeDebounceTask: Task<Void, Never>?
    private var configRecoveryTask: Task<Void, Never>?
    private var configRecoveryTimeoutTask: Task<Void, Never>?
    /// Tracks whether a recording was active when the first config change in a
    /// burst arrived. Subsequent changes during recovery inherit this flag so
    /// the final recovery attempt knows to restart recording.
    private var configChangeWasRecording = false
    /// Pure-logic state machine for device-change recovery. Owns the generation
    /// counter and the readiness flags. Mirrored into @Published so the UI can
    /// observe via Combine.
    private var recoveryState = ParakeetRecoveryState()
    /// Counts consecutive failed prewarm attempts. Reset on successful prewarm or
    /// on a fresh config-change burst. Bounded by `prewarmRetryBudget` to prevent
    /// infinite Task chains when the mic is permanently unavailable.
    private var prewarmRetryCount: Int = 0
    private var prewarmRetryTask: Task<Void, Never>?
    private var isShuttingDown = false

    // FluidAudio ASR
    private var asrManager: AsrManager?
    private var modelInitializationTask: Task<Void, Never>?
    private var modelFilePrefetchTask: Task<URL, Error>?
    private var prefetchedModelPath: URL?
    private var audioWatchdogTask: Task<Void, Never>?
    private var zombieRecoveryRestartPending = false
    private var asrInferenceActivity = ParakeetASRInferenceActivityState()
    private var asrInferenceHandoffCount = 0
    private var asrInferenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var pureSampleTranscriptionActivityCount = 0
    private var asrManagerReady = false
    private nonisolated(unsafe) var didReceiveAudioSamples = false
    private var cachedInputDeviceName = "Unknown"
    private var lastAudioStartFailureReportAt: TimeInterval?
    private var lastInputSelectionReportKey: String?
    private var ignoreInputSelectionConfigChangesUntil: CFAbsoluteTime = 0

    var isModelLoaded: Bool { asrManagerReady }
    var inputDeviceName: String { cachedInputDeviceName }

    var currentAudioRouteAnalyticsContext: [String: String] {
        dictationRouteAnalyticsContext(selection: Self.loadDictationInputDeviceSelection())
    }

    init() {
        markCachedRuntimeModelIfAvailable()
        scheduleInputDeviceNameRefresh()
    }

    private static func makeAudioEngineQueue() -> DispatchQueue {
        DispatchQueue(label: "com.transcripted.parakeet.audio-engine", qos: .userInitiated)
    }

    nonisolated private static func loadDictationInputDeviceSelection(
        allowsBuiltInBluetoothFallback: Bool = true
    ) -> DictationInputDeviceSelection? {
        do {
            return try CoreAudioInputDeviceLookup.preferredDictationInputSelection(
                allowsBuiltInBluetoothFallback: allowsBuiltInBluetoothFallback
            )
        } catch {
            return nil
        }
    }

    nonisolated private static var unknownInputDeviceSelection: DictationInputDeviceSelection {
        let unknownDevice = DictationAudioDevice(
            id: AudioDeviceID(kAudioObjectUnknown),
            name: "Unknown",
            transport: .other,
            inputChannelCount: 0
        )
        return DictationInputDeviceSelection(
            defaultInput: unknownDevice,
            selectedInput: unknownDevice,
            defaultOutput: nil,
            reason: .defaultIsSafe
        )
    }

    private func scheduleInputDeviceNameRefresh() {
        Task.detached(priority: .utility) { [weak self] in
            if let selection = Self.loadDictationInputDeviceSelection() {
                await self?.updateCachedInputDeviceSelection(selection)
            } else {
                await self?.updateCachedInputDeviceName("Unknown")
            }
        }
    }

    private func runAudioEngineWork<T>(_ work: @escaping (AVAudioEngine) throws -> T) async throws -> T {
        let queue = audioEngineQueue
        let engine = audioEngine
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work(engine))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runTimedAudioEngineWork<T>(
        operation: String,
        timeoutNanoseconds: UInt64 = TranscriptedConstants.audioStartOperationTimeout,
        cleanupAfterLateCompletion: ((AVAudioEngine) -> Void)? = nil,
        _ work: @escaping (AVAudioEngine) throws -> T
    ) async throws -> T {
        let queue = audioEngineQueue
        let engine = audioEngine
        let timeoutMs = Int(timeoutNanoseconds / 1_000_000)
        let resumeLock = NSLock()
        var didResume = false

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            func resumeOnce(_ result: Result<T, Error>) {
                var shouldResume = false
                resumeLock.withLock {
                    if !didResume {
                        didResume = true
                        shouldResume = true
                    }
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            queue.async {
                let shouldRun = resumeLock.withLock { !didResume }
                guard shouldRun else { return }

                let result: Result<T, Error>
                do {
                    result = .success(try work(engine))
                } catch {
                    result = .failure(error)
                }

                var completedBeforeTimeout = false
                resumeLock.withLock {
                    if !didResume {
                        didResume = true
                        completedBeforeTimeout = true
                    }
                }

                if completedBeforeTimeout {
                    continuation.resume(with: result)
                } else {
                    cleanupAfterLateCompletion?(engine)
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))
            ) {
                resumeOnce(
                    .failure(
                        ParakeetAudioEngineWorkError.timedOut(
                            operation: operation,
                            timeoutMs: timeoutMs
                        )
                    )
                )
            }
        }
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        max(0, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
    }

    private static func timingContext(_ timings: [String: Int]) -> [String: String] {
        timings.reduce(into: [:]) { context, entry in
            context[entry.key] = "\(entry.value)"
        }
    }

    /// Remove the input tap without tripping AVAudioEngine's
    /// `required condition is false: isSink || tap != nullptr` assertion.
    ///
    /// Removing a tap while the engine is still running leaves the input node
    /// with neither a tap nor a downstream sink; the next IO-thread
    /// `InputAvailable` callback then crashes the process. Stop the engine and
    /// let in-flight input callbacks drain BEFORE removing the tap, mirroring
    /// the meeting/mic path's `Audio.tearDownInputTapSafely` via the shared
    /// `AudioInputTapTeardownPolicy`.
    ///
    /// Must be called on `audioEngineQueue` (callers already hop there); the
    /// drain step briefly blocks that queue, never the CoreAudio render thread.
    private nonisolated static func safelyRemoveInputTap(on audioEngine: AVAudioEngine) {
        for step in AudioInputTapTeardownPolicy.steps(engineIsRunning: audioEngine.isRunning) {
            switch step {
            case .stopEngine:
                audioEngine.stop()
            case .waitForStoppedInputCallbacks:
                Thread.sleep(forTimeInterval: AudioInputTapTeardownPolicy.inputCallbackDrainDelay)
            case .removeInputTap:
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
    }

    private static func cleanUpLateAudioStart(on audioEngine: AVAudioEngine) {
        safelyRemoveInputTap(on: audioEngine)
        audioEngine.reset()
    }

    private func runAudioEngineWork<T>(_ work: @escaping (AVAudioEngine) -> T) async -> T {
        let queue = audioEngineQueue
        let engine = audioEngine
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work(engine))
            }
        }
    }

    private func updateCachedInputDeviceName(_ deviceName: String) {
        cachedInputDeviceName = deviceName
    }

    private func updateCachedInputDeviceSelection(_ selection: DictationInputDeviceSelection) {
        cachedInputDeviceName = selection.selectedInput.name
    }

    private func handleDefaultInputDeviceChange(selection: DictationInputDeviceSelection) {
        cachedInputDeviceName = selection.selectedInput.name
        print("🎤 PARAKEET | default input changed → \(selection.defaultInput.name); dictation input → \(selection.selectedInput.name)")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "default_input_device_changed",
            message: "Default input device changed",
            context: inputSelectionContext(selection)
        )
        Task { @MainActor [weak self] in
            await self?.handleAudioConfigChange()
        }
    }

    // MARK: - Model Initialization

    /// Load Parakeet models from the app bundle (preferred) or download from HuggingFace (fallback).
    /// Bundle path: Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/
    func initialize() async {
        guard !isShuttingDown, !Task.isCancelled else { return }

        if let modelInitializationTask {
            await modelInitializationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialize()
        }
        modelInitializationTask = task
        await task.value
    }

    private func performInitialize() async {
        defer { modelInitializationTask = nil }
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
        print("🔄 PARAKEET | initializing models...")

        var failureStage: ParakeetModelInitStage = .authorizationRequest
        var loadSource: ParakeetModelLoadSource = .unresolved
        let bundledModelPath = bundledModelPath(subdirectory: "parakeet-tdt-0.6b-v3-coreml", checkFile: "Encoder.mlmodelc")
        let bundledModelPresent = bundledModelPath != nil

        do {
            let models: AsrModels
            let loadSourceName: String

            // Try loading from app bundle first (bundled by build.sh)
            if let bundlePath = bundledModelPath {
                failureStage = .bundleLoad
                loadSource = .bundle
                print("📦 PARAKEET | loading from bundle: \(bundlePath.path)")
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
                    print("🌐 PARAKEET | waiting for background Parakeet model cache...")
                    modelDownloadState = .downloading(progress: 0.0)
                    downloadedPath = try await modelFilePrefetchTask.value
                    prefetchedModelPath = downloadedPath
                    self.modelFilePrefetchTask = nil
                } else if let prefetchedModelPath {
                    downloadedPath = prefetchedModelPath
                } else if let cachedModelPath = ModelCacheInventory.activeParakeetModelDirectory() {
                    prefetchedModelPath = cachedModelPath
                    downloadedPath = cachedModelPath
                } else {
                    print("🌐 PARAKEET | models not bundled, downloading (~600MB)...")
                    modelDownloadState = .downloading(progress: 0.0)
                    downloadedPath = try await AsrModels.download(version: .v3)
                    prefetchedModelPath = downloadedPath
                }
                guard !Task.isCancelled, !isShuttingDown else { return }
                modelDownloadState = .loading
                print("🌐 PARAKEET | loading downloaded models from: \(downloadedPath.path)")
                models = try await AsrModels.load(from: downloadedPath, version: .v3)
                guard !Task.isCancelled, !isShuttingDown else { return }
                loadSourceName = loadSource.rawValue
            }

            failureStage = .managerInitialize
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            guard !Task.isCancelled, !isShuttingDown else {
                Task { manager.cleanup() }
                return
            }

            asrManager = manager
            asrManagerReady = true
            modelDownloadState = .ready
            print("✅ PARAKEET | TDT V3 models loaded (source: \(loadSourceName))")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "models_loaded",
                message: "Parakeet ASR models initialized successfully",
                context: ["load_source": loadSourceName])

            if liveDisplayEnabled {
                await initializeEouModel()
            }

        } catch {
            guard !Task.isCancelled, !isShuttingDown else { return }
            modelFilePrefetchTask = nil
            prefetchedModelPath = nil
            let friendlyMessage = ModelDownloadService.classifyError(error).detail
            modelDownloadState = .failed(friendlyMessage)
            print("❌ PARAKEET | model initialization failed: \(error.localizedDescription)")
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
            modelDownloadState = .downloading(progress: 0.0)
            task = Task.detached(priority: .utility) {
                try await AsrModels.download(version: .v3)
            }
            modelFilePrefetchTask = task
        }

        do {
            let downloadedPath = try await task.value
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
            if modelFilePrefetchTask != nil {
                modelFilePrefetchTask = nil
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
    private func markCachedRuntimeModelIfAvailable() -> Bool {
        guard let cachedModelPath = ModelCacheInventory.activeParakeetModelDirectory() else {
            return false
        }

        prefetchedModelPath = cachedModelPath
        if !asrManagerReady {
            modelDownloadState = .cached
        }
        return true
    }

    /// Load Parakeet EOU 120M for streaming live display.
    /// Non-fatal — if EOU fails, live transcript stays empty but batch result still works.
    private func initializeEouModel() async {
        do {
            let eou = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)

            let modelDir: URL
            if let bundlePath = bundledModelPath(subdirectory: "parakeet-eou-120m-coreml", checkFile: "streaming_encoder.mlmodelc") {
                print("📦 PARAKEET EOU | loading from bundle: \(bundlePath.path)")
                modelDir = bundlePath
            } else {
                // Download from HuggingFace (~120MB) and cache locally
                // DownloadUtils nests inside <directory>/<repo.folderName>/, so we use the parent
                guard let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                    print("⚠️ PARAKEET EOU | application support directory unavailable")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "eou_app_support_unavailable",
                        message: "Application support directory lookup returned no results; cannot resolve EOU model cache"
                    )
                    return
                }
                let cacheBase = appSupportRoot.appendingPathComponent("FluidAudio/Models", isDirectory: true)
                let expectedDir = cacheBase.appendingPathComponent("parakeet-eou-streaming/320ms", isDirectory: true)
                let checkFile = expectedDir.appendingPathComponent("streaming_encoder.mlmodelc")
                if FileManager.default.fileExists(atPath: checkFile.path) {
                    print("📦 PARAKEET EOU | loading from cache: \(expectedDir.path)")
                    modelDir = expectedDir
                } else {
                    print("⚠️ PARAKEET EOU | streaming model download unavailable with current FluidAudio API")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "eou_model_unavailable",
                        message: "Streaming EOU model download is unavailable with the current FluidAudio version"
                    )
                    return
                }
            }
            try await eou.loadModels(modelDir: modelDir)

            // Partial callback fires on every chunk with new tokens — live "ghost text" display
            await eou.setPartialCallback { [weak self] partial in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let trimmed = partial.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    self.liveTranscript = self.committedStreamText.isEmpty
                        ? trimmed
                        : self.committedStreamText + " " + trimmed
                }
            }

            // EOU callback fires after silence — commits the utterance so partial text resets
            await eou.setEouCallback { [weak self] transcript in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let trimmed = transcript.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    self.committedStreamText = self.committedStreamText.isEmpty
                        ? trimmed
                        : self.committedStreamText + " " + trimmed
                    self.liveTranscript = self.committedStreamText
                }
            }

            eouManager = eou
            print("✅ PARAKEET EOU | streaming model ready")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "eou_model_loaded",
                message: "Parakeet EOU streaming model initialized")
        } catch {
            // Non-fatal — live display will just stay empty until batch result arrives
            print("⚠️ PARAKEET EOU | model load failed (live display disabled): \(error.localizedDescription)")
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "eou_model_failed",
                message: error.localizedDescription)
        }
    }

    /// Check for a Parakeet model bundled in the app at build time.
    /// Expected layout: Contents/Resources/parakeet-models/{subdirectory}/{checkFile}
    private func bundledModelPath(subdirectory: String, checkFile: String) -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("parakeet-models")
            .appendingPathComponent(subdirectory)
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent(checkFile).path) else { return nil }
        return path
    }

    // MARK: - Input readiness

    func prewarm() async {
        guard !isShuttingDown else { return }
        guard !isRecording else { return }
        guard !audioStartInProgress else { return }
        installAudioObserversIfNeeded()
        scheduleInputDeviceNameRefresh()

        await releaseIdleAudioHardware(removeTap: false)
        let prewarmGeneration = audioGraphGeneration
        guard canContinuePrewarm(generation: prewarmGeneration) else { return }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch ParakeetPrewarmPolicy.decision(for: microphoneStatus) {
        case .proceed:
            break
        case .skip(let level, let event, let message, let context):
            let eventLevel: EventLevel
            switch level {
            case .info:
                eventLevel = .info
            case .warning:
                eventLevel = .warning
            }
            EventReporter.shared.capture(
                level: eventLevel,
                engine: "parakeet",
                event: event,
                message: message,
                context: context
            )
            return
        }

        let snapshot: ParakeetAudioInputSnapshot
        do {
            snapshot = try await audioInputSnapshot(operation: "prewarm")
        } catch {
            guard canContinuePrewarm(generation: prewarmGeneration) else { return }
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "prewarm_failed",
                message: error.localizedDescription
            )
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }
        guard canContinuePrewarm(generation: prewarmGeneration) else { return }

        // Validate both formats. AirPods on macOS run input in Hands-Free Profile
        // (24kHz hw / 48kHz output bus); CoreAudio's internal converter handles
        // the upsample and the tap delivers at the output bus rate. Both must be
        // valid before declaring the engine ready — input alone or output alone
        // can transiently report zero during device transitions.
        let readiness = audioFormatReadiness(
            outputFormat: snapshot.outputFormat,
            hwFormat: snapshot.hwFormat,
            selection: snapshot.selection
        )
        guard readiness == .ready else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "prewarm_invalid_format",
                message: "Audio format invalid during prewarm",
                context: audioFormatContext(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection,
                    readiness: readiness
                ))
            if readiness == .routeNotSettled {
                let rebuildGeneration = audioGraphGeneration + 1
                await rebuildAudioEngine(reason: "audio_route_not_settled")
                guard canContinuePrewarm(generation: rebuildGeneration) else { return }
            }
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }

        updateNativeSampleRate(snapshot.outputFormat.sampleRate)

        prewarmRetryCount = 0
        markFormatReadyAndPublish()
        print("🔥 PARAKEET | input ready (\(inputDeviceName), \(safeNativeSampleRate())Hz)")
    }

    private func canContinuePrewarm(generation: Int) -> Bool {
        !isShuttingDown
            && !isRecording
            && !audioStartInProgress
            && audioGraphGeneration == generation
    }

    private func schedulePrewarmRetry() {
        guard !isShuttingDown else { return }
        // Bounded retry — give CoreAudio time to settle, but don't loop forever.
        // Each call counts toward the budget; budget resets on a successful prewarm
        // or on an explicit device change (which restarts the cycle anyway).
        guard prewarmRetryCount < TranscriptedConstants.prewarmRetryBudget else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet",
                event: "prewarm_retry_budget_exhausted",
                message: "Prewarm retry budget exhausted — engine will retry on next device change or user action",
                context: ["audio_device": inputDeviceName])
            prewarmRetryCount = 0
            return
        }
        prewarmRetryCount += 1
        let capturedGeneration = recoveryState.generation
        prewarmRetryTask?.cancel()
        prewarmRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled,
                  let self,
                  !self.isShuttingDown,
                  !self.recoveryState.isStale(generation: capturedGeneration) else { return }
            await self.prewarm()
        }
    }

    func forceInputReadinessRecovery(reason: String) async {
        guard !isShuttingDown else { return }
        guard !isRecording, !audioStartInProgress else { return }

        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        prewarmRetryCount = 0

        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "input_readiness_recovery_forced",
            message: "Forced idle audio graph recovery while waiting for dictation input readiness",
            context: [
                "reason": reason,
                "recovering": "\(recoveryState.isRecovering)",
                "format_ready": "\(recoveryState.inputFormatReady)",
                "generation": "\(recoveryState.generation)",
            ]
        )

        abandonBlockedAudioEngine(reason: reason)
        markFormatUnreadyAndPublish()
        try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
        await prewarm()
    }

    private func installAudioObserversIfNeeded() {
        installAudioEngineConfigObserverIfNeeded()

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleSystemWake()
                }
            }
        }

        installInputDeviceChangeListenerIfNeeded()
    }

    private func installAudioEngineConfigObserverIfNeeded() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAudioConfigChange()
            }
        }
    }

    private func removeAudioEngineConfigObserver() {
        guard let observer = configChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
    }

    private func installInputDeviceChangeListenerIfNeeded() {
        guard inputDeviceChangeListener == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task.detached(priority: .utility) { [weak self] in
                let selection = Self.loadDictationInputDeviceSelection() ?? Self.unknownInputDeviceSelection
                await self?.handleDefaultInputDeviceChange(selection: selection)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )

        guard status == noErr else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "default_input_listener_failed",
                message: "Failed to register default input device listener",
                context: ["status": "\(status)"]
            )
            return
        }

        inputDeviceChangeListener = listener
    }

    private func removeInputDeviceChangeListener() {
        unregisterDefaultInputDeviceListener(inputDeviceChangeListener)
        inputDeviceChangeListener = nil
    }

    private func handleAudioConfigChange() async {
        if CFAbsoluteTimeGetCurrent() < ignoreInputSelectionConfigChangesUntil {
            return
        }
        audioGraphGeneration += 1

        // Track whether any config change in the current burst interrupted a
        // recording. Once set, subsequent changes in the same burst inherit it.
        if isRecording {
            configChangeWasRecording = true
        }

        // Bump the generation counter and signal UI that engine is recovering.
        // DictationSessionController waits on these flags instead of racing.
        cancelConfigRecoveryTimeout()
        let recoveryGeneration = recoveryState.beginConfigChange()
        publishRecoveryState()
        AnalyticsReporter.track(
            "dictation_audio_route_changed",
            properties: dictationRouteAnalyticsContext(
                selection: Self.loadDictationInputDeviceSelection(),
                extra: [
                    "was_recording": "\(configChangeWasRecording)"
                ]
            )
        )
        scheduleConfigRecoveryTimeout(
            generation: recoveryGeneration,
            wasRecording: configChangeWasRecording
        )
        // Fresh device state warrants a fresh retry budget for prewarm.
        prewarmRetryCount = 0

        // Immediately tear down anything that's running — the system has
        // already stopped the engine internally before posting this notification,
        // so the tap and prewarm state are stale.
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil

        if isRecording {
            preserveCurrentRecordingBuffersForRecovery()
            streamingSamplesLock.withLock { streamingSampleBuffer.removeAll(keepingCapacity: true) }
            Task { await eouManager?.reset() }
            await removeRecordingTap()
            isRecording = false
            audioLevel = 0
        }

        await stopAudioEngine()
        isEnginePrewarmed = false
        await rebuildAudioEngine(reason: "configuration_change")

        // Cancel any in-flight recovery — the latest device change wins.
        // Bluetooth disconnect/reconnect fires multiple notifications over
        // 500-1500ms; each cancels the previous recovery so only the final
        // stable device state gets a recovery attempt.
        configChangeDebounceTask?.cancel()
        configRecoveryTask?.cancel()

        configChangeDebounceTask = Task { @MainActor [weak self] in
            // 250ms debounce — long enough to coalesce rapid BT notifications,
            // short enough that dictation recovery feels responsive.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay)
            guard !Task.isCancelled, let self = self else { return }
            self.attemptDeviceRecovery()
        }
    }

    private func attemptDeviceRecovery() {
        let shouldRestartRecording = configChangeWasRecording
        configChangeWasRecording = false
        let myGeneration = recoveryState.generation
        let recoveryStartedAt = CFAbsoluteTimeGetCurrent()
        WorkflowRecoveryTelemetry.attempted(
            workflowKind: "dictation",
            failureKind: "route_changed",
            retrySource: "audio_route_recovery",
            surface: "runtime",
            artifactRetained: shouldRestartRecording
        )

        configRecoveryTask = Task { @MainActor [weak self] in
            // Wait for CoreAudio to finish settling the new device graph.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled, let self = self else { return }
            guard !self.recoveryState.isStale(generation: myGeneration) else { return }
            do {
                var recoveryAttempt = 0
                var readySnapshot: ParakeetAudioInputSnapshot?
                while readySnapshot == nil {
                    recoveryAttempt += 1
                    let snapshot = try await self.audioInputSnapshot(
                        operation: recoveryAttempt == 1 ? "device_recovery" : "device_recovery_retry",
                        recoveryGeneration: myGeneration
                    )
                    let readiness = self.audioFormatReadiness(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection
                    )
                    switch ParakeetDeviceRecoveryReadinessPolicy.action(for: readiness) {
                    case .finishRecovery:
                        readySnapshot = snapshot
                    case .keepWaiting:
                        var context = self.audioFormatContext(
                            outputFormat: snapshot.outputFormat,
                            hwFormat: snapshot.hwFormat,
                            selection: snapshot.selection,
                            readiness: readiness
                        )
                        context["recovery_attempt"] = "\(recoveryAttempt)"
                        EventReporter.shared.capture(
                            level: .warning,
                            engine: "parakeet",
                            event: "device_change_rewarm_deferred",
                            message: "Audio route still settling after device change",
                            context: context
                        )
                        try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        continue
                    }
                }
                guard let snapshot = readySnapshot else { return }
                self.updateNativeSampleRate(snapshot.outputFormat.sampleRate)
                self.prewarmRetryCount = 0
                print("🔄 PARAKEET | audio device changed → \(self.inputDeviceName) (\(self.safeNativeSampleRate())Hz), input ready")

                guard !Task.isCancelled else { return }
                guard self.recoveryState.finishRecovery(success: true, generation: myGeneration) else { return }
                self.cancelConfigRecoveryTimeout()
                self.publishRecoveryState()
                AnalyticsReporter.track(
                    "dictation_audio_route_recovery_finished",
                    properties: self.dictationRouteAnalyticsContext(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection,
                        extra: [
                            "outcome": "success",
                            "recovery_latency_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt),
                            "was_recording": "\(shouldRestartRecording)"
                        ]
                    )
                )
                // If we were recording, try to restart on the new device.
                // The watchdog (via isRecoveryAttempt=false) catches silent
                // failures where the device looks functional but produces no
                // samples. The watchdog gets one retry before giving up.
                if shouldRestartRecording {
                    var restarted = false
                    for attempt in 1...TranscriptedConstants.recordingRestartAttempts {
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        if await self.startRecording() {
                            restarted = true
                            print("✅ PARAKEET | recording recovered on new device (\(self.inputDeviceName)) after \(attempt) attempt(s)")
                            EventReporter.shared.capture(level: .info, engine: "parakeet",
                                event: "recording_recovered_device_change",
                                message: "Recording recovered after device change",
                                context: [
                                    "audio_device": self.inputDeviceName,
                                    "sample_rate": "\(self.safeNativeSampleRate())",
                                    "attempts": "\(attempt)"
                                ])
                            WorkflowRecoveryTelemetry.finished(
                                workflowKind: "dictation",
                                failureKind: "route_changed",
                                retrySource: "audio_route_recovery",
                                result: "success",
                                elapsedSeconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt,
                                surface: "runtime",
                                artifactRetained: true
                            )
                            break
                        }
                        // BT format negotiation can take ~1-2s; wait between attempts.
                        try? await Task.sleep(nanoseconds: TranscriptedConstants.recordingRestartRetryDelay)
                    }
                    if !restarted {
                        self.interruptRecordingAndClearRecoveredTimeline()
                        EventReporter.shared.capture(level: .error, engine: "parakeet",
                            event: "recording_interrupted",
                            message: "Recording could not restart after device change within retry budget",
                            context: self.dictationRouteDiagnosticsContext(
                                outputFormat: snapshot.outputFormat,
                                hwFormat: snapshot.hwFormat,
                                selection: snapshot.selection,
                                extra: [
                                    "audio_device": self.inputDeviceName,
                                    "reason": "recording_restart_budget_exhausted"
                                ]
                            ))
                        WorkflowRecoveryTelemetry.finished(
                            workflowKind: "dictation",
                            failureKind: "route_changed",
                            retrySource: "audio_route_recovery",
                            result: "gave_up",
                            elapsedSeconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt,
                            surface: "runtime",
                            artifactRetained: false
                        )
                    }
                } else {
                    WorkflowRecoveryTelemetry.finished(
                        workflowKind: "dictation",
                        failureKind: "route_changed",
                        retrySource: "audio_route_recovery",
                        result: "success",
                        elapsedSeconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt,
                        surface: "runtime",
                        artifactRetained: false
                    )
                }
            } catch {
                guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                // A timed-out audio-engine operation means the serial engine queue
                // is wedged behind a CoreAudio call that never returned (the AirPods
                // / Bluetooth route-switch hang). Rebuilding on that same queue would
                // never run, so fail safe by abandoning the blocked graph instead.
                let audioEngineQueueBlocked = error is ParakeetAudioEngineWorkError
                let failureAction = ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: shouldRestartRecording)
                if self.recoveryState.finishRecovery(success: false, generation: myGeneration) {
                    self.cancelConfigRecoveryTimeout()
                    self.publishRecoveryState()
                }
                AnalyticsReporter.track(
                    "dictation_audio_route_recovery_finished",
                    properties: self.dictationRouteAnalyticsContext(
                        selection: Self.loadDictationInputDeviceSelection(),
                        extra: [
                            "outcome": "failed",
                            "recovery_latency_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt),
                            "was_recording": "\(shouldRestartRecording)"
                        ]
                    )
                )
                WorkflowRecoveryTelemetry.finished(
                    workflowKind: "dictation",
                    failureKind: "route_changed",
                    retrySource: "audio_route_recovery",
                    result: "failed",
                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt,
                    surface: "runtime",
                    artifactRetained: shouldRestartRecording
                )
                if failureAction.markRecordingInterrupted {
                    self.interruptRecordingAndClearRecoveredTimeline()
                    EventReporter.shared.capture(level: .error, engine: "parakeet",
                        event: "recording_interrupted",
                        message: "Recording interrupted — engine rewarm failed after device change",
                        context: self.dictationRouteDiagnosticsContext(
                            selection: Self.loadDictationInputDeviceSelection(),
                            extra: [
                                "audio_device": self.inputDeviceName,
                                "error": error.localizedDescription
                            ]
                        ))
                }
                if failureAction.reportSentryFailure {
                    EventReporter.shared.capture(level: .error, engine: "parakeet",
                        event: "device_change_rewarm_failed",
                        message: error.localizedDescription,
                        context: self.dictationRouteDiagnosticsContext(
                            selection: Self.loadDictationInputDeviceSelection(),
                            extra: [
                                "audio_device": self.inputDeviceName,
                                "was_recording": "\(shouldRestartRecording)",
                                "recovery_generation": "\(myGeneration)"
                            ]
                        ))
                } else {
                    EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "device_change_rewarm_deferred",
                        message: "Idle audio route still settling after device change",
                        context: self.dictationRouteDiagnosticsContext(
                            selection: Self.loadDictationInputDeviceSelection(),
                            extra: [
                                "was_recording": "false",
                                "error": error.localizedDescription,
                                "recovery_generation": "\(myGeneration)"
                            ]
                        ))
                }
                switch ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(
                    audioEngineQueueBlocked: audioEngineQueueBlocked
                ) {
                case .queuedOnAudioEngineQueue:
                    await self.rebuildAudioEngine(reason: "device_change_rewarm_failed")
                case .abandonBlockedAudioGraph:
                    self.abandonBlockedAudioEngine(reason: "device_change_rewarm_failed")
                }
                if failureAction.schedulePrewarmRetry {
                    self.prewarmRetryCount = 0
                    self.schedulePrewarmRetry()
                }
            }
        }
    }

    private func scheduleConfigRecoveryTimeout(generation: UInt64, wasRecording: Bool) {
        configRecoveryTimeoutTask?.cancel()
        configRecoveryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioDeviceRecoveryTimeout)
            guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
            guard self.recoveryState.timeoutRecovery(generation: generation) else { return }

            self.configRecoveryTimeoutTask = nil
            self.publishRecoveryState()
            let timeoutAction = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: wasRecording)
            let failureAction = timeoutAction.failureAction
            AnalyticsReporter.track(
                "dictation_audio_route_recovery_timeout",
                properties: self.dictationRouteAnalyticsContext(
                    selection: Self.loadDictationInputDeviceSelection(),
                    extra: [
                        "recovery_latency_bucket": AnalyticsReporter.durationBucket(
                            seconds: Double(TranscriptedConstants.audioDeviceRecoveryTimeout) / 1_000_000_000
                        ),
                        "was_recording": "\(wasRecording)"
                    ]
                )
            )
            WorkflowRecoveryTelemetry.finished(
                workflowKind: "dictation",
                failureKind: "route_changed",
                retrySource: "audio_route_recovery",
                result: "gave_up",
                elapsedSeconds: Double(TranscriptedConstants.audioDeviceRecoveryTimeout) / 1_000_000_000,
                surface: "runtime",
                artifactRetained: wasRecording
            )
            let diagnosticsEvent = failureAction.reportSentryFailure
                ? "device_change_recovery_timeout"
                : "device_change_recovery_deferred"
            let diagnosticsLevel: EventLevel = failureAction.reportSentryFailure ? .error : .warning
            let diagnosticsMessage = failureAction.reportSentryFailure
                ? "Audio device recovery timed out"
                : "Idle audio route still settling after device change"
            EventReporter.shared.capture(
                level: diagnosticsLevel,
                engine: "parakeet",
                event: diagnosticsEvent,
                message: diagnosticsMessage,
                context: self.dictationRouteDiagnosticsContext(
                    selection: Self.loadDictationInputDeviceSelection(),
                    extra: [
                        "recovery_generation": "\(generation)",
                        "timeout_ms": "\(TranscriptedConstants.audioDeviceRecoveryTimeout / 1_000_000)",
                        "was_recording": "\(wasRecording)",
                        "audio_device": self.inputDeviceName
                    ]
                )
            )
            if failureAction.markRecordingInterrupted {
                self.interruptRecordingAndClearRecoveredTimeline()
                EventReporter.shared.capture(
                    level: .error,
                    engine: "parakeet",
                    event: "recording_interrupted",
                    message: "Recording interrupted because audio device recovery timed out",
                    context: self.dictationRouteDiagnosticsContext(
                        selection: Self.loadDictationInputDeviceSelection(),
                        extra: [
                            "audio_device": self.inputDeviceName,
                            "reason": "device_change_recovery_timeout"
                        ]
                    )
                )
            }
            switch timeoutAction.rebuildStrategy {
            case .queuedOnAudioEngineQueue:
                await self.rebuildAudioEngine(reason: "device_change_recovery_timeout")
            case .abandonBlockedAudioGraph:
                self.abandonBlockedAudioEngine(reason: "device_change_recovery_timeout")
            }
            if failureAction.schedulePrewarmRetry {
                self.prewarmRetryCount = 0
                self.schedulePrewarmRetry()
            }
        }
    }

    private func cancelConfigRecoveryTimeout() {
        configRecoveryTimeoutTask?.cancel()
        configRecoveryTimeoutTask = nil
    }

    private func publishRecoveryState() {
        isRecovering = recoveryState.isRecovering
        inputFormatReady = recoveryState.inputFormatReady
    }

    private func markFormatUnreadyAndPublish() {
        recoveryState.markFormatUnready()
        publishRecoveryState()
    }

    private func markStartFailedAndPublish() {
        recoveryState.markStartFailed()
        publishRecoveryState()
    }

    private func markFormatReadyAndPublish() {
        if !recoveryState.inputFormatReady {
            recoveryState.markFormatReady()
            publishRecoveryState()
        }
    }

    private nonisolated static func audioFormatSummary(_ format: AVAudioFormat) -> ParakeetAudioFormatSummary {
        ParakeetAudioFormatSummary(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }

    private func safeNativeSampleRate() -> Double {
        ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(nativeSampleRate)
    }

    private func updateNativeSampleRate(_ sampleRate: Double) {
        nativeSampleRate = ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(sampleRate)
    }

    private func reserveNativeSampleBufferCapacity() {
        sampleBuffer.reserveCapacity(
            ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
                sampleRate: safeNativeSampleRate(),
                seconds: TranscriptedConstants.audioBufferCapacitySeconds
            )
        )
    }

    private func audioFormatReadiness(
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        selection: DictationInputDeviceSelection?
    ) -> ParakeetAudioFormatReadiness {
        ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: outputFormat.sampleRate,
            outputChannelCount: outputFormat.channelCount,
            inputSampleRate: hwFormat.sampleRate,
            inputChannelCount: hwFormat.channelCount,
            selectedInputClass: selectedInputClass(for: selection),
            outputDeviceClass: defaultOutputClass(for: selection),
            selectionOverrodeDefault: selection?.didOverrideDefault ?? false,
            selectionReason: selection?.reason
        )
    }

    private func selectedInputClass(for selection: DictationInputDeviceSelection?) -> String {
        if let selection {
            return DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
        }
        return inputDeviceClass(for: inputDeviceName)
    }

    private func defaultOutputClass(for selection: DictationInputDeviceSelection?) -> String {
        selection?.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown"
    }

    private func audioFormatContext(
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        selection: DictationInputDeviceSelection?,
        readiness: ParakeetAudioFormatReadiness
    ) -> [String: String] {
        var context = [
            "format_readiness": readiness.rawValue,
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "input_device_class": selectedInputClass(for: selection),
            "selection_overrode_default": "\(selection?.didOverrideDefault ?? false)",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
        ]

        if let selection {
            context["selection_reason"] = selection.reason.rawValue
            context["default_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput)
            context["selected_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
            if let defaultOutput = selection.defaultOutput {
                context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
            }
        }

        return context
    }

    private func dictationRouteDiagnosticsContext(
        outputFormat: ParakeetAudioFormatSummary? = nil,
        hwFormat: ParakeetAudioFormatSummary? = nil,
        selection: DictationInputDeviceSelection?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var context = dictationRouteAnalyticsContext(
            outputFormat: outputFormat,
            hwFormat: hwFormat,
            selection: selection
        )
        context["recovering"] = "\(recoveryState.isRecovering)"
        context["format_ready"] = "\(recoveryState.inputFormatReady)"
        context["generation"] = "\(recoveryState.generation)"

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    private func dictationRouteAnalyticsContext(
        outputFormat: ParakeetAudioFormatSummary? = nil,
        hwFormat: ParakeetAudioFormatSummary? = nil,
        selection: DictationInputDeviceSelection?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let selectedClass = selectedInputClass(for: selection)
        let defaultInputClass = selection.map { DictationInputDeviceSelectionPolicy.deviceClass(for: $0.defaultInput) } ?? "unknown"
        let defaultOutputClass = selection?.defaultOutput.map { DictationInputDeviceSelectionPolicy.deviceClass(for: $0) } ?? "unknown"
        let outputRate = outputFormat?.sampleRate
        let inputRate = hwFormat?.sampleRate

        var context: [String: String] = [
            "default_input_class": defaultInputClass,
            "default_output_class": defaultOutputClass,
            "format_ready": "\(recoveryState.inputFormatReady)",
            "hfp_suspected": "\(ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(inputClass: selectedClass, outputDeviceClass: defaultOutputClass, inputRate: inputRate, outputRate: outputRate))",
            "input_device_class": selectedClass,
            "output_device_class": defaultOutputClass,
            "recovering": "\(recoveryState.isRecovering)",
            "route_shape": ParakeetRouteDiagnosticsPolicy.routeShape(
                selectedInputClass: selectedClass,
                outputDeviceClass: defaultOutputClass
            ),
            "sample_flow_started": "\(didReceiveAudioSamples)",
            "selection_overrode_default": "\(selection?.didOverrideDefault ?? false)",
            "selection_reason": selection?.reason.rawValue ?? "unknown",
            "selected_input_class": selectedClass,
        ]

        if let outputFormat {
            context["output_rate_hz"] = String(format: "%.0f", outputFormat.sampleRate)
            context["output_channels"] = "\(outputFormat.channelCount)"
        }

        if let hwFormat {
            context["input_rate_hz"] = String(format: "%.0f", hwFormat.sampleRate)
            context["input_channels"] = "\(hwFormat.channelCount)"
        }

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    private func audioInputSnapshot(
        operation: String,
        recoveryGeneration: UInt64? = nil,
        allowsBuiltInBluetoothFallback: Bool = true
    ) async throws -> ParakeetAudioInputSnapshot {
        let snapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let selectionStartedAt = CFAbsoluteTimeGetCurrent()
        let selection = Self.loadDictationInputDeviceSelection(
            allowsBuiltInBluetoothFallback: allowsBuiltInBluetoothFallback
        )
        var stageTimings = [
            "audio_input_selection_load_ms": Self.elapsedMilliseconds(since: selectionStartedAt)
        ]
        if let selection, selection.didOverrideDefault {
            // Avoid touching the current default input before the override is applied.
            // On AirPods routes, even a short read of the default input can briefly
            // pull playback toward headset-mode audio.
            ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent() + 1.0
        }

        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }
        let snapshotGraphGeneration = audioGraphGeneration
        let snapshotReadStartedAt = CFAbsoluteTimeGetCurrent()
        let snapshotResult = try await runTimedAudioEngineWork(operation: "\(operation)_snapshot") { audioEngine in
            let inputNode = audioEngine.inputNode
            let selectionApplication = Self.applyPreferredDictationInputDevice(selection, to: inputNode)
            return (
                outputFormat: Self.audioFormatSummary(inputNode.outputFormat(forBus: 0)),
                hwFormat: Self.audioFormatSummary(inputNode.inputFormat(forBus: 0)),
                selectionApplication: selectionApplication,
                engineWasRunning: audioEngine.isRunning
            )
        }
        stageTimings["audio_input_snapshot_read_ms"] = Self.elapsedMilliseconds(since: snapshotReadStartedAt)
        stageTimings["audio_input_total_ms"] = Self.elapsedMilliseconds(since: snapshotStartedAt)
        let snapshot = ParakeetAudioInputSnapshot(
            outputFormat: snapshotResult.outputFormat,
            hwFormat: snapshotResult.hwFormat,
            selection: selection,
            selectionApplication: snapshotResult.selectionApplication,
            engineWasRunning: snapshotResult.engineWasRunning,
            stageTimings: stageTimings
        )
        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }
        if snapshotGraphGeneration == audioGraphGeneration {
            recordInputSelection(snapshot.selectionApplication, operation: operation)
        }

        guard snapshot.selectionApplication?.didApplyOverride == true else {
            return snapshot
        }

        let immediateReadiness = audioFormatReadiness(
            outputFormat: snapshot.outputFormat,
            hwFormat: snapshot.hwFormat,
            selection: snapshot.selection
        )
        let overrideSettleDelay = ParakeetInputOverrideSettlePolicy.delayNanoseconds(
            afterImmediateReadiness: immediateReadiness
        )
        if overrideSettleDelay == 0 {
            return snapshot
        }

        let settleSleepStartedAt = CFAbsoluteTimeGetCurrent()
        try? await Task.sleep(nanoseconds: overrideSettleDelay)
        stageTimings["audio_input_override_settle_sleep_ms"] = Self.elapsedMilliseconds(since: settleSleepStartedAt)
        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }

        let settledGraphGeneration = audioGraphGeneration
        let settledSnapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let settledSnapshotResult = try await runTimedAudioEngineWork(operation: "\(operation)_settled_snapshot") { audioEngine in
            let inputNode = audioEngine.inputNode
            return (
                outputFormat: Self.audioFormatSummary(inputNode.outputFormat(forBus: 0)),
                hwFormat: Self.audioFormatSummary(inputNode.inputFormat(forBus: 0)),
                engineWasRunning: audioEngine.isRunning
            )
        }
        stageTimings["audio_input_settled_snapshot_read_ms"] = Self.elapsedMilliseconds(since: settledSnapshotStartedAt)
        stageTimings["audio_input_total_ms"] = Self.elapsedMilliseconds(since: snapshotStartedAt)
        let settledSnapshot = ParakeetAudioInputSnapshot(
            outputFormat: settledSnapshotResult.outputFormat,
            hwFormat: settledSnapshotResult.hwFormat,
            selection: selection,
            selectionApplication: snapshot.selectionApplication,
            engineWasRunning: settledSnapshotResult.engineWasRunning,
            stageTimings: stageTimings
        )
        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }
        if settledGraphGeneration == audioGraphGeneration {
            let readiness = audioFormatReadiness(
                outputFormat: settledSnapshot.outputFormat,
                hwFormat: settledSnapshot.hwFormat,
                selection: settledSnapshot.selection
            )
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "dictation_input_device_override_settled",
                message: "Dictation input override settled before reading microphone format",
                context: audioFormatContext(
                    outputFormat: settledSnapshot.outputFormat,
                    hwFormat: settledSnapshot.hwFormat,
                    selection: settledSnapshot.selection,
                    readiness: readiness
                ).merging(
                    ["operation": operation],
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }
        return settledSnapshot
    }

    private func installTapAndStartEngine(isRecoveryAttempt: Bool) async throws -> ParakeetAudioStartSnapshot {
        let wasPrewarmed = isEnginePrewarmed
        return try await runTimedAudioEngineWork(
            operation: "start_recording",
            cleanupAfterLateCompletion: Self.cleanUpLateAudioStart(on:)
        ) { audioEngine in
            let workStartedAt = CFAbsoluteTimeGetCurrent()
            var stageTimings: [String: Int] = [:]
            let inputNode = audioEngine.inputNode
            let tapRemoveStartedAt = CFAbsoluteTimeGetCurrent()
            inputNode.removeTap(onBus: 0)
            stageTimings["audio_tap_remove_ms"] = Self.elapsedMilliseconds(since: tapRemoveStartedAt)
            let voiceProcessingRequested = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
            let voiceProcessingStartedAt = CFAbsoluteTimeGetCurrent()
            Self.applyDictationVoiceProcessingPreference(voiceProcessingRequested, to: inputNode)
            stageTimings["audio_voice_processing_apply_ms"] = Self.elapsedMilliseconds(since: voiceProcessingStartedAt)
            let tapInstallStartedAt = CFAbsoluteTimeGetCurrent()
            inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: nil) { [weak self] buffer, _ in
                guard let self = self,
                      let monoSamples = self.extractMonoSamples(from: buffer) else { return }
                let frameLength = monoSamples.count
                guard frameLength > 0 else { return }
                let bufferFormat = Self.audioFormatSummary(buffer.format)
                let effectiveSampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
                    bufferSampleRate: bufferFormat.sampleRate
                )
                self.nativeSampleRate = effectiveSampleRate

                if !self.didReceiveAudioSamples && frameLength > 0 {
                    self.didReceiveAudioSamples = true
                    let startToFirstSampleMs = self.audioStartReferenceTime.map {
                        Int((CFAbsoluteTimeGetCurrent() - $0) * 1000)
                    }
                    Task { @MainActor in
                        var context = [
                            "sample_rate": "\(effectiveSampleRate)",
                            "channels": "\(bufferFormat.channelCount)",
                            "frames": "\(frameLength)"
                        ]
                        if let startToFirstSampleMs {
                            context["start_to_first_sample_ms"] = "\(startToFirstSampleMs)"
                        }
                        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "audio_samples_detected",
                            message: "Audio samples started flowing",
                            context: context)
                    }
                }

                if self.liveDisplayEnabled, let eou = self.eouManager {
                    let resampled = AudioResampler.resample(monoSamples, from: effectiveSampleRate, to: 16000)
                    let chunk: [Float]? = self.streamingSamplesLock.withLock {
                        self.streamingSampleBuffer.append(contentsOf: resampled)
                        guard self.streamingSampleBuffer.count >= self.eouChunkSamples else { return nil }
                        let ready = self.streamingSampleBuffer
                        self.streamingSampleBuffer = []
                        return ready
                    }
                    if let chunk = chunk, let pcm = self.makePCMBuffer(from: chunk) {
                        Task {
                            do { _ = try await eou.process(audioBuffer: pcm) }
                            catch { EventReporter.shared.capture(level: .warning, engine: "parakeet",
                                event: "eou_process_error", message: error.localizedDescription) }
                        }
                    }
                }

                self.pendingSamplesLock.withLock {
                    self.pendingSamples.append(contentsOf: monoSamples)
                    let maxSamples = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
                        sampleRate: effectiveSampleRate,
                        seconds: TranscriptedConstants.audioBufferCapacitySeconds
                    )
                    let overflowMargin = Int(effectiveSampleRate)
                    if self.pendingSamples.count > maxSamples + overflowMargin {
                        self.pendingSamples.removeFirst(self.pendingSamples.count - maxSamples)
                    }
                }

                let now = CFAbsoluteTimeGetCurrent()
                guard now - self.lastLevelUpdate > TranscriptedConstants.audioMeteringInterval else { return }
                self.lastLevelUpdate = now

                let normalized = DictationAudioLevelMeter.normalizedLevel(from: buffer)

                Task { @MainActor [weak self] in
                    self?.audioLevel = normalized
                }
            }
            stageTimings["audio_tap_install_ms"] = Self.elapsedMilliseconds(since: tapInstallStartedAt)

            let engineWasRunning = audioEngine.isRunning
            if !wasPrewarmed || !audioEngine.isRunning {
                stageTimings["audio_engine_prepare_ms"] = 0
                let engineStartStartedAt = CFAbsoluteTimeGetCurrent()
                try audioEngine.start()
                stageTimings["audio_engine_start_ms"] = Self.elapsedMilliseconds(since: engineStartStartedAt)
            } else {
                stageTimings["audio_engine_prepare_ms"] = 0
                stageTimings["audio_engine_start_ms"] = 0
            }
            stageTimings["audio_start_work_ms"] = Self.elapsedMilliseconds(since: workStartedAt)
            return ParakeetAudioStartSnapshot(
                engineWasRunning: engineWasRunning,
                stageTimings: stageTimings
            )
        }
    }

    private func removeRecordingTap(force: Bool = false) async {
        guard force || inputTapInstalled else { return }
        await runAudioEngineWork { audioEngine in
            // Stop + drain before removing the tap; the canonical stop path
            // (`removeRecordingTap()` then `stopAudioEngine()`) otherwise removes
            // the tap while the engine is still recording and can crash the
            // audio IO thread with `isSink || tap != nullptr`.
            Self.safelyRemoveInputTap(on: audioEngine)
        }
        inputTapInstalled = false
    }

    /// Share the user-consented issue #500 VPIO path with dictation. Meeting
    /// capture owns the prompt; dictation just honors the stable mic-processing
    /// preference on each new recording start.
    private nonisolated static func applyDictationVoiceProcessingPreference(
        _ enabled: Bool,
        to inputNode: AVAudioInputNode
    ) {
        guard inputNode.isVoiceProcessingEnabled != enabled else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(enabled)
            if enabled {
                inputNode.isVoiceProcessingAGCEnabled = true
                if #available(macOS 14.0, *) {
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                }
            }
        } catch {
            let action = enabled ? "enable" : "disable"
            Task { @MainActor in
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "dictation_voice_processing_unavailable",
                    message: "Could not \(action) dictation voice processing; continuing with current input node mode",
                    context: ["requested": "\(enabled)"]
                )
            }
        }
    }

    private func stopAudioEngine() async {
        await runAudioEngineWork { audioEngine in
            if audioEngine.isRunning {
                audioEngine.stop()
            }
        }
    }

    private func resetAudioGraphAfterStartFailure(reason: String, rebuildEngine: Bool) async {
        // Keep runtime/UI state coherent when startRecording fails before we ever
        // transition to a stable recording session.
        cancelAudioWatchdog()
        isRecording = false
        audioLevel = 0
        didReceiveAudioSamples = false

        if rebuildEngine {
            await rebuildAudioEngine(reason: reason)
            return
        }
        audioGraphGeneration += 1
        await runAudioEngineWork { audioEngine in
            Self.safelyRemoveInputTap(on: audioEngine)
            audioEngine.reset()
        }
        inputTapInstalled = false
        isEnginePrewarmed = false
    }

    private func rebuildAudioEngine(reason: String) async {
        audioGraphGeneration += 1
        removeAudioEngineConfigObserver()
        let retiredEngine = audioEngine
        await runAudioEngineWork { audioEngine in
            Self.safelyRemoveInputTap(on: audioEngine)
            audioEngine.reset()
        }
        guard audioEngine === retiredEngine else { return }
        audioEngine = AVAudioEngine()
        ParakeetRetiredAudioEngineStore.shared.retire(retiredEngine, reason: reason)
        inputTapInstalled = false
        isEnginePrewarmed = false
        didReceiveAudioSamples = false
        if !isShuttingDown {
            installAudioEngineConfigObserverIfNeeded()
        }
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "audio_engine_rebuilt",
            message: "Audio engine rebuilt after microphone graph failure",
            context: [
                "reason": reason,
                "recovering": "\(recoveryState.isRecovering)",
                "format_ready": "\(recoveryState.inputFormatReady)",
                "generation": "\(recoveryState.generation)"
            ]
        )
    }

    private func abandonBlockedAudioEngine(reason: String) {
        audioGraphGeneration += 1
        removeAudioEngineConfigObserver()
        let retiredEngine = audioEngine
        audioEngine = AVAudioEngine()
        audioEngineQueue = Self.makeAudioEngineQueue()
        ParakeetRetiredAudioEngineStore.shared.retire(retiredEngine, reason: reason)
        inputTapInstalled = false
        isEnginePrewarmed = false
        didReceiveAudioSamples = false
        if !isShuttingDown {
            installAudioEngineConfigObserverIfNeeded()
        }
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "audio_engine_rebuilt",
            message: "Audio engine rebuilt after blocked microphone graph recovery",
            context: [
                "reason": reason,
                "hard_reset": "true",
                "recovering": "\(recoveryState.isRecovering)",
                "format_ready": "\(recoveryState.inputFormatReady)",
                "generation": "\(recoveryState.generation)"
            ]
        )
    }

    private func handleSystemWake() async {
        print("🔄 PARAKEET | system wake detected, resetting audio engine")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake",
            message: "System woke from sleep, resetting audio engine",
            context: ["was_recording": "\(isRecording)", "was_prewarmed": "\(isEnginePrewarmed)"])

        audioGraphGeneration += 1
        let wasRecording = isRecording
        cancelAudioWatchdog()
        if isRecording {
            pendingSamplesLock.withLock {
                pendingSamples.removeAll(keepingCapacity: true)
            }
            streamingSamplesLock.withLock {
                streamingSampleBuffer.removeAll(keepingCapacity: true)
            }
            Task { await eouManager?.reset() }
            await removeRecordingTap()
            isRecording = false
            audioLevel = 0
        }

        await stopAudioEngine()
        isEnginePrewarmed = false

        if wasRecording {
            interruptRecordingAndClearRecoveredTimeline()
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by system sleep/wake")
        }
    }

    // MARK: - Recording

    @discardableResult
    private static func applyPreferredDictationInputDevice(
        _ selection: DictationInputDeviceSelection?,
        to inputNode: AVAudioInputNode
    ) -> ParakeetInputDeviceApplication? {
        guard let selection else {
            return nil
        }

        guard selection.didOverrideDefault else {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: nil
            )
        }

        guard inputNode.auAudioUnit.deviceID != selection.selectedInput.id else {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: nil
            )
        }

        do {
            try inputNode.auAudioUnit.setDeviceID(selection.selectedInput.id)
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: true,
                reportKey: "\(selection.defaultInput.id)->\(selection.selectedInput.id)",
                errorDescription: nil
            )
        } catch {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func recordInputSelection(
        _ application: ParakeetInputDeviceApplication?,
        operation: String
    ) {
        guard let application else { return }
        let selection = application.selection

        guard selection.didOverrideDefault else {
            cachedInputDeviceName = selection.selectedInput.name
            lastInputSelectionReportKey = nil
            return
        }

        if let errorDescription = application.errorDescription {
            ignoreInputSelectionConfigChangesUntil = 0
            cachedInputDeviceName = selection.defaultInput.name
            var context = inputSelectionContext(selection, operation: operation)
            context["error"] = errorDescription
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_input_device_selection_failed",
                message: "Failed to apply preferred dictation input device",
                context: context
            )
            return
        }

        cachedInputDeviceName = selection.selectedInput.name
        guard application.didApplyOverride,
              let reportKey = application.reportKey,
              lastInputSelectionReportKey != reportKey else { return }

        lastInputSelectionReportKey = reportKey
        print("🎤 PARAKEET | using \(selection.selectedInput.name) instead of \(selection.defaultInput.name) to avoid Bluetooth headset mode")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_input_device_auto_selected",
            message: "Dictation input changed away from Bluetooth headset microphone",
            context: inputSelectionContext(selection, operation: operation)
        )
    }

    private func inputSelectionContext(
        _ selection: DictationInputDeviceSelection,
        operation: String? = nil
    ) -> [String: String] {
        var context = [
            "audio_device": selection.selectedInput.name,
            "default_input_device": selection.defaultInput.name,
            "selected_input_device": selection.selectedInput.name,
            "default_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
            "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
            "selection_reason": selection.reason.rawValue,
            "selection_overrode_default": "\(selection.didOverrideDefault)"
        ]

        if let defaultOutput = selection.defaultOutput {
            context["default_output_device"] = defaultOutput.name
            context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
        }

        if let operation {
            context["operation"] = operation
        }

        return context
    }

    private func audioStartContext(
        attempt: Int,
        isRecoveryAttempt: Bool,
        engineWasRunning: Bool,
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        error: Error? = nil
    ) -> [String: String] {
        var context = [
            "attempt": "\(attempt)",
            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
            "prewarmed": "\(isEnginePrewarmed)",
            "engine_running_before_start": "\(engineWasRunning)",
            "tap_installed": "\(inputTapInstalled)",
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "input_device_class": inputDeviceClass(for: inputDeviceName),
        ]

        if let error {
            let nsError = error as NSError
            context["status_domain"] = nsError.domain
            context["status_code"] = "\(nsError.code)"
        }

        return context
    }

    private func inputDeviceClass(for deviceName: String) -> String {
        DictationInputDeviceSelectionPolicy.deviceClass(forName: deviceName)
    }

    private func reportAudioStartFailureIfNeeded(message: String, context: [String: String]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard ParakeetAudioStartRecoveryPolicy.shouldReportFailure(
            now: now,
            lastReportAt: lastAudioStartFailureReportAt
        ) else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_engine_start_failed",
                message: message,
                context: context.merging(["report_throttled": "true"]) { current, _ in current }
            )
            return
        }

        lastAudioStartFailureReportAt = now
        EventReporter.shared.capture(
            level: .error,
            engine: "parakeet",
            event: "audio_engine_start_failed",
            message: message,
            context: context
        )
    }

    func startRecording(isRecoveryAttempt: Bool = false) async -> Bool {
        guard !isShuttingDown else { return false }
        guard !isRecording else { return true }
        guard !audioStartInProgress else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while another start is still in progress",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)",
                    "audio_graph_generation": "\(audioGraphGeneration)"
                ]
            )
            return false
        }
        audioStartInProgress = true
        audioStartReferenceTime = CFAbsoluteTimeGetCurrent()
        audioGraphGeneration += 1
        var startGeneration = audioGraphGeneration
        defer {
            audioStartInProgress = false
        }

        scheduleInputDeviceNameRefresh()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return false
        }

        installAudioObserversIfNeeded()
        guard isRecoveryAttempt || recoveryState.canStartRecording else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while input format is still recovering",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)"
                ]
            )
            if !recoveryState.isRecovering {
                schedulePrewarmRetry()
            }
            return false
        }

        recordingInterrupted = false
        didReceiveAudioSamples = false
        cancelAudioWatchdog()
        if !isRecoveryAttempt && !preservingRecordingAcrossRecovery {
            recoveredRecordingTimeline.removeAll(keepingCapacity: true)
        }
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        sampleBuffer.removeAll(keepingCapacity: true)
        reserveNativeSampleBufferCapacity()

        let maxAttempts = isRecoveryAttempt ? 1 : 1 + TranscriptedConstants.audioStartRecoveryAttempts
        for attempt in 1...maxAttempts {
            guard startGeneration == audioGraphGeneration else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed before startup finished",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return false
            }

            let snapshot: ParakeetAudioInputSnapshot
            do {
                snapshot = try await audioInputSnapshot(
                    operation: "start_recording",
                    allowsBuiltInBluetoothFallback: !isRecoveryAttempt
                )
            } catch {
                let operationTimedOut = error is ParakeetAudioEngineWorkError
                EventReporter.shared.capture(
                    level: operationTimedOut ? .error : .warning,
                    engine: "parakeet",
                    event: operationTimedOut ? "audio_format_read_timeout" : "audio_format_unavailable",
                    message: operationTimedOut
                        ? "Audio hardware format read timed out while starting dictation"
                        : "Audio hardware format could not be read while starting dictation",
                    context: [
                        "attempt": "\(attempt)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "error": error.localizedDescription
                    ]
                )
                if operationTimedOut {
                    abandonBlockedAudioEngine(reason: "audio_format_read_timeout")
                } else {
                    await resetAudioGraphAfterStartFailure(reason: "audio_format_read_failed", rebuildEngine: true)
                }
                markFormatUnreadyAndPublish()
                schedulePrewarmRetry()
                return false
            }
            guard startGeneration == audioGraphGeneration else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed while reading input format",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return false
            }

            let readiness = audioFormatReadiness(
                outputFormat: snapshot.outputFormat,
                hwFormat: snapshot.hwFormat,
                selection: snapshot.selection
            )
            guard readiness == .ready else {
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: readiness.startFailureReason ?? .invalidAudioFormat,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                print("⚠️ PARAKEET | input format unavailable (\(readiness.rawValue)): output=\(snapshot.outputFormat.sampleRate)Hz/\(snapshot.outputFormat.channelCount)ch hw=\(snapshot.hwFormat.sampleRate)Hz/\(snapshot.hwFormat.channelCount)ch")
                var context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat
                )
                context.merge(
                    audioFormatContext(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection,
                        readiness: readiness
                    )
                ) { current, _ in current }
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_format_unavailable",
                    message: "Audio hardware format not ready while starting dictation",
                    context: context
                )
                await resetAudioGraphAfterStartFailure(
                    reason: readiness == .routeNotSettled ? "audio_route_not_settled" : "invalid_audio_format",
                    rebuildEngine: startFailureAction.rebuildAudioEngine
                )
                if startFailureAction.markFormatUnready {
                    markFormatUnreadyAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return false
            }

            updateNativeSampleRate(snapshot.outputFormat.sampleRate)
            reserveNativeSampleBufferCapacity()

            do {
                let startSnapshot = try await installTapAndStartEngine(isRecoveryAttempt: isRecoveryAttempt)
                guard startGeneration == audioGraphGeneration else {
                    await removeRecordingTap(force: true)
                    await stopAudioEngine()
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_start_aborted",
                        message: "Audio start aborted because the audio graph changed while starting",
                        context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                    )
                    return false
                }
                inputTapInstalled = true
                isEnginePrewarmed = true

                var timingContext = dictationRouteAnalyticsContext(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection,
                    extra: [
                        "engine_running_before_start": "\(startSnapshot.engineWasRunning)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                    ]
                )
                timingContext.merge(Self.timingContext(snapshot.stageTimings)) { current, _ in current }
                timingContext.merge(Self.timingContext(startSnapshot.stageTimings)) { current, _ in current }
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "dictation_audio_start_timing",
                    message: "Dictation audio start stage timing",
                    context: timingContext
                )

                if !startSnapshot.engineWasRunning && isEnginePrewarmed {
                    EventReporter.shared.capture(level: .info, engine: "parakeet",
                        event: "audio_engine_started",
                        message: "Audio engine started on worker queue",
                        context: [
                            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                            "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                            "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate)
                        ])
                }
            } catch {
                let operationTimedOut = error is ParakeetAudioEngineWorkError
                let context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    error: error
                )
                let failureReason = operationTimedOut
                    ? ParakeetStartRecordingFailureReason.audioEngineStartFailed
                    : ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error as NSError)
                let shouldRetry = !operationTimedOut
                    && failureReason == .audioEngineStartFailed
                    && ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(
                    isRecoveryAttempt: isRecoveryAttempt,
                    failedAttempts: attempt
                )
                if operationTimedOut {
                    abandonBlockedAudioEngine(reason: "audio_engine_start_timeout")
                } else {
                    await resetAudioGraphAfterStartFailure(
                        reason: failureReason == .audioRouteNotSettled ? "audio_route_not_settled" : "audio_engine_start_failed",
                        rebuildEngine: true
                    )
                }

                if shouldRetry {
                    startGeneration = audioGraphGeneration
                    print("🔄 PARAKEET | audio engine start failed, resetting graph and retrying once: \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_engine_start_retrying",
                        message: "Audio engine failed to start; resetting graph and retrying",
                        context: context
                    )
                    continue
                }

                if failureReason == .audioRouteNotSettled {
                    print("⚠️ PARAKEET | audio route format unsupported while starting; waiting for CoreAudio to settle")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_route_not_settled",
                        message: "Audio route format was not ready while starting dictation",
                        context: context
                    )
                    let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                        for: failureReason,
                        isRecoveryAttempt: isRecoveryAttempt
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return false
                }

                if operationTimedOut {
                    print("❌ PARAKEET | audio engine start timed out after \(attempt) attempt(s): \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .error,
                        engine: "parakeet",
                        event: "audio_engine_start_timeout",
                        message: "Audio engine start timed out; abandoned blocked microphone graph",
                        context: context
                    )
                    let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                        for: .audioEngineStartFailed,
                        isRecoveryAttempt: isRecoveryAttempt
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return false
                }

                print("❌ PARAKEET | audio engine failed after \(attempt) attempt(s): \(error.localizedDescription)")
                reportAudioStartFailureIfNeeded(message: error.localizedDescription, context: context)
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: .audioEngineStartFailed,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                if startFailureAction.markFormatUnready {
                    markStartFailedAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return false
            }

            if attempt > 1 {
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "audio_engine_start_recovered",
                    message: "Audio engine started after a graph reset",
                    context: [
                        "attempts": "\(attempt)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                        "output_channels": "\(snapshot.outputFormat.channelCount)",
                        "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate),
                        "hw_channels": "\(snapshot.hwFormat.channelCount)",
                    ]
                )
            }
            lastAudioStartFailureReportAt = nil
            break
        }

        isRecording = true
        markFormatReadyAndPublish()
        liveTranscript = ""
        committedStreamText = ""
        if liveDisplayEnabled {
            streamingSamplesLock.withLock {
                streamingSampleBuffer.removeAll(keepingCapacity: true)
            }
            Task { await eouManager?.reset() }
        }
        print("🎤 PARAKEET | recording started (\(inputDeviceName), \(safeNativeSampleRate())Hz)")

        // Watchdog: detect zombie audio engine (running but no samples flowing after sleep/wake).
        // Only on first attempt — recovery attempt doesn't re-watchdog to prevent infinite loops.
        if !isRecoveryAttempt {
            startAudioWatchdog()
        }

        return true
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        guard frameCount > 0, channelCount > 0 else { return [] }

        if channelCount == 1 {
            guard let channelData = buffer.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        }

        var monoSamples = Array<Float>(repeating: 0, count: frameCount)

        if buffer.format.isInterleaved {
            guard let interleavedData = buffer.floatChannelData?[0] else { return nil }
            for frame in 0..<frameCount {
                let baseIndex = frame * channelCount
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleavedData[baseIndex + channel]
                }
                monoSamples[frame] = sum / Float(channelCount)
            }
            return monoSamples
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            monoSamples[frame] = sum / Float(channelCount)
        }
        return monoSamples
    }

    /// Watchdog that detects zombie audio engines — running but producing no samples.
    /// After sleep/wake, CoreAudio may report the engine as running but the hardware graph
    /// is disconnected. If no samples arrive within 2 seconds, tear down and retry once.
    /// If the user stops dictation during the recovery delay, the pending retry is cleared
    /// so the watchdog does not revive a recording the user already ended.
    private func startAudioWatchdog() {
        cancelAudioWatchdog()
        audioWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioWatchdogTimeout)
            guard let self = self, self.isRecording, !Task.isCancelled else { return }

            let sampleCount = self.pendingSamplesLock.withLock {
                guard self.isRecording else { return -1 }
                return self.pendingSamples.count + self.sampleBuffer.count
            }
            guard sampleCount >= 0 else { return }

            guard sampleCount == 0 else { return }  // Audio is flowing — all good

            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "zombie_engine_detected",
                message: "No audio samples received after recording start — resetting engine",
                context: ["audio_device": self.inputDeviceName])

            self.streamingSamplesLock.withLock {
                self.streamingSampleBuffer.removeAll(keepingCapacity: true)
            }
            self.pendingSamplesLock.withLock {
                self.pendingSamples.removeAll(keepingCapacity: true)
            }
            self.zombieRecoveryRestartPending = true
            self.isRecording = false
            self.audioLevel = 0
            self.configChangeWasRecording = false
            self.ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent() + 1.0
            await self.eouManager?.reset()
            await self.removeRecordingTap()
            await self.stopAudioEngine()
            self.isEnginePrewarmed = false

            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled, self.zombieRecoveryRestartPending else {
                self.zombieRecoveryRestartPending = false
                return
            }
            self.zombieRecoveryRestartPending = false

            // Retry once — isRecoveryAttempt prevents another watchdog
            if await self.startRecording(isRecoveryAttempt: true) {
                print("✅ PARAKEET | zombie engine recovered — recording restarted")
                EventReporter.shared.capture(level: .info, engine: "parakeet", event: "zombie_engine_recovered",
                    message: "Audio engine recovered after reset")
            } else {
                print("❌ PARAKEET | zombie engine recovery failed")
                EventReporter.shared.capture(level: .error, engine: "parakeet", event: "zombie_engine_recovery_failed",
                    message: "Audio engine could not recover after reset",
                    context: ["audio_device": self.inputDeviceName])
                self.interruptRecordingAndClearRecoveredTimeline()
            }
        }
    }

    func stopRecording() async {
        guard isRecording else {
            // A zombie reset marks recording idle while it waits to retry. Treat a
            // user stop in that window as cancellation of the pending restart.
            if zombieRecoveryRestartPending {
                audioGraphGeneration += 1
                cancelAudioWatchdog()
                clearRecoveredRecordingTimeline(keepingCapacity: true)
                return
            }
            if audioStartInProgress {
                audioGraphGeneration += 1
            } else {
                clearRecoveredRecordingTimeline(keepingCapacity: true)
            }
            return
        }
        audioGraphGeneration += 1
        cancelAudioWatchdog()
        if liveDisplayEnabled {
            let remainingEou: [Float] = streamingSamplesLock.withLock {
                let remainingEou = streamingSampleBuffer
                streamingSampleBuffer.removeAll(keepingCapacity: true)
                return remainingEou
            }
            if let eou = eouManager, !remainingEou.isEmpty, let pcm = makePCMBuffer(from: remainingEou) {
                Task {
                    do { _ = try await eou.process(audioBuffer: pcm) }
                    catch { EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "eou_process_error", message: error.localizedDescription) }
                }
            }
        }
        await removeRecordingTap()
        await stopAudioEngine()
        isEnginePrewarmed = false
        drainPendingSamplesIntoSampleBuffer()
        isRecording = false
        audioLevel = 0
        let stopSampleRate = safeNativeSampleRate()
        print("⏹️ PARAKEET | recording stopped (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / stopSampleRate))s)")
    }

    // MARK: - EOU Streaming (live display)
    // Live display is driven by StreamingEouAsrManager fed via the audio tap (see startRecording).
    // EOU callback in initializeEouModel() updates committedStreamText → liveTranscript.
    // No explicit start/stop methods needed — tap feeds the manager, reset() clears state.

    private func drainPendingSamplesIntoSampleBuffer() {
        pendingSamplesLock.withLock {
            guard !pendingSamples.isEmpty else { return }
            if sampleBuffer.isEmpty {
                swap(&sampleBuffer, &pendingSamples)
            } else {
                sampleBuffer.append(contentsOf: pendingSamples)
                pendingSamples.removeAll(keepingCapacity: false)
            }
        }
    }

    private func preserveCurrentRecordingBuffersForRecovery() {
        drainPendingSamplesIntoSampleBuffer()
        if !sampleBuffer.isEmpty {
            recoveredRecordingTimeline.append(sampleBuffer, sampleRate: safeNativeSampleRate())
            sampleBuffer.removeAll(keepingCapacity: true)
        }
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty
    }

    private func clearRecoveredRecordingTimeline(keepingCapacity: Bool = true) {
        recoveredRecordingTimeline.removeAll(keepingCapacity: keepingCapacity)
        preservingRecordingAcrossRecovery = false
    }

    private func interruptRecordingAndClearRecoveredTimeline() {
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        recordingInterrupted = true
    }

    func loadRecordedSamplesForDictationBenchmark(_ samples: [Float], sampleRate: Double) {
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        sampleBuffer = samples
        recoveredRecordingTimeline.removeAll(keepingCapacity: true)
        preservingRecordingAcrossRecovery = false
        nativeSampleRate = sampleRate
        isRecording = false
        isTranscribing = false
        recordingInterrupted = false
        audioLevel = 0
    }

    private func drainRecordedSamplesForInference() async -> (nativeSampleCount: Int, samples16k: [Float])? {
        drainPendingSamplesIntoSampleBuffer()

        if !recoveredRecordingTimeline.isEmpty {
            recoveredRecordingTimeline.append(sampleBuffer, sampleRate: safeNativeSampleRate())
            sampleBuffer.removeAll(keepingCapacity: true)
            let segments = recoveredRecordingTimeline.drain()
            preservingRecordingAcrossRecovery = false
            let nativeSampleCount = segments.reduce(0) { $0 + $1.samples.count }
            guard nativeSampleCount > 0 else { return nil }
            let resampled = await Task.detached(priority: .userInitiated) {
                var combined: [Float] = []
                for segment in segments {
                    combined.append(contentsOf: AudioResampler.resample(
                        segment.samples,
                        from: segment.sampleRate,
                        to: TranscriptedConstants.parakeetSampleRate
                    ))
                }
                return combined
            }.value
            return (nativeSampleCount, resampled)
        }

        guard !sampleBuffer.isEmpty else { return nil }
        var samples: [Float] = []
        swap(&samples, &sampleBuffer)
        let inputRate = safeNativeSampleRate()
        let nativeSampleCount = samples.count
        let samplesForResampling = samples
        samples.removeAll(keepingCapacity: false)
        let resampled = await Task.detached(priority: .userInitiated) {
            AudioResampler.resample(
                samplesForResampling,
                from: inputRate,
                to: TranscriptedConstants.parakeetSampleRate
            )
        }.value
        return (nativeSampleCount, resampled)
    }

    /// Convert [Float] samples to AVAudioPCMBuffer for StreamingEouAsrManager.
    private func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = eouPCMFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dest = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                guard let baseAddress = src.baseAddress else { return }
                dest.update(from: baseAddress, count: samples.count)
            }
        }
        return buffer
    }

    // MARK: - Transcription

    func drainRecordedSamplesForExternalTranscription(engineName: String) async -> RecordedSpeechSamples? {
        guard !isTranscribing else {
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress"
            )
            return nil
        }

        drainPendingSamplesIntoSampleBuffer()

        guard !sampleBuffer.isEmpty || !recoveredRecordingTimeline.isEmpty else {
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called"
            )
            return nil
        }

        isTranscribing = true
        guard let recorded = await drainRecordedSamplesForInference() else {
            finishExternalTranscription()
            return nil
        }
        let nativeCount = recorded.nativeSampleCount
        let resampled = recorded.samples16k
        print("🔄 \(engineName.uppercased()) | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            print("⚠️ \(engineName.uppercased()) | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            finishExternalTranscription()
            return nil
        }

        return RecordedSpeechSamples(nativeSampleCount: nativeCount, samples16k: resampled)
    }

    func finishExternalTranscription() {
        finishTranscription()
    }

    private func finishTranscription() {
        isTranscribing = false
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
    }

    private var hasActiveASRWork: Bool {
        asrInferenceActivity.isActive
            || asrInferenceHandoffCount > 0
            || !asrInferenceWaiters.isEmpty
            || pureSampleTranscriptionActivityCount > 0
    }

    private func beginPureSampleTranscriptionActivity() {
        pureSampleTranscriptionActivityCount += 1
    }

    private func finishPureSampleTranscriptionActivity() {
        pureSampleTranscriptionActivityCount = max(0, pureSampleTranscriptionActivityCount - 1)
    }

    private func beginASRInference() async {
        if asrInferenceActivity.canStartImmediately(reservedHandoffCount: asrInferenceHandoffCount) {
            asrInferenceActivity.begin()
            return
        }

        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "asr_inference_deferred",
            message: "ASR inference request queued behind active decoder work",
            context: [
                "active_count": "\(asrInferenceActivity.activeCount)",
                "handoff_count": "\(asrInferenceHandoffCount)",
                "waiter_count": "\(asrInferenceWaiters.count)"
            ]
        )
        await withCheckedContinuation { continuation in
            asrInferenceWaiters.append(continuation)
        }
        asrInferenceHandoffCount = max(0, asrInferenceHandoffCount - 1)
        asrInferenceActivity.begin()
    }

    private func finishASRInference() {
        asrInferenceActivity.finish()
        if let next = asrInferenceWaiters.first {
            asrInferenceWaiters.removeFirst()
            asrInferenceHandoffCount += 1
            next.resume()
            return
        }
    }

    private func runASRInference(
        manager: AsrManager,
        samples: [Float],
        source: AudioSource
    ) async throws -> String {
        await beginASRInference()
        do {
            try Task.checkCancellation()
            let result = try await manager.transcribe(samples, source: source)
            let text = withExtendedLifetime(result) {
                String(result.text)
            }
            finishASRInference()
            return text
        } catch {
            finishASRInference()
            throw error
        }
    }

    func transcribe() async -> String? {
        guard !isTranscribing else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress")
            return nil
        }
        drainPendingSamplesIntoSampleBuffer()
        guard !sampleBuffer.isEmpty || !recoveredRecordingTimeline.isEmpty else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called")
            return nil
        }
        guard let manager = asrManager, asrManagerReady else {
            print("❌ PARAKEET | ASR manager not available")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcription")
            return nil
        }

        isTranscribing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let recorded = await drainRecordedSamplesForInference() else {
            finishTranscription()
            return nil
        }
        let nativeCount = recorded.nativeSampleCount
        let resampled = recorded.samples16k
        print("🔄 PARAKEET | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            print("⚠️ PARAKEET | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            finishTranscription()
            return nil
        }

        do {
            let resultText = try await runASRInference(
                manager: manager,
                samples: resampled,
                source: .microphone
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = CustomDictionaryTextProcessor.apply(to: trimmed)

            let audioDuration = Double(resampled.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
            print("✅ PARAKEET | transcribed in \(String(format: "%.2f", elapsed))s, chars=\(corrected.count)")

            if trimmed.isEmpty {
                let analysis = DictationAudioRecovery.analyze(
                    samples: resampled,
                    sampleRate: TranscriptedConstants.parakeetSampleRate
                )
                var emptyContext = ["samples": "\(nativeCount)"]
                emptyContext.merge(analysis.context) { current, _ in current }

                if let retrySamples = DictationAudioRecovery.retrySamples(
                    from: resampled,
                    sampleRate: TranscriptedConstants.parakeetSampleRate,
                    analysis: analysis
                ) {
                    let retryStarted = CFAbsoluteTimeGetCurrent()
                    EventReporter.shared.capture(
                        level: .info,
                        engine: "parakeet",
                        event: "dictation_empty_retry_started",
                        message: "Retrying empty dictation with focused audio",
                        context: emptyContext.merging([
                            "retry_samples": "\(retrySamples.count)",
                            "retry_audio_duration_s": String(format: "%.2f", Double(retrySamples.count) / TranscriptedConstants.parakeetSampleRate),
                        ]) { current, _ in current }
                    )

                    do {
                        let retryResultText = try await runASRInference(
                            manager: manager,
                            samples: retrySamples,
                            source: .microphone
                        )
                        let retryElapsed = CFAbsoluteTimeGetCurrent() - retryStarted
                        let retryTrimmed = retryResultText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let retryCorrected = CustomDictionaryTextProcessor.apply(to: retryTrimmed)
                        if !retryTrimmed.isEmpty {
                            let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
                            let retryDuration = Double(retrySamples.count) / TranscriptedConstants.parakeetSampleRate
                            let retryRtf = retryDuration > 0 ? retryElapsed / retryDuration : 0
                            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_recovered",
                                message: "Recovered empty dictation on retry",
                                context: emptyContext.merging([
                                    "elapsed_s": String(format: "%.3f", totalElapsed),
                                    "retry_elapsed_s": String(format: "%.3f", retryElapsed),
                                    "retry_audio_duration_s": String(format: "%.2f", retryDuration),
                                    "retry_rtf": String(format: "%.3f", retryRtf),
                                    "retry_samples": "\(retrySamples.count)",
                                    "chars": "\(retryCorrected.count)",
                                    "input_samples": "\(nativeCount)",
                                ]) { current, _ in current })
                            finishTranscription()
                            return retryCorrected
                        }

                        emptyContext["retry_empty"] = "true"
                        emptyContext["retry_elapsed_s"] = String(format: "%.3f", retryElapsed)
                        emptyContext["retry_samples"] = "\(retrySamples.count)"
                    } catch {
                        emptyContext["retry_error"] = error.localizedDescription
                    }
                } else if !analysis.hasUsableSpeechSignal {
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "dictation_audio_silent",
                        message: "Dictation audio did not contain enough speech-like signal",
                        context: emptyContext
                    )
                }

                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_empty",
                    message: "Parakeet returned no text after \(String(format: "%.1f", elapsed))s inference",
                    context: emptyContext)
                finishTranscription()
                return nil
            }

            finishTranscription()

            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_complete",
                message: "Transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.1f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(corrected.count)",
                    "input_samples": "\(nativeCount)",
                ])
            return corrected
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if let fallbackDecision = ParakeetShortAudioGate.dictationFallback(
                nativeSampleCount: nativeCount,
                resampledSampleCount: resampled.count,
                errorMessage: error.localizedDescription
            ) {
                var fallbackContext = fallbackDecision.context
                fallbackContext["elapsed"] = String(format: "%.2f", elapsed)
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: fallbackDecision.event ?? "recording_too_short",
                    message: fallbackDecision.message ?? "Dictation audio too short for transcription",
                    context: fallbackContext
                )
                finishTranscription()
                return nil
            }

            print("❌ PARAKEET | transcription failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "transcription_failed",
                message: error.localizedDescription,
                context: ["samples": "\(nativeCount)", "elapsed": String(format: "%.2f", elapsed)])
            finishTranscription()
            return nil
        }
    }

    // MARK: - Pure-Sample Transcription (for Meeting pipeline)

    /// Transcribe pre-resampled 16kHz mono Float32 samples directly, bypassing
    /// ParakeetEngine's recording lifecycle (audioEngine, sampleBuffer, EOU streaming).
    ///
    /// Used by `MeetingSTTAdapter` to satisfy Core's `SpeechToTextEngine` protocol:
    /// Core's TranscriptionPipeline owns its own recording (mic + system audio files via
    /// `Audio.swift`), extracts 16kHz samples per speaker segment, and calls this method
    /// once per segment. This is distinct from the app's regular dictation flow, which uses
    /// `startRecording()` / `transcribe()` to capture and transcribe in one shot.
    ///
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 samples. Caller must resample; we do not.
    ///   - source: FluidAudio's `AudioSource` (`.microphone` or `.system`).
    /// - Returns: Transcribed text, trimmed. Empty string if Parakeet returned nothing.
    /// - Throws: Re-throws `AsrManager.transcribe` errors (including model-not-ready).
    func transcribeSamples(_ samples: [Float], source: AudioSource) async throws -> String {
        beginPureSampleTranscriptionActivity()
        defer { finishPureSampleTranscriptionActivity() }

        guard let manager = asrManager, asrManagerReady else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcribeSamples")
            throw NSError(domain: "ParakeetEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet ASR manager is not loaded"
            ])
        }
        guard !samples.isEmpty else { return "" }
        let shortAudioDecision = ParakeetShortAudioGate.meetingSegment(
            sampleCount: samples.count,
            sourceDescription: source == .microphone ? "microphone" : "system"
        )
        guard shortAudioDecision.shouldTranscribe else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: shortAudioDecision.event ?? "segment_too_short",
                message: shortAudioDecision.message ?? "Skipped short audio segment before Parakeet transcription",
                context: shortAudioDecision.context
            )
            return ""
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let sourceDescription = source == .microphone ? "microphone" : "system"
        let resultText: String
        do {
            resultText = try await runASRInference(
                manager: manager,
                samples: samples,
                source: source
            )
        } catch {
            if let fallbackDecision = ParakeetShortAudioGate.meetingSegmentFallback(
                sampleCount: samples.count,
                sourceDescription: sourceDescription,
                errorMessage: error.localizedDescription
            ) {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: fallbackDecision.event ?? "segment_too_short",
                    message: fallbackDecision.message ?? "Skipped short audio segment before Parakeet transcription",
                    context: fallbackDecision.context
                )
                return ""
            }
            throw error
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = CustomDictionaryTextProcessor.apply(to: trimmed)

        let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
        let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "meeting_segment_transcribed",
            message: "Meeting segment transcribed in \(String(format: "%.2f", elapsed))s",
            context: [
                "elapsed_s": String(format: "%.3f", elapsed),
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "rtf": String(format: "%.3f", rtf),
                "chars": "\(corrected.count)",
            ])

        return corrected
    }

    // MARK: - Cleanup

    func resetAfterFailedRecordingStart() async {
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        recoveryState.markFormatUnready()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        streamingSamplesLock.withLock {
            streamingSampleBuffer.removeAll(keepingCapacity: true)
        }
        await eouManager?.reset()
        isRecording = false
        isTranscribing = false
        audioLevel = 0
        didReceiveAudioSamples = false
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        liveTranscript = ""
        committedStreamText = ""
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        await releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
    }

    func abandonBlockedRecordingStart(reason: String) {
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        recoveryState.markFormatUnready()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        streamingSamplesLock.withLock {
            streamingSampleBuffer.removeAll(keepingCapacity: true)
        }
        Task { await eouManager?.reset() }
        isRecording = false
        isTranscribing = false
        audioStartInProgress = false
        audioLevel = 0
        didReceiveAudioSamples = false
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        liveTranscript = ""
        committedStreamText = ""
        abandonBlockedAudioEngine(reason: reason)
    }

    func cancel() {
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        if isRecording {
            if liveDisplayEnabled {
                streamingSamplesLock.withLock {
                    streamingSampleBuffer.removeAll(keepingCapacity: true)
                }
                Task { await eouManager?.reset() }
            }
            isRecording = false
            audioLevel = 0
        }
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        Task { @MainActor [weak self] in
            await self?.releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
        }
        sampleBuffer.removeAll()
        clearRecoveredRecordingTimeline(keepingCapacity: false)
        isTranscribing = false
        liveTranscript = ""
        committedStreamText = ""
    }

    private func releaseIdleAudioHardware(removeTap: Bool, expectedGeneration: Int? = nil) async {
        if let expectedGeneration, expectedGeneration != audioGraphGeneration {
            return
        }
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        if removeTap {
            await removeRecordingTap(force: true)
        }
        if expectedGeneration != nil, cleanupGeneration != audioGraphGeneration {
            return
        }
        await stopAudioEngine()
        if expectedGeneration != nil, cleanupGeneration != audioGraphGeneration {
            return
        }
        isEnginePrewarmed = false
    }

    private func cancelAudioWatchdog() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        zombieRecoveryRestartPending = false
    }

    func cleanup() {
        isShuttingDown = true
        modelInitializationTask?.cancel()
        modelInitializationTask = nil
        modelFilePrefetchTask?.cancel()
        modelFilePrefetchTask = nil
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        Task { @MainActor [weak self] in
            await self?.releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
        }
        isRecording = false
        audioLevel = 0
        removeAudioEngineConfigObserver()
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        removeInputDeviceChangeListener()
        let cleanupDecision = ParakeetASRManagerCleanupPolicy.decision(
            isTranscribing: isTranscribing || hasActiveASRWork
        )
        let mgr = asrManager
        if cleanupDecision == .cleanupNow {
            asrManager = nil
        }
        asrManagerReady = false
        eouManager = nil
        modelDownloadState = .notLoaded
        if cleanupDecision == .cleanupNow {
            Task { mgr?.cleanup() }
        } else {
            print("ℹ️ PARAKEET | deferring ASR manager cleanup while transcription is active")
        }
    }

    deinit {
        modelInitializationTask?.cancel()
        modelFilePrefetchTask?.cancel()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        unregisterDefaultInputDeviceListener(inputDeviceChangeListener)
        audioEngineQueue.async { [audioEngine] in
            ParakeetEngine.safelyRemoveInputTap(on: audioEngine)
            audioEngine.reset()
        }
        ParakeetRetiredAudioEngineStore.shared.retire(audioEngine, reason: "deinit")
        let mgr = asrManager
        Task { mgr?.cleanup() }
        eouManager = nil
    }
}
