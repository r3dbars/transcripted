// ParakeetEngine.swift
// FluidAudio-based STT engine — CoreML Parakeet TDT V3 for fast, accurate transcription.
// AVAudioEngine tap → NSLock-batched samples → resampled to 16kHz → AsrManager.transcribe()
// for batch inference. Live Apple Speech provides display-only streaming text.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import FluidAudio
import Foundation
import Speech

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

    // Live Apple Speech (display-only — Parakeet owns the final transcript)
    private var committedLiveText: String = ""
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private var isLiveSpeechActive = false
    private var liveRestartCount = 0
    private var liveRestartWindowStart: CFAbsoluteTime = 0
    private var configChangeObserver: NSObjectProtocol?

    // FluidAudio ASR
    private var asrManager: AsrManager?
    private var initTask: Task<Void, Never>?

    var isModelLoaded: Bool { asrManager?.isAvailable ?? false }

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
            print("⚠️ PARAKEET | already initialized")
            return
        }

        modelDownloadState = .loading
        print("🔄 PARAKEET | initializing models...")

        do {
            let models: AsrModels
            let loadSource: String

            // Try loading from app bundle first (bundled by build.sh)
            if let bundlePath = bundledModelsPath() {
                print("📦 PARAKEET | loading from bundle: \(bundlePath.path)")
                models = try await AsrModels.load(from: bundlePath, version: .v3)
                loadSource = "bundle"
            } else {
                // Fallback: download from HuggingFace (~600MB on first run)
                print("🌐 PARAKEET | models not bundled, downloading (~600MB)...")
                modelDownloadState = .downloading(progress: 0.0)
                models = try await AsrModels.downloadAndLoad(version: .v3)
                loadSource = "download"
            }

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)

            asrManager = manager
            modelDownloadState = .ready
            print("✅ PARAKEET | models loaded and ready (source: \(loadSource))")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "models_loaded",
                message: "Parakeet ASR models initialized successfully",
                context: ["load_source": loadSource])
        } catch {
            modelDownloadState = .failed(error.localizedDescription)
            print("❌ PARAKEET | model initialization failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "model_init_failed",
                message: error.localizedDescription)
        }
    }

    /// Check for Parakeet models bundled inside the app at build time.
    /// Expected layout: Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/
    private func bundledModelsPath() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("parakeet-models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        // Verify the encoder model exists (it's the largest and most critical)
        let encoderPath = path.appendingPathComponent("Encoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: encoderPath.path) else { return nil }
        return path
    }

    // MARK: - Pre-warm

    func prewarm() {
        guard !isEnginePrewarmed, !isRecording else { return }
        do {
            let inputNode = audioEngine.inputNode
            let nativeFormat = inputNode.outputFormat(forBus: 0)
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
            print("⚠️ PARAKEET | prewarm failed: \(error.localizedDescription)")
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
            stopLiveSpeech()
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
                print("⚠️ PARAKEET | re-warm failed: \(error.localizedDescription)")
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
            stopLiveSpeech()
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

        // Re-warm after a brief delay to let audio hardware reinitialize
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: DraftConstants.audioRewarmDelay)
            self?.prewarm()
        }
    }

    // MARK: - Recording

    func startRecording() -> Bool {
        guard !isRecording else { return true }
        guard isModelLoaded else {
            print("⚠️ PARAKEET | cannot start recording — model not loaded")
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "model_not_loaded",
                message: "Recording attempted without model loaded")
            return false
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            print("⚠️ PARAKEET | microphone permission not granted (status: \(micStatus.rawValue))")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return false
        }

        recordingInterrupted = false
        sampleBuffer.removeAll(keepingCapacity: true)
        sampleBuffer.reserveCapacity(Int(nativeSampleRate * 120))

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        nativeSampleRate = nativeFormat.sampleRate

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeSampleRate, channels: 1) else {
            print("❌ PARAKEET | failed to create mono audio format at \(nativeSampleRate)Hz")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "audio_format_failed",
                message: "AVAudioFormat creation failed", context: ["sample_rate": "\(nativeSampleRate)"])
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: monoFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // Consumer 1: Apple Speech (live display)
            self.liveRequest?.append(buffer)

            // Consumer 2: Parakeet sample buffer — lock-protected
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            self.pendingSamplesLock.lock()
            self.pendingSamples.append(contentsOf: samples)
            self.pendingSamplesLock.unlock()

            // Consumer 3: Audio level metering (~20Hz throttled)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastLevelUpdate > 0.05 else { return }
            self.lastLevelUpdate = now

            var sumOfSquares: Float = 0
            for i in 0..<frameLength {
                let s = channelData[i]
                sumOfSquares += s * s
            }
            let rms = sqrt(sumOfSquares / Float(max(1, frameLength)))
            let dB = rms > 0.0001 ? 20.0 * log10(rms) : -60.0
            let floorDB: Float = -50.0
            let ceilDB: Float = -6.0
            let normalized = max(0.0, min(1.0, (dB - floorDB) / (ceilDB - floorDB)))

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
        committedLiveText = ""
        startLiveSpeech()
        print("🎤 PARAKEET | recording started (\(inputDeviceName), \(nativeSampleRate)Hz)")
        return true
    }

    func stopRecording() {
        guard isRecording else { return }
        stopLiveSpeech()
        audioEngine.inputNode.removeTap(onBus: 0)
        pendingSamplesLock.lock()
        sampleBuffer.append(contentsOf: pendingSamples)
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesLock.unlock()
        isRecording = false
        audioLevel = 0
        print("⏹️ PARAKEET | recording stopped (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / nativeSampleRate))s)")
    }

    // MARK: - Live Apple Speech (display-only)

    private func startLiveSpeech() {
        if liveSpeechRecognizer == nil {
            liveSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let recognizer = liveSpeechRecognizer, recognizer.isAvailable else {
            print("⚠️ PARAKEET | Apple Speech unavailable, skipping live transcript")
            return
        }

        isLiveSpeechActive = true
        liveRestartCount = 0
        liveRestartWindowStart = CFAbsoluteTimeGetCurrent()
        startLiveSpeechTask(recognizer: recognizer)
        print("👂 PARAKEET | live Apple Speech started")
    }

    private func startLiveSpeechTask(recognizer: SFSpeechRecognizer) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - liveRestartWindowStart > 10 {
            liveRestartCount = 0
            liveRestartWindowStart = now
        }
        liveRestartCount += 1
        if liveRestartCount > 5 {
            print("⚠️ PARAKEET | live speech restarted too many times, stopping")
            isLiveSpeechActive = false
            return
        }

        liveRequest?.endAudio()
        liveTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *), recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        liveRequest = request

        liveTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                let partialText = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespaces)
                Task { @MainActor [weak self] in
                    guard let self = self, !partialText.isEmpty else { return }
                    let combined = self.committedLiveText.isEmpty
                        ? partialText
                        : self.committedLiveText + " " + partialText
                    // Never shrink the transcript — a new recognition task's early
                    // partial results can be shorter than what's already committed.
                    if combined.count >= self.liveTranscript.count {
                        self.liveTranscript = combined
                    }
                }

                if result.isFinal {
                    let finalText = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespaces)
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isLiveSpeechActive else { return }
                        if !finalText.isEmpty {
                            self.committedLiveText = self.committedLiveText.isEmpty
                                ? finalText
                                : self.committedLiveText + " " + finalText
                        }
                        // Pin display to committed text before restarting — prevents
                        // the gap between old task ending and new task producing text.
                        self.liveTranscript = self.committedLiveText
                        self.startLiveSpeechTask(recognizer: recognizer)
                    }
                }
            } else if let error = error {
                Task { @MainActor [weak self] in
                    guard let self = self, self.isLiveSpeechActive else { return }
                    if !self.liveTranscript.isEmpty {
                        self.committedLiveText = self.liveTranscript
                    }
                    // Pin display to committed text before restarting
                    self.liveTranscript = self.committedLiveText
                    self.startLiveSpeechTask(recognizer: recognizer)
                }
            }
        }
    }

    private func stopLiveSpeech() {
        isLiveSpeechActive = false
        liveRequest?.endAudio()
        liveTask?.cancel()
        liveRequest = nil
        liveTask = nil
    }

    // MARK: - Transcription

    func transcribe() async -> String? {
        guard !isTranscribing else {
            print("⚠️ PARAKEET | transcription already in progress")
            return nil
        }
        pendingSamplesLock.lock()
        sampleBuffer.append(contentsOf: pendingSamples)
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesLock.unlock()
        guard !sampleBuffer.isEmpty else {
            print("⚠️ PARAKEET | no audio to transcribe")
            return nil
        }
        guard let manager = asrManager, manager.isAvailable else {
            print("❌ PARAKEET | ASR manager not available")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcription")
            return nil
        }

        isTranscribing = true
        let samples = sampleBuffer
        let inputRate = nativeSampleRate

        let startTime = CFAbsoluteTimeGetCurrent()

        // Resample to 16kHz for Parakeet inference
        let resampled = AudioResampler.resample(samples, from: inputRate, to: 16000)
        print("🔄 PARAKEET | resampled \(samples.count) → \(resampled.count) samples")

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
                    context: ["samples": "\(samples.count)"])
                return nil
            }

            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_complete",
                message: "Transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.1f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(trimmed.count)",
                    "input_samples": "\(samples.count)",
                ])
            return trimmed
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("❌ PARAKEET | transcription failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "transcription_failed",
                message: error.localizedDescription,
                context: ["samples": "\(samples.count)", "elapsed": String(format: "%.2f", elapsed)])
            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)
            return nil
        }
    }

    // MARK: - Cleanup

    func cancel() {
        if isRecording {
            stopLiveSpeech()
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
            audioLevel = 0
        }
        sampleBuffer.removeAll()
        isTranscribing = false
        liveTranscript = ""
        committedLiveText = ""
    }

    func cleanup() {
        initTask?.cancel()
        initTask = nil
        asrManager?.cleanup()
        asrManager = nil
        modelDownloadState = .notLoaded
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
        asrManager?.cleanup()
    }
}
