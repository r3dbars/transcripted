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

enum ParakeetModelState {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}

enum RecordingInterruptionReason: String {
    case audioDeviceChanged = "audio_device_changed"
    case systemWake = "system_wake"
    case recoveryFailed = "recovery_failed"
}

@MainActor
class ParakeetEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var liveTranscript: String = ""
    @Published var modelDownloadState: ParakeetModelState = .notLoaded
    @Published var recordingInterrupted = false
    @Published var interruptionReason: RecordingInterruptionReason?

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private var nativeSampleRate: Double = 48000
    private var recordedSampleRate: Double?
    private let pendingSamplesLock = NSLock()
    private var pendingSamples: [Float] = []
    private nonisolated(unsafe) var lastLevelUpdate: CFAbsoluteTime = 0
    private var isEnginePrewarmed = false
    private var wakeObserver: NSObjectProtocol?

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

    // FluidAudio ASR
    private var asrManager: AsrManager?
    private var initializeTask: Task<Void, Never>?
    private var audioWatchdogTask: Task<Void, Never>?
    private var pendingRecoveryTask: Task<Void, Never>?
    private var asrManagerReady = false
    // Written true by the audio tap callback (audio thread); reset false in startRecording()
    // before installTap(), so no write-write race. Matches the nonisolated(unsafe) pattern
    // used for lastLevelUpdate and eouManager.
    private nonisolated(unsafe) var didReceiveAudioSamples = false

    var isModelLoaded: Bool { asrManagerReady }

    var inputDeviceName: String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return "Unknown" }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        guard nameStatus == noErr, (name as String).count > 0 else { return "Unknown" }
        return name as String
    }

    // MARK: - Model Initialization

    /// Load Parakeet models from the app bundle (preferred) or download from HuggingFace (fallback).
    /// Bundle path: Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/
    func initialize() async {
        if let initializeTask {
            await initializeTask.value
            return
        }
        guard asrManager == nil else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "already_initialized",
                message: "initialize() called but ASR manager already exists — ignoring")
            return
        }

        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialize()
        }
        initializeTask = task
        await task.value
        initializeTask = nil
    }

    private func performInitialize() async {
        guard asrManager == nil else { return }

        // Request microphone permission early so it's granted before first recording
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            print("🎤 PARAKEET | microphone permission \(granted ? "granted" : "denied")")
        }

        modelDownloadState = .loading
        print("🔄 PARAKEET | initializing models...")

        do {
            let models: AsrModels
            let loadSource: String

            // Try loading from app bundle first (bundled by build.sh)
            if let bundlePath = bundledModelPath(subdirectory: "parakeet-tdt-0.6b-v3-coreml", checkFile: "Encoder.mlmodelc") {
                print("📦 PARAKEET | loading from bundle: \(bundlePath.path)")
                models = try await AsrModels.load(from: bundlePath, version: .v3)
                loadSource = "bundle"
            } else {
                // Fallback: download from HuggingFace (~600MB on first run)
                print("🌐 PARAKEET | models not bundled, downloading (~600MB)...")
                modelDownloadState = .downloading(progress: 0.0)
                models = try await AsrModels.downloadAndLoad(version: .v3) { [weak self] progress in
                    Task { @MainActor in
                        self?.modelDownloadState = .downloading(progress: progress.fractionCompleted)
                        switch progress.phase {
                        case .listing:
                            print("🌐 PARAKEET | listing model files...")
                        case .downloading(let completed, let total):
                            print("🌐 PARAKEET | downloading \(completed)/\(total) files (\(Int(progress.fractionCompleted * 100))%)...")
                        case .compiling(let name):
                            print("🌐 PARAKEET | compiling \(name)...")
                        }
                    }
                }
                loadSource = "download"
            }

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)

            asrManager = manager
            asrManagerReady = true
            modelDownloadState = .ready
            print("✅ PARAKEET | TDT V3 models loaded (source: \(loadSource))")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "models_loaded",
                message: "Parakeet ASR models initialized successfully",
                context: ["load_source": loadSource])

            if liveDisplayEnabled {
                await initializeEouModel()
            }

        } catch {
            modelDownloadState = .failed(error.localizedDescription)
            print("❌ PARAKEET | model initialization failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "model_init_failed",
                message: error.localizedDescription)
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
                    print("🌐 PARAKEET EOU | downloading streaming model (~120MB)...")
                    let modelNames = ["streaming_encoder", "decoder", "joint_decision"]
                    _ = try await DownloadUtils.loadModels(
                        .parakeetEou320,
                        modelNames: modelNames,
                        directory: cacheBase
                    )
                    print("✅ PARAKEET EOU | download complete")
                    modelDir = expectedDir
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
        do {
            let inputNode = audioEngine.inputNode
            let nativeFormat = inputNode.outputFormat(forBus: 0)

            // Validate audio format — after sleep, the input node may return a zero-rate
            // format if CoreAudio hardware hasn't fully reinitialized.
            guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "prewarm_invalid_format",
                    message: "Audio format invalid during prewarm",
                    context: ["sample_rate": "\(nativeFormat.sampleRate)", "channels": "\(nativeFormat.channelCount)"])
                return
            }

            nativeSampleRate = nativeFormat.sampleRate

            audioEngine.prepare()
            try audioEngine.start()
            isEnginePrewarmed = true
            print("🔥 PARAKEET | engine pre-warmed (\(inputDeviceName), \(nativeSampleRate)Hz)")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "prewarm_succeeded",
                message: "Audio engine pre-warmed",
                context: ["audio_device": inputDeviceName, "sample_rate": "\(nativeSampleRate)"])

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
        } catch {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "prewarm_failed",
                message: error.localizedDescription, context: ["audio_device": inputDeviceName])
        }
    }

    private func handleAudioConfigChange() {
        let wasRecording = isRecording
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        cancelPendingRecovery()

        if isRecording {
            streamingSamplesLock.withLock { streamingSampleBuffer.removeAll(keepingCapacity: true) }
            Task { await eouManager?.reset() }
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
            audioLevel = 0
        }

        audioEngine.stop()
        isEnginePrewarmed = false

        // Always interrupt if a recording was active — don't try to auto-restart.
        // The new audio pipeline may look functional but silently produce no samples
        // (e.g., USB dock unplug), leaving the overlay stuck in listening state.
        if wasRecording {
            interruptionReason = .audioDeviceChanged
            recordingInterrupted = true
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by device change", context: ["audio_device": inputDeviceName])
        }

        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "audio_device_change_detected",
            message: "Audio configuration changed",
            context: ["audio_device": inputDeviceName, "was_recording": "\(wasRecording)"])

        scheduleRecovery(
            after: TranscriptedConstants.audioRecoveryDelay,
            event: "device_change_rewarm_failed",
            retryDelay: nil
        )
    }

    private func handleSystemWake() {
        print("🔄 PARAKEET | system wake detected, resetting audio engine")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake",
            message: "System woke from sleep, resetting audio engine",
            context: ["was_recording": "\(isRecording)", "was_prewarmed": "\(isEnginePrewarmed)"])

        let wasRecording = isRecording
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        cancelPendingRecovery()
        if isRecording {
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
            interruptionReason = .systemWake
            recordingInterrupted = true
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by system sleep/wake")
        }

        scheduleRecovery(
            after: TranscriptedConstants.audioRewarmDelay,
            event: "wake_prewarm_failed",
            retryDelay: 1_000_000_000
        )
    }

    // MARK: - Recording

    func startRecording(isRecoveryAttempt: Bool = false) -> Bool {
        guard !isRecording else { return true }
        guard pendingRecoveryTask == nil else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_blocked_recovery",
                message: "startRecording() called while audio recovery was still in progress",
                context: ["audio_device": inputDeviceName])
            return false
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return false
        }

        recordingInterrupted = false
        interruptionReason = nil
        didReceiveAudioSamples = false
        resetBufferedAudio()
        sampleBuffer.reserveCapacity(Int(nativeSampleRate * Double(TranscriptedConstants.audioBufferCapacitySeconds)))

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard isValidAudioFormat(nativeFormat) else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_invalid_format",
                message: "Audio format invalid during startRecording",
                context: ["sample_rate": "\(nativeFormat.sampleRate)", "channels": "\(nativeFormat.channelCount)"])
            scheduleRecovery(
                after: TranscriptedConstants.audioRecoveryDelay,
                event: "start_recording_rewarm_failed",
                retryDelay: nil
            )
            return false
        }
        nativeSampleRate = nativeFormat.sampleRate
        recordedSampleRate = nativeSampleRate

        // After sleep/wake, the output format and hardware input format can
        // desync — outputFormat reports one rate while the hardware runs at
        // another. installTap asserts they match. Detect and fix by
        // restarting the engine so CoreAudio rebuilds the graph.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        if nativeFormat.sampleRate != hwFormat.sampleRate && hwFormat.sampleRate > 0 {
            print("⚠️ PARAKEET | format mismatch: output=\(nativeFormat.sampleRate)Hz hw=\(hwFormat.sampleRate)Hz — resyncing engine")
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "format_mismatch_resync",
                message: "Output/hardware sample rate mismatch after wake",
                context: ["output_rate": "\(nativeFormat.sampleRate)", "hw_rate": "\(hwFormat.sampleRate)"])
            audioEngine.stop()
            isEnginePrewarmed = false
            audioEngine.prepare()
            do {
                try audioEngine.start()
                isEnginePrewarmed = true
            } catch {
                EventReporter.shared.capture(level: .error, engine: "parakeet", event: "resync_engine_failed",
                    message: error.localizedDescription)
                return false
            }
            // Re-read both formats after engine restart and refuse to install a
            // tap until CoreAudio reports a stable, matching hardware graph.
            let refreshedOutputFormat = inputNode.outputFormat(forBus: 0)
            let refreshedHardwareFormat = inputNode.inputFormat(forBus: 0)
            nativeSampleRate = refreshedOutputFormat.sampleRate

            guard refreshedOutputFormat.sampleRate > 0, refreshedHardwareFormat.sampleRate > 0 else {
                EventReporter.shared.capture(level: .warning, engine: "parakeet",
                    event: "format_mismatch_retry_needed",
                    message: "Audio hardware still settling after device change",
                    context: [
                        "output_rate": "\(refreshedOutputFormat.sampleRate)",
                        "hw_rate": "\(refreshedHardwareFormat.sampleRate)"
                    ])
                audioEngine.stop()
                isEnginePrewarmed = false
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
                    self?.prewarm()
                }
                return false
            }

            guard refreshedOutputFormat.sampleRate == refreshedHardwareFormat.sampleRate else {
                print("⚠️ PARAKEET | format mismatch persisted after resync: output=\(refreshedOutputFormat.sampleRate)Hz hw=\(refreshedHardwareFormat.sampleRate)Hz")
                EventReporter.shared.capture(level: .warning, engine: "parakeet",
                    event: "format_mismatch_retry_needed",
                    message: "Audio format mismatch persisted after engine resync",
                    context: [
                        "output_rate": "\(refreshedOutputFormat.sampleRate)",
                        "hw_rate": "\(refreshedHardwareFormat.sampleRate)"
                    ])
                audioEngine.stop()
                isEnginePrewarmed = false
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
                    self?.prewarm()
                }
                return false
            }
        }

        guard nativeSampleRate > 0 else {
            print("❌ PARAKEET | sample rate is 0 — audio hardware not ready")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "zero_sample_rate",
                message: "Sample rate is 0, audio hardware not initialized")
            return false
        }

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeSampleRate, channels: 1) else {
            print("❌ PARAKEET | failed to create mono audio format at \(nativeSampleRate)Hz")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "audio_format_failed",
                message: "AVAudioFormat creation failed", context: ["sample_rate": "\(nativeSampleRate)"])
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: monoFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            if !self.didReceiveAudioSamples && frameLength > 0 {
                self.didReceiveAudioSamples = true
                Task { @MainActor in
                    EventReporter.shared.capture(level: .info, engine: "parakeet", event: "audio_samples_detected",
                        message: "Audio samples started flowing",
                        context: [
                            "audio_device": self.inputDeviceName,
                            "sample_rate": "\(self.nativeSampleRate)",
                            "frames": "\(frameLength)"
                        ])
                }
            }

            // Consumer 1: optional live streaming display (currently disabled).
            if self.liveDisplayEnabled, let eou = self.eouManager {
                let rawSamples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                let resampled = AudioResampler.resample(rawSamples, from: self.nativeSampleRate, to: 16000)
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
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            self.pendingSamplesLock.lock()
            self.pendingSamples.append(contentsOf: samples)
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
            for i in 0..<frameLength {
                let s = channelData[i]
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
        liveTranscript = ""
        committedStreamText = ""
        if liveDisplayEnabled {
            streamingSamplesLock.lock()
            streamingSampleBuffer.removeAll(keepingCapacity: true)
            streamingSamplesLock.unlock()
            Task { await eouManager?.reset() }
        }
        print("🎤 PARAKEET | recording started (\(inputDeviceName), \(nativeSampleRate)Hz)")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "recording_started",
            message: "Recording started",
            context: [
                "audio_device": inputDeviceName,
                "sample_rate": "\(nativeSampleRate)",
                "recovery_attempt": "\(isRecoveryAttempt)"
            ])

        // Watchdog: detect zombie audio engine (running but no samples flowing after sleep/wake).
        // Only on first attempt — recovery attempt doesn't re-watchdog to prevent infinite loops.
        if !isRecoveryAttempt {
            startAudioWatchdog()
        }

        return true
    }

    /// Watchdog that detects zombie audio engines — running but producing no samples.
    /// After sleep/wake, CoreAudio may report the engine as running but the hardware graph
    /// is disconnected. If no samples arrive within 2 seconds, tear down and retry once.
    private func startAudioWatchdog() {
        audioWatchdogTask?.cancel()
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
            await self.eouManager?.reset()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
            self.isEnginePrewarmed = false
            self.isRecording = false
            self.audioLevel = 0
            self.resetBufferedAudio()

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
                self.interruptionReason = .recoveryFailed
                self.recordingInterrupted = true
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        cancelPendingRecovery()
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
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
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "recording_stopped",
            message: "Recording stopped",
            context: [
                "audio_device": inputDeviceName,
                "sample_count": "\(sampleBuffer.count)",
                "duration_s": String(format: "%.1f", Double(sampleBuffer.count) / nativeSampleRate)
            ])
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
        let inputRate = recordedSampleRate ?? nativeSampleRate

        let startTime = CFAbsoluteTimeGetCurrent()

        // Resample to 16kHz for Parakeet inference, then free the native-rate buffer
        // before inference — avoids holding both the raw and resampled arrays simultaneously.
        let nativeCount = samples.count
        let resampled = AudioResampler.resample(samples, from: inputRate, to: 16000)
        samples.removeAll()
        print("🔄 PARAKEET | resampled \(nativeCount) → \(resampled.count) samples")

        do {
            let result = try await manager.transcribe(resampled, source: .microphone)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            let audioDuration = Double(resampled.count) / 16000.0
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
            print("✅ PARAKEET | transcribed in \(String(format: "%.2f", elapsed))s: \"\(trimmed.prefix(80))...\"")

            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)
            recordedSampleRate = nil

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
            print("❌ PARAKEET | transcription failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "transcription_failed",
                message: error.localizedDescription,
                context: ["samples": "\(nativeCount)", "elapsed": String(format: "%.2f", elapsed)])
            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)
            recordedSampleRate = nil
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

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await manager.transcribe(samples, source: source)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let audioDuration = Double(samples.count) / 16000.0
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
        cancelPendingRecovery()
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
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
        resetBufferedAudio(keepingCapacity: false)
        recordedSampleRate = nil
        isTranscribing = false
        liveTranscript = ""
        committedStreamText = ""
    }

    func cleanup() {
        cancelPendingRecovery()
        initializeTask?.cancel()
        initializeTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        let mgr = asrManager
        asrManager = nil
        asrManagerReady = false
        eouManager = nil
        modelDownloadState = .notLoaded
        Task { await mgr?.cleanup() }
    }

    deinit {
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
        initializeTask?.cancel()
        initializeTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let mgr = asrManager
        Task { await mgr?.cleanup() }
        eouManager = nil
    }

    private func isValidAudioFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func cancelPendingRecovery() {
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
    }

    private func resetBufferedAudio(keepingCapacity: Bool = true) {
        if keepingCapacity {
            sampleBuffer.removeAll(keepingCapacity: true)
        } else {
            sampleBuffer.removeAll()
        }
        pendingSamplesLock.withLock {
            if keepingCapacity {
                pendingSamples.removeAll(keepingCapacity: true)
            } else {
                pendingSamples.removeAll()
            }
        }
    }

    private func scheduleRecovery(after delay: UInt64, event: String, retryDelay: UInt64?) {
        cancelPendingRecovery()
        pendingRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            if self.isRecording || self.isEnginePrewarmed {
                self.pendingRecoveryTask = nil
                return
            }

            if self.rewarmEngine() {
                self.pendingRecoveryTask = nil
                return
            }

            if let retryDelay {
                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "wake_prewarm_retry",
                    message: "First prewarm after wake failed, retrying in 1s")
                try? await Task.sleep(nanoseconds: retryDelay)
                guard !Task.isCancelled else { return }
                if self.rewarmEngine() {
                    self.pendingRecoveryTask = nil
                    return
                }
            }

            EventReporter.shared.capture(level: .error, engine: "parakeet", event: event,
                message: "Audio engine re-warm failed",
                context: ["audio_device": self.inputDeviceName])
            self.pendingRecoveryTask = nil
        }
    }

    private func rewarmEngine() -> Bool {
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard isValidAudioFormat(inputFormat) else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "rewarm_invalid_format",
                message: "Audio format invalid during recovery re-warm",
                context: ["sample_rate": "\(inputFormat.sampleRate)", "channels": "\(inputFormat.channelCount)"])
            return false
        }

        nativeSampleRate = inputFormat.sampleRate
        do {
            print("🔄 PARAKEET | re-warming audio engine (\(inputDeviceName), \(inputFormat.sampleRate)Hz)")
            audioEngine.prepare()
            try audioEngine.start()
            isEnginePrewarmed = true
            print("🔥 PARAKEET | engine re-warmed")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "rewarm_succeeded",
                message: "Audio engine re-warmed",
                context: ["audio_device": inputDeviceName, "sample_rate": "\(inputFormat.sampleRate)"])
            return true
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "rewarm_attempt_failed",
                message: error.localizedDescription,
                context: ["audio_device": inputDeviceName])
            return false
        }
    }
}
