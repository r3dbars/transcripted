// ParakeetEngine.swift
// FluidAudio-based STT engine — CoreML Parakeet TDT V3 for batch transcription.
// AVAudioEngine tap → NSLock-batched samples → resampled to 16kHz → AsrManager.transcribe()
// for final batch inference.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import FluidAudio
import Foundation
import TranscriptedCore

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private enum InputDeviceLookupError: Error {
    case propertyReadFailed(OSStatus)
    case unknownDevice
}

private enum CoreAudioInputDeviceLookup {
    static func defaultInputDeviceName() throws -> String {
        let deviceID = try defaultInputDeviceID()
        let name = try readStringProperty(
            selector: kAudioDevicePropertyDeviceNameCFString,
            objectID: AudioObjectID(deviceID)
        )
        return name.isEmpty ? "Unknown" : name
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw InputDeviceLookupError.unknownDevice
        }

        return deviceID
    }

    private static func readStringProperty(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                UnsafeMutableRawPointer(valuePointer)
            )
        }

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        return (value?.takeUnretainedValue() as String?) ?? ""
    }
}

private func unregisterDefaultInputDeviceListener(_ listener: AudioObjectPropertyListenerBlock?) {
    guard let listener else { return }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        .main,
        listener
    )

    if status != noErr {
        print("⚠️ PARAKEET | failed to remove default input listener (\(status))")
    }
}

// FluidAudio 0.7.9 no longer exposes the older streaming EOU manager used by
// this dormant live-display path. Keep a no-op shim so the disabled code path
// still compiles until we rewire live transcripts to the newer streaming API.
private actor StreamingEouAsrManager {
    enum ChunkSize {
        case ms320
    }

    init(chunkSize: ChunkSize, eouDebounceMs: Int) {}

    func loadModels(modelDir: URL) async throws {}

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {}

    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {}

    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String { "" }

    func reset() async {}
}

enum ParakeetModelState {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}

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

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private var nativeSampleRate: Double = 48000
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
    // Accumulates resampled 16kHz samples between tap callbacks before flushing to EOU.
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

    // FluidAudio ASR
    private var asrManager: AsrManager?
    private var audioWatchdogTask: Task<Void, Never>?
    private var asrManagerReady = false
    private nonisolated(unsafe) var didReceiveAudioSamples = false
    private var cachedInputDeviceName = "Unknown"

    var isModelLoaded: Bool { asrManagerReady }
    var inputDeviceName: String { cachedInputDeviceName }

    init() {
        scheduleInputDeviceNameRefresh()
    }

    nonisolated private static func loadInputDeviceName() -> String {
        do {
            return try CoreAudioInputDeviceLookup.defaultInputDeviceName()
        } catch {
            return "Unknown"
        }
    }

    private func scheduleInputDeviceNameRefresh() {
        Task.detached(priority: .utility) { [weak self] in
            let deviceName = Self.loadInputDeviceName()
            await self?.updateCachedInputDeviceName(deviceName)
        }
    }

    private func updateCachedInputDeviceName(_ deviceName: String) {
        cachedInputDeviceName = deviceName
    }

    private func handleDefaultInputDeviceChange(deviceName: String) {
        cachedInputDeviceName = deviceName
        print("🎤 PARAKEET | default input changed → \(deviceName)")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "default_input_device_changed",
            message: "Default input device changed",
            context: ["audio_device": deviceName]
        )
        handleAudioConfigChange()
    }

    // MARK: - Model Initialization

    /// Load Parakeet models from the app bundle (preferred) or download from HuggingFace (fallback).
    /// Bundle path: Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/
    func initialize() async {
        scheduleInputDeviceNameRefresh()

        guard asrManager == nil else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "already_initialized",
                message: "initialize() called but ASR manager already exists — ignoring")
            return
        }

        switch modelDownloadState {
        case .downloading, .loading:
            return
        case .notLoaded, .ready, .failed:
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
                print("🌐 PARAKEET | models not bundled, downloading (~600MB)...")
                modelDownloadState = .downloading(progress: 0.0)
                let downloadedPath = try await AsrModels.download(version: .v3)
                modelDownloadState = .loading
                print("🌐 PARAKEET | loading downloaded models from: \(downloadedPath.path)")
                models = try await AsrModels.load(from: downloadedPath, version: .v3)
                loadSourceName = loadSource.rawValue
            }

            failureStage = .managerInitialize
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)

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
                let cacheBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("FluidAudio/Models", isDirectory: true)
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

    // MARK: - Pre-warm

    func prewarm() {
        guard !isEnginePrewarmed, !isRecording else { return }
        installAudioObserversIfNeeded()
        scheduleInputDeviceNameRefresh()

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

        do {
            let inputNode = audioEngine.inputNode
            let outputFormat = inputNode.outputFormat(forBus: 0)
            let hwFormat = inputNode.inputFormat(forBus: 0)

            // Validate both formats. AirPods on macOS run input in Hands-Free Profile
            // (24kHz hw / 48kHz output bus); CoreAudio's internal converter handles
            // the upsample and the tap delivers at the output bus rate. Both must be
            // valid before declaring the engine ready — input alone or output alone
            // can transiently report zero during device transitions.
            guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
                  hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "prewarm_invalid_format",
                    message: "Audio format invalid during prewarm",
                    context: [
                        "output_rate": "\(outputFormat.sampleRate)",
                        "output_channels": "\(outputFormat.channelCount)",
                        "hw_rate": "\(hwFormat.sampleRate)",
                        "hw_channels": "\(hwFormat.channelCount)"
                    ])
                schedulePrewarmRetry()
                return
            }

            nativeSampleRate = outputFormat.sampleRate

            audioEngine.prepare()
            try audioEngine.start()
            isEnginePrewarmed = true
            prewarmRetryCount = 0
            markFormatReadyAndPublish()
            print("🔥 PARAKEET | engine pre-warmed (\(inputDeviceName), \(nativeSampleRate)Hz)")
        } catch {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "prewarm_failed",
                message: error.localizedDescription, context: ["audio_device": inputDeviceName])
            schedulePrewarmRetry()
        }
    }

    private func schedulePrewarmRetry() {
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard let self, !self.recoveryState.isStale(generation: capturedGeneration) else { return }
            self.prewarm()
        }
    }

    private func installAudioObserversIfNeeded() {
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: audioEngine,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAudioConfigChange()
                }
            }
        }

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemWake()
                }
            }
        }

        installInputDeviceChangeListenerIfNeeded()
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
                let deviceName = Self.loadInputDeviceName()
                await self?.handleDefaultInputDeviceChange(deviceName: deviceName)
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

    private func handleAudioConfigChange() {
        // Track whether any config change in the current burst interrupted a
        // recording. Once set, subsequent changes in the same burst inherit it.
        if isRecording {
            configChangeWasRecording = true
        }

        // Bump the generation counter and signal UI that engine is recovering.
        // DictationSessionController waits on these flags instead of racing.
        _ = recoveryState.beginConfigChange()
        publishRecoveryState()
        // Fresh device state warrants a fresh retry budget for prewarm.
        prewarmRetryCount = 0

        // Immediately tear down anything that's running — the system has
        // already stopped the engine internally before posting this notification,
        // so the tap and prewarm state are stale.
        cancelAudioWatchdog()

        if isRecording {
            pendingSamplesLock.withLock {
                pendingSamples.removeAll(keepingCapacity: true)
            }
            streamingSamplesLock.withLock { streamingSampleBuffer.removeAll(keepingCapacity: true) }
            Task { await eouManager?.reset() }
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
            audioLevel = 0
        }

        audioEngine.stop()
        isEnginePrewarmed = false

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

        configRecoveryTask = Task { @MainActor [weak self] in
            // Wait for CoreAudio to finish settling the new device graph.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled, let self = self else { return }
            guard !self.recoveryState.isStale(generation: myGeneration) else { return }
            do {
                // Two-step format validation. CoreAudio sometimes reports zero
                // sample rate on first read after device change, even past the
                // initial settle delay. One extra wait + re-read is enough.
                var newFormat = self.audioEngine.inputNode.outputFormat(forBus: 0)
                if newFormat.sampleRate == 0 || newFormat.channelCount == 0 {
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
                    guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                    newFormat = self.audioEngine.inputNode.outputFormat(forBus: 0)
                }
                guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
                    throw NSError(domain: "ParakeetEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid audio format after device change (\(newFormat.sampleRate)Hz, \(newFormat.channelCount)ch)"])
                }
                self.nativeSampleRate = newFormat.sampleRate
                print("🔄 PARAKEET | audio device changed → \(self.inputDeviceName) (\(newFormat.sampleRate)Hz), re-warming")
                self.audioEngine.prepare()
                try self.audioEngine.start()
                self.isEnginePrewarmed = true
                print("🔥 PARAKEET | engine re-warmed after device change")

                guard !Task.isCancelled else { return }
                guard self.recoveryState.finishRecovery(success: true, generation: myGeneration) else { return }
                self.publishRecoveryState()

                // If we were recording, try to restart on the new device.
                // The watchdog (via isRecoveryAttempt=false) catches silent
                // failures where the device looks functional but produces no
                // samples. The watchdog gets one retry before giving up.
                if shouldRestartRecording {
                    var restarted = false
                    for attempt in 1...TranscriptedConstants.recordingRestartAttempts {
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        if self.startRecording() {
                            restarted = true
                            print("✅ PARAKEET | recording recovered on new device (\(self.inputDeviceName)) after \(attempt) attempt(s)")
                            EventReporter.shared.capture(level: .info, engine: "parakeet",
                                event: "recording_recovered_device_change",
                                message: "Recording recovered after device change",
                                context: [
                                    "audio_device": self.inputDeviceName,
                                    "sample_rate": "\(self.nativeSampleRate)",
                                    "attempts": "\(attempt)"
                                ])
                            break
                        }
                        // BT format negotiation can take ~1-2s; wait between attempts.
                        try? await Task.sleep(nanoseconds: TranscriptedConstants.recordingRestartRetryDelay)
                    }
                    if !restarted {
                        self.recordingInterrupted = true
                        EventReporter.shared.capture(level: .warning, engine: "parakeet",
                            event: "recording_interrupted",
                            message: "Recording could not restart after device change within retry budget",
                            context: ["audio_device": self.inputDeviceName])
                    }
                }
            } catch {
                if self.recoveryState.finishRecovery(success: false, generation: myGeneration) {
                    self.publishRecoveryState()
                }
                if shouldRestartRecording {
                    self.recordingInterrupted = true
                    EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "recording_interrupted",
                        message: "Recording interrupted — engine rewarm failed after device change",
                        context: ["audio_device": self.inputDeviceName, "error": error.localizedDescription])
                }
                EventReporter.shared.capture(level: .error, engine: "parakeet",
                    event: "device_change_rewarm_failed",
                    message: error.localizedDescription, context: ["audio_device": self.inputDeviceName])
            }
        }
    }

    private func publishRecoveryState() {
        isRecovering = recoveryState.isRecovering
        inputFormatReady = recoveryState.inputFormatReady
    }

    private func markFormatUnreadyAndPublish() {
        recoveryState.markFormatUnready()
        publishRecoveryState()
    }

    private func markFormatReadyAndPublish() {
        if !recoveryState.inputFormatReady {
            recoveryState.markFormatReady()
            publishRecoveryState()
        }
    }

    private func handleSystemWake() {
        print("🔄 PARAKEET | system wake detected, resetting audio engine")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake",
            message: "System woke from sleep, resetting audio engine",
            context: ["was_recording": "\(isRecording)", "was_prewarmed": "\(isEnginePrewarmed)"])

        let wasRecording = isRecording
        cancelAudioWatchdog()
        if isRecording {
            pendingSamplesLock.withLock {
                pendingSamples.removeAll(keepingCapacity: true)
            }
            streamingSamplesLock.lock()
            streamingSampleBuffer.removeAll(keepingCapacity: true)
            streamingSamplesLock.unlock()
            Task { await eouManager?.reset() }
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
            audioLevel = 0
        }

        audioEngine.stop()
        isEnginePrewarmed = false

        if wasRecording {
            recordingInterrupted = true
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by system sleep/wake")
        }

        // Re-warm after a delay to let audio hardware reinitialize.
        // Retry once if the first attempt fails (CoreAudio may need more time).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRewarmDelay)
            guard let self = self else { return }
            self.prewarm()

            if !self.isEnginePrewarmed {
                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "wake_prewarm_retry",
                    message: "First prewarm after wake failed, retrying in 1s")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.prewarm()
            }
        }
    }

    // MARK: - Recording

    func startRecording(isRecoveryAttempt: Bool = false) -> Bool {
        guard !isRecording else { return true }
        scheduleInputDeviceNameRefresh()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return false
        }

        installAudioObserversIfNeeded()
        recordingInterrupted = false
        didReceiveAudioSamples = false
        cancelAudioWatchdog()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        sampleBuffer.removeAll(keepingCapacity: true)
        sampleBuffer.reserveCapacity(Int(nativeSampleRate * Double(TranscriptedConstants.audioBufferCapacitySeconds)))

        let inputNode = audioEngine.inputNode
        // The tap is installed with format: nil, which means buffers arrive at the
        // node's OUTPUT bus format. On AirPods HFP the hw input is 24kHz but the
        // node's output bus is 48kHz (CoreAudio's internal converter handles the
        // upsample). The downstream resampler must use the rate the buffer
        // actually arrives at — i.e. outputFormat — not the hw rate. Validate
        // both so we don't proceed when the device graph is still settling.
        let outputFormat = inputNode.outputFormat(forBus: 0)
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
              hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            print("⚠️ PARAKEET | input format unavailable: output=\(outputFormat.sampleRate)Hz/\(outputFormat.channelCount)ch hw=\(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch")
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_format_unavailable",
                message: "Audio hardware format not ready while starting dictation",
                context: [
                    "audio_device": inputDeviceName,
                    "output_rate": "\(outputFormat.sampleRate)",
                    "output_channels": "\(outputFormat.channelCount)",
                    "hw_rate": "\(hwFormat.sampleRate)",
                    "hw_channels": "\(hwFormat.channelCount)",
                ]
            )
            audioEngine.stop()
            isEnginePrewarmed = false
            markFormatUnreadyAndPublish()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
                self?.prewarm()
            }
            return false
        }

        nativeSampleRate = outputFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self = self,
                  let monoSamples = self.extractMonoSamples(from: buffer) else { return }
            let frameLength = monoSamples.count
            guard frameLength > 0 else { return }

            if !self.didReceiveAudioSamples && frameLength > 0 {
                self.didReceiveAudioSamples = true
                Task { @MainActor in
                    EventReporter.shared.capture(level: .info, engine: "parakeet", event: "audio_samples_detected",
                        message: "Audio samples started flowing",
                        context: [
                            "audio_device": self.inputDeviceName,
                            "sample_rate": "\(self.nativeSampleRate)",
                            "channels": "\(buffer.format.channelCount)",
                            "frames": "\(frameLength)"
                        ])
                }
            }

            // Consumer 1: optional live streaming display (currently disabled).
            if self.liveDisplayEnabled, let eou = self.eouManager {
                let resampled = AudioResampler.resample(monoSamples, from: self.nativeSampleRate, to: 16000)
                self.streamingSamplesLock.lock()
                self.streamingSampleBuffer.append(contentsOf: resampled)
                var chunk: [Float]? = nil
                if self.streamingSampleBuffer.count >= self.eouChunkSamples {
                    // Swap instead of copy — avoids memcpy under lock
                    chunk = self.streamingSampleBuffer
                    self.streamingSampleBuffer = []
                }
                self.streamingSamplesLock.unlock()
                if let chunk = chunk, let pcm = self.makePCMBuffer(from: chunk) {
                    Task {
                        do { _ = try await eou.process(audioBuffer: pcm) }
                        catch { EventReporter.shared.capture(level: .warning, engine: "parakeet",
                            event: "eou_process_error", message: error.localizedDescription) }
                    }
                }
            }

            // Consumer 2: Parakeet sample buffer — lock-protected
            self.pendingSamplesLock.lock()
            self.pendingSamples.append(contentsOf: monoSamples)
            // Enforce hard cap — keep only the most recent audioBufferCapacitySeconds of audio.
            // Amortized compaction: trim once per second of overflow rather than on every tap
            // callback, to avoid O(n) memmoves at ~47Hz.
            let maxSamples = Int(self.nativeSampleRate) * TranscriptedConstants.audioBufferCapacitySeconds
            if self.pendingSamples.count > maxSamples + Int(self.nativeSampleRate) {
                self.pendingSamples.removeFirst(self.pendingSamples.count - maxSamples)
            }
            self.pendingSamplesLock.unlock()

            // Consumer 3: Audio level metering (~20Hz throttled)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastLevelUpdate > TranscriptedConstants.audioMeteringInterval else { return }
            self.lastLevelUpdate = now

            var sumOfSquares: Float = 0
            for sample in monoSamples {
                let s = sample
                sumOfSquares += s * s
            }
            let rms = sqrt(sumOfSquares / Float(max(1, frameLength)))
            let dB = rms > 0.0001 ? 20.0 * log10(rms) : -60.0
            let normalized = max(0.0, min(1.0, (dB - TranscriptedConstants.audioLevelFloorDB) / (TranscriptedConstants.audioLevelCeilingDB - TranscriptedConstants.audioLevelFloorDB)))

            Task { @MainActor [weak self] in
                self?.audioLevel = normalized
            }
        }

        if !isEnginePrewarmed || !audioEngine.isRunning {
            do {
                if !audioEngine.isRunning && isEnginePrewarmed {
                    print("🔄 PARAKEET | engine was prewarmed but not running (likely sleep/wake), restarting")
                    EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "engine_stale_restart",
                        message: "Audio engine was prewarmed but not running — restarting",
                        context: ["audio_device": inputDeviceName])
                }
                audioEngine.prepare()
                try audioEngine.start()
                isEnginePrewarmed = true
            } catch {
                inputNode.removeTap(onBus: 0)  // Clean up tap to prevent double-install crash
                print("❌ PARAKEET | audio engine failed: \(error.localizedDescription)")
                EventReporter.shared.capture(level: .error, engine: "parakeet",
                    event: "audio_engine_start_failed", message: error.localizedDescription)
                return false
            }
        }

        isRecording = true
        markFormatReadyAndPublish()
        liveTranscript = ""
        committedStreamText = ""
        if liveDisplayEnabled {
            streamingSamplesLock.lock()
            streamingSampleBuffer.removeAll(keepingCapacity: true)
            streamingSamplesLock.unlock()
            Task { await eouManager?.reset() }
        }
        print("🎤 PARAKEET | recording started (\(inputDeviceName), \(nativeSampleRate)Hz)")

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

            // Full teardown
            self.streamingSamplesLock.withLock {
                self.streamingSampleBuffer.removeAll(keepingCapacity: true)
            }
            self.pendingSamplesLock.withLock {
                self.pendingSamples.removeAll(keepingCapacity: true)
            }
            await self.eouManager?.reset()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
            self.isEnginePrewarmed = false
            self.isRecording = false
            self.audioLevel = 0

            // Brief delay for hardware to reinitialize
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled else { return }

            // Retry once — isRecoveryAttempt prevents another watchdog
            if self.startRecording(isRecoveryAttempt: true) {
                print("✅ PARAKEET | zombie engine recovered — recording restarted")
                EventReporter.shared.capture(level: .info, engine: "parakeet", event: "zombie_engine_recovered",
                    message: "Audio engine recovered after reset")
            } else {
                print("❌ PARAKEET | zombie engine recovery failed")
                EventReporter.shared.capture(level: .error, engine: "parakeet", event: "zombie_engine_recovery_failed",
                    message: "Audio engine could not recover after reset",
                    context: ["audio_device": self.inputDeviceName])
                self.recordingInterrupted = true
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        cancelAudioWatchdog()
        if liveDisplayEnabled {
            streamingSamplesLock.lock()
            let remainingEou: [Float] = streamingSampleBuffer
            streamingSampleBuffer.removeAll(keepingCapacity: true)
            streamingSamplesLock.unlock()
            if let eou = eouManager, !remainingEou.isEmpty, let pcm = makePCMBuffer(from: remainingEou) {
                Task {
                    do { _ = try await eou.process(audioBuffer: pcm) }
                    catch { EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "eou_process_error", message: error.localizedDescription) }
                }
            }
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        pendingSamplesLock.lock()
        sampleBuffer.append(contentsOf: pendingSamples)
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesLock.unlock()
        isRecording = false
        audioLevel = 0
        print("⏹️ PARAKEET | recording stopped (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / nativeSampleRate))s)")
    }

    // MARK: - EOU Streaming (live display)
    // Live display is driven by StreamingEouAsrManager fed via the audio tap (see startRecording).
    // EOU callback in initializeEouModel() updates committedStreamText → liveTranscript.
    // No explicit start/stop methods needed — tap feeds the manager, reset() clears state.

    /// Convert [Float] samples to AVAudioPCMBuffer for StreamingEouAsrManager.
    private func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = eouPCMFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dest = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dest.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    // MARK: - Transcription

    func transcribe() async -> String? {
        guard !isTranscribing else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress")
            return nil
        }
        pendingSamplesLock.withLock {
            sampleBuffer.append(contentsOf: pendingSamples)
            pendingSamples.removeAll(keepingCapacity: true)
        }
        guard !sampleBuffer.isEmpty else {
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
        // Swap instead of copy — moves data out of sampleBuffer without allocating a duplicate.
        // sampleBuffer is cleared immediately, freeing capacity before resampling.
        var samples: [Float] = []
        swap(&samples, &sampleBuffer)
        let inputRate = nativeSampleRate

        let startTime = CFAbsoluteTimeGetCurrent()

        // Resample to 16kHz for Parakeet inference, then free the native-rate buffer
        // before inference — avoids holding both the raw and resampled arrays simultaneously.
        let nativeCount = samples.count
        let resampled = AudioResampler.resample(samples, from: inputRate, to: 16000)
        samples.removeAll()
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
            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)
            return nil
        }

        do {
            let result = try await manager.transcribe(resampled, source: .microphone)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            let audioDuration = Double(resampled.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
            print("✅ PARAKEET | transcribed in \(String(format: "%.2f", elapsed))s: \"\(trimmed.prefix(80))...\"")

            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)

            if trimmed.isEmpty {
                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_empty",
                    message: "Parakeet returned no text after \(String(format: "%.1f", elapsed))s inference",
                    context: ["samples": "\(nativeCount)"])
                return nil
            }

            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_complete",
                message: "Transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.1f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(trimmed.count)",
                    "input_samples": "\(nativeCount)",
                ])
            return trimmed
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
                isTranscribing = false
                sampleBuffer.removeAll(keepingCapacity: true)
                return nil
            }

            print("❌ PARAKEET | transcription failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "transcription_failed",
                message: error.localizedDescription,
                context: ["samples": "\(nativeCount)", "elapsed": String(format: "%.2f", elapsed)])
            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)
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
            let result = try await manager.transcribe(samples, source: source)
            resultText = result.text
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

        let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
        let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "meeting_segment_transcribed",
            message: "Meeting segment transcribed in \(String(format: "%.2f", elapsed))s",
            context: [
                "elapsed_s": String(format: "%.3f", elapsed),
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "rtf": String(format: "%.3f", rtf),
                "chars": "\(trimmed.count)",
            ])

        return trimmed
    }

    // MARK: - Cleanup

    func cancel() {
        cancelAudioWatchdog()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        if isRecording {
            if liveDisplayEnabled {
                streamingSamplesLock.lock()
                streamingSampleBuffer.removeAll(keepingCapacity: true)
                streamingSamplesLock.unlock()
                Task { await eouManager?.reset() }
            }
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
            audioLevel = 0
        }
        sampleBuffer.removeAll()
        isTranscribing = false
        liveTranscript = ""
        committedStreamText = ""
    }

    private func cancelAudioWatchdog() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
    }

    func cleanup() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        removeInputDeviceChangeListener()
        let mgr = asrManager
        asrManager = nil
        asrManagerReady = false
        eouManager = nil
        modelDownloadState = .notLoaded
        Task { mgr?.cleanup() }
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        unregisterDefaultInputDeviceListener(inputDeviceChangeListener)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let mgr = asrManager
        Task { mgr?.cleanup() }
        eouManager = nil
    }
}
