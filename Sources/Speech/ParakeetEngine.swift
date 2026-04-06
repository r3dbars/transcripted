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

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private var nativeSampleRate: Double = 48000
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

    // FluidAudio ASR
    private var asrManager: AsrManager?
    private var audioWatchdogTask: Task<Void, Never>?
    private var asrManagerReady = false

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
        guard asrManager == nil else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "already_initialized",
                message: "initialize() called but ASR manager already exists — ignoring")
            return
        }

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
        guard isEnginePrewarmed else { return }

        let wasRecording = isRecording

        // Stop the engine FIRST — disconnects from hardware before we touch
        // inputNode. When a USB device is yanked, accessing audioEngine.inputNode
        // while the hardware graph is partially torn down can throw an ObjC
        // exception that the system swallows, corrupting heap metadata.
        audioEngine.stop()
        isEnginePrewarmed = false

        if wasRecording {
            streamingSamplesLock.lock()
            streamingSampleBuffer.removeAll(keepingCapacity: true)
            streamingSamplesLock.unlock()
            Task { await eouManager?.reset() }
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
            audioLevel = 0
        }

        // Always interrupt if a recording was active — don't try to auto-restart.
        // The new audio pipeline may look functional but silently produce no samples
        // (e.g., USB dock unplug), leaving the overlay stuck in listening state.
        if wasRecording {
            recordingInterrupted = true
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by device change", context: ["audio_device": inputDeviceName])
        }

        // Re-warm the engine on the new device after a brief delay to let
        // CoreAudio finish tearing down the old device graph. Without this,
        // accessing inputNode immediately can throw an ObjC exception that
        // kills the process without a crash report.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: DraftConstants.audioRecoveryDelay)
            guard let self = self else { return }
            do {
                let newFormat = self.audioEngine.inputNode.outputFormat(forBus: 0)
                self.nativeSampleRate = newFormat.sampleRate
                print("🔄 PARAKEET | audio device changed → \(self.inputDeviceName) (\(newFormat.sampleRate)Hz), re-warming")
                self.audioEngine.prepare()
                try self.audioEngine.start()
                self.isEnginePrewarmed = true
                print("🔥 PARAKEET | engine re-warmed after device change")
            } catch {
                EventReporter.shared.capture(level: .error, engine: "parakeet", event: "device_change_rewarm_failed",
                    message: error.localizedDescription, context: ["audio_device": self.inputDeviceName])
            }
        }
    }

    private func handleSystemWake() {
        print("🔄 PARAKEET | system wake detected, resetting audio engine")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake",
            message: "System woke from sleep, resetting audio engine",
            context: ["was_recording": "\(isRecording)", "was_prewarmed": "\(isEnginePrewarmed)"])

        let wasRecording = isRecording
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
            recordingInterrupted = true
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by system sleep/wake")
        }

        // Re-warm after a delay to let audio hardware reinitialize.
        // Retry once if the first attempt fails (CoreAudio may need more time).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: DraftConstants.audioRewarmDelay)
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
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return false
        }

        recordingInterrupted = false
        sampleBuffer.removeAll(keepingCapacity: true)
        sampleBuffer.reserveCapacity(Int(nativeSampleRate * Double(DraftConstants.audioBufferCapacitySeconds)))

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        nativeSampleRate = nativeFormat.sampleRate

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeSampleRate, channels: 1) else {
            print("❌ PARAKEET | failed to create mono audio format at \(nativeSampleRate)Hz")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "audio_format_failed",
                message: "AVAudioFormat creation failed", context: ["sample_rate": "\(nativeSampleRate)"])
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: DraftConstants.audioTapBufferSize, format: monoFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

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
            let maxSamples = Int(self.nativeSampleRate) * DraftConstants.audioBufferCapacitySeconds
            if self.pendingSamples.count > maxSamples + Int(self.nativeSampleRate) {
                self.pendingSamples.removeFirst(self.pendingSamples.count - maxSamples)
            }
            self.pendingSamplesLock.unlock()

            // Consumer 3: Audio level metering (~20Hz throttled)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastLevelUpdate > DraftConstants.audioMeteringInterval else { return }
            self.lastLevelUpdate = now

            var sumOfSquares: Float = 0
            for i in 0..<frameLength {
                let s = channelData[i]
                sumOfSquares += s * s
            }
            let rms = sqrt(sumOfSquares / Float(max(1, frameLength)))
            let dB = rms > 0.0001 ? 20.0 * log10(rms) : -60.0
            let normalized = max(0.0, min(1.0, (dB - DraftConstants.audioLevelFloorDB) / (DraftConstants.audioLevelCeilingDB - DraftConstants.audioLevelFloorDB)))

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
            try? await Task.sleep(nanoseconds: DraftConstants.audioWatchdogTimeout)
            guard let self = self, self.isRecording, !Task.isCancelled else { return }

            self.pendingSamplesLock.lock()
            // Re-check isRecording after lock — recording may have stopped between
            // the guard above and lock acquisition
            guard self.isRecording else {
                self.pendingSamplesLock.unlock()
                return
            }
            let sampleCount = self.pendingSamples.count + self.sampleBuffer.count
            self.pendingSamplesLock.unlock()

            guard sampleCount == 0 else { return }  // Audio is flowing — all good

            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "zombie_engine_detected",
                message: "No audio samples received after recording start — resetting engine",
                context: ["audio_device": self.inputDeviceName])

            // Full teardown
            self.streamingSamplesLock.lock()
            self.streamingSampleBuffer.removeAll(keepingCapacity: true)
            self.streamingSamplesLock.unlock()
            await self.eouManager?.reset()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
            self.isEnginePrewarmed = false
            self.isRecording = false
            self.audioLevel = 0

            // Brief delay for hardware to reinitialize
            try? await Task.sleep(nanoseconds: DraftConstants.audioRecoveryDelay)
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
        pendingSamplesLock.lock()
        sampleBuffer.append(contentsOf: pendingSamples)
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesLock.unlock()
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

        do {
            let result = try await manager.transcribe(resampled, source: .microphone)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            let audioDuration = Double(resampled.count) / 16000.0
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
    /// once per segment. This is distinct from Draft's drafting flow, which uses
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
        sampleBuffer.removeAll()
        isTranscribing = false
        liveTranscript = ""
        committedStreamText = ""
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
        let mgr = asrManager
        asrManager = nil
        asrManagerReady = false
        eouManager = nil
        modelDownloadState = .notLoaded
        Task { await mgr?.cleanup() }
    }

    deinit {
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
}
