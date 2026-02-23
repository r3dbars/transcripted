// WhisperEngine.swift
// Records audio and batch-transcribes using whisper.cpp (large-v3-turbo).
// Live Apple Speech provides display-only streaming text while recording;
// Whisper owns the final transcript via batch inference after recording stops.

import AVFoundation
import CoreAudio
import Foundation
import Speech

@MainActor
class WhisperEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0  // 0.0–1.0, RMS level for waveform

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private var nativeSampleRate: Double = 48000
    // Lock-protected buffer for audio thread → MainActor sample transfer (avoids ~47 Task creations/sec)
    private let pendingSamplesLock = NSLock()
    private var pendingSamples: [Float] = []
    // Accessed from both the audio thread and MainActor — benign race (worst case: extra/missed level update)
    private nonisolated(unsafe) var lastLevelUpdate: CFAbsoluteTime = 0
    private var isEnginePrewarmed = false

    // Live Apple Speech (display-only — Whisper owns the final transcript)
    @Published var liveTranscript: String = ""
    private var committedLiveText: String = ""  // Accumulates across task restarts
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private var isLiveSpeechActive = false  // Guards against restart after explicit stop
    private var liveRestartCount = 0         // Prevents infinite restart loop on non-transient errors
    private var liveRestartWindowStart: CFAbsoluteTime = 0
    private var configChangeObserver: NSObjectProtocol?

    // Whisper context — loaded once, reused across transcriptions
    private var whisperContext: OpaquePointer?  // whisper_context *

    // MARK: - Model Loading

    /// Load the GGML model file into memory. Call once (e.g., at app launch if Whisper is selected).
    func loadModel(path: String) -> Bool {
        guard !isRecording, !isTranscribing else {
            print("⚠️ WHISPER | cannot load model while recording or transcribing")
            return false
        }
        if whisperContext != nil { unloadModel() }

        let params = whisper_context_default_params()
        whisperContext = whisper_init_from_file_with_params(path, params)

        if whisperContext == nil {
            print("❌ WHISPER | failed to load model at \(path)")
            return false
        }
        print("✅ WHISPER | model loaded from \(path)")
        return true
    }

    func unloadModel() {
        guard !isRecording, !isTranscribing else {
            print("⚠️ WHISPER | cannot unload model while recording or transcribing")
            return
        }
        if let ctx = whisperContext {
            whisper_free(ctx)
            whisperContext = nil
            print("🗑️ WHISPER | model unloaded")
        }
    }

    var isModelLoaded: Bool { whisperContext != nil }

    /// Current input device name (e.g., "MacBook Pro Microphone", "AirPods Pro")
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

    // MARK: - Pre-warm

    /// Pre-warm the audio engine: prepare + start with NO tap installed.
    /// No mic indicator dot appears on macOS (no tap = no audio capture). Next startRecording() is instant.
    func prewarm() {
        guard !isEnginePrewarmed, !isRecording else { return }
        do {
            let inputNode = audioEngine.inputNode
            let nativeFormat = inputNode.outputFormat(forBus: 0)
            nativeSampleRate = nativeFormat.sampleRate

            audioEngine.prepare()
            try audioEngine.start()
            isEnginePrewarmed = true
            print("🔥 WHISPER | engine pre-warmed (\(inputDeviceName), \(nativeSampleRate)Hz)")

            // Observe audio device changes (e.g., switching to AirPods) — re-warm with new device
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
        } catch {
            print("⚠️ WHISPER | prewarm failed: \(error.localizedDescription), will cold-start on record")
        }
    }

    /// Audio device changed (AirPods connected, USB mic plugged in, etc.)
    /// Stop the engine, re-warm with the new device's format, and auto-resume if recording was active.
    private func handleAudioConfigChange() {
        guard isEnginePrewarmed else { return }

        let wasRecording = isRecording
        if isRecording {
            stopLiveSpeech()
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecording = false
            audioLevel = 0
        }

        // Engine is now invalid — stop and re-warm with new device
        audioEngine.stop()
        isEnginePrewarmed = false

        let newFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        print("🔄 WHISPER | audio device changed → \(inputDeviceName) (\(newFormat.sampleRate)Hz), re-warming")

        // Re-warm immediately
        do {
            nativeSampleRate = newFormat.sampleRate
            audioEngine.prepare()
            try audioEngine.start()
            isEnginePrewarmed = true
            print("🔥 WHISPER | engine re-warmed after device change (\(inputDeviceName), \(nativeSampleRate)Hz)")

            // Auto-resume recording if it was active before the device change
            if wasRecording {
                startRecording()
                print("🎤 WHISPER | auto-resumed recording after device change")
            }
        } catch {
            print("⚠️ WHISPER | re-warm failed after device change: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        guard isModelLoaded else {
            print("⚠️ WHISPER | cannot start recording — model not loaded")
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            print("⚠️ WHISPER | microphone permission not granted (status: \(micStatus.rawValue))")
            return
        }
        sampleBuffer.removeAll(keepingCapacity: true)
        // Pre-allocate for ~2 minutes of audio to avoid geometric reallocation during recording
        sampleBuffer.reserveCapacity(Int(nativeSampleRate * 120))

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        nativeSampleRate = nativeFormat.sampleRate

        // Force mono at native sample rate — multi-channel interfaces cause SFSpeechRecognizer error 1110
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeSampleRate, channels: 1)!

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: monoFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // Consumer 1: Apple Speech (live display)
            self.liveRequest?.append(buffer)

            // Consumer 2: Whisper sample buffer — lock-protected intermediate buffer
            // (avoids creating ~47 Task objects/sec; flushed in stopRecording/transcribe)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            self.pendingSamplesLock.lock()
            self.pendingSamples.append(contentsOf: samples)
            self.pendingSamplesLock.unlock()

            // Consumer 3: Audio level metering (~20Hz throttled) for waveform animation
            let now = CFAbsoluteTimeGetCurrent()
            guard now - (self.lastLevelUpdate) > 0.05 else { return }
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

        // If pre-warmed, engine is already running — just the tap install above is enough.
        // Otherwise, cold-start the engine now.
        if !isEnginePrewarmed {
            do {
                audioEngine.prepare()
                try audioEngine.start()
                isEnginePrewarmed = true
            } catch {
                print("❌ WHISPER | audio engine failed: \(error.localizedDescription)")
                return
            }
        }

        isRecording = true
        liveTranscript = ""
        committedLiveText = ""
        startLiveSpeech()
        print("🎤 WHISPER | recording started (\(isEnginePrewarmed ? "pre-warmed" : "cold-start"), \(inputDeviceName), \(nativeSampleRate)Hz)")
    }

    func stopRecording() {
        guard isRecording else { return }
        stopLiveSpeech()
        // Remove tap but keep engine running — stays warm for next session
        audioEngine.inputNode.removeTap(onBus: 0)
        // Flush any pending samples from the audio thread before we read sampleBuffer
        pendingSamplesLock.lock()
        sampleBuffer.append(contentsOf: pendingSamples)
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesLock.unlock()
        isRecording = false
        audioLevel = 0
        print("⏹️ WHISPER | recording stopped, engine stays warm (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / nativeSampleRate))s)")
    }

    // MARK: - Live Apple Speech (display-only)

    private func startLiveSpeech() {
        if liveSpeechRecognizer == nil {
            liveSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let recognizer = liveSpeechRecognizer, recognizer.isAvailable else {
            print("⚠️ WHISPER | Apple Speech unavailable, skipping live transcript")
            return
        }

        isLiveSpeechActive = true
        liveRestartCount = 0
        liveRestartWindowStart = CFAbsoluteTimeGetCurrent()
        startLiveSpeechTask(recognizer: recognizer)
        print("👂 WHISPER | live Apple Speech started")
    }

    /// Creates a fresh recognition request/task. Called on initial start AND on auto-restart
    /// after Apple Speech dies (silence timeout, error 203/216, isFinal).
    private func startLiveSpeechTask(recognizer: SFSpeechRecognizer) {
        // Prevent infinite restart loop on non-transient errors (e.g., auth revoked, hardware failure).
        // Allow max 5 rapid restarts within 10 seconds; after that, stop live speech.
        let now = CFAbsoluteTimeGetCurrent()
        if now - liveRestartWindowStart > 10 {
            liveRestartCount = 0
            liveRestartWindowStart = now
        }
        liveRestartCount += 1
        if liveRestartCount > 5 {
            print("⚠️ WHISPER | live speech restarted too many times (\(liveRestartCount) in 10s), stopping")
            isLiveSpeechActive = false
            return
        }

        // Clean up previous task if any
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
                    // Combine committed text (from previous tasks) with current partial
                    let combined = self.committedLiveText.isEmpty
                        ? partialText
                        : self.committedLiveText + " " + partialText
                    self.liveTranscript = combined
                }

                // isFinal = task is done (silence or timeout) — commit and restart
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
                        print("👂 WHISPER | live speech task ended (isFinal), restarting")
                        self.startLiveSpeechTask(recognizer: recognizer)
                    }
                }
            } else if let error = error {
                // Task died (error 203/216 = normal timeout, or other).
                // Snapshot current liveTranscript into committedLiveText to prevent text loss,
                // then restart with a fresh task.
                Task { @MainActor [weak self] in
                    guard let self = self, self.isLiveSpeechActive else { return }
                    // Commit whatever was displayed to prevent gap after restart
                    if !self.liveTranscript.isEmpty {
                        self.committedLiveText = self.liveTranscript
                    }
                    print("👂 WHISPER | live speech error (restarting): \(error.localizedDescription)")
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
        // Do NOT clear liveTranscript or committedLiveText — needed for lock-in animation
        print("👂 WHISPER | live Apple Speech stopped")
    }

    // MARK: - Transcription

    /// Transcribe the accumulated audio buffer. Returns the full transcription text, or nil on failure.
    func transcribe() async -> String? {
        guard !isTranscribing else {
            print("⚠️ WHISPER | transcription already in progress, skipping")
            return nil
        }
        // Flush any remaining samples from the audio thread
        pendingSamplesLock.lock()
        sampleBuffer.append(contentsOf: pendingSamples)
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesLock.unlock()
        guard !sampleBuffer.isEmpty else {
            print("⚠️ WHISPER | no audio to transcribe")
            return nil
        }
        guard let ctx = whisperContext else {
            print("❌ WHISPER | model not loaded")
            return nil
        }

        isTranscribing = true
        let samples = sampleBuffer
        let inputRate = nativeSampleRate

        let result = await Self.runWhisperInference(ctx: ctx, samples: samples, inputRate: inputRate)

        isTranscribing = false
        sampleBuffer.removeAll(keepingCapacity: true)
        return result
    }

    // MARK: - Inference (off main thread)

    /// Wrapper to pass OpaquePointer across concurrency boundaries.
    private struct SendablePointer: @unchecked Sendable { let ptr: OpaquePointer }

    /// Serial queue for whisper inference — whisper_context is NOT safe for concurrent whisper_full() calls
    /// (the Metal backend shares command buffers internally, concurrent access → ggml_abort).
    private static let inferenceQueue = DispatchQueue(label: "com.draft.whisper-inference", qos: .userInitiated)

    /// Runs whisper_full() on a dedicated serial queue via withCheckedContinuation.
    private nonisolated static func runWhisperInference(ctx: OpaquePointer, samples: [Float], inputRate: Double) async -> String? {
        let sendable = SendablePointer(ptr: ctx)
        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
                let result = Self.whisperInferenceSync(ctx: sendable.ptr, samples: samples, inputRate: inputRate)
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronous whisper inference — called on a background queue.
    private nonisolated static func whisperInferenceSync(ctx: OpaquePointer, samples: [Float], inputRate: Double) -> String? {
        // Resample to 16kHz
        let resampled = AudioResampler.resample(samples, from: inputRate, to: 16000)
        print("🔄 WHISPER | resampled \(samples.count) → \(resampled.count) samples")

        // Configure whisper
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_timestamps = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        let langStr = strdup("en")
        params.language = UnsafePointer(langStr)
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        params.n_threads = Int32(max(1, cpuCount - 2))

        let startTime = CFAbsoluteTimeGetCurrent()

        // Run inference
        let status = resampled.withUnsafeBufferPointer { bufferPtr in
            whisper_full(ctx, params, bufferPtr.baseAddress, Int32(resampled.count))
        }

        // Free strdup'd language string
        if let langStr = langStr { free(langStr) }

        guard status == 0 else {
            print("❌ WHISPER | whisper_full failed with status \(status)")
            return nil
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let nSegments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cStr)
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("✅ WHISPER | transcribed \(nSegments) segments in \(String(format: "%.2f", elapsed))s: \"\(trimmed.prefix(80))...\"")
        return trimmed.isEmpty ? nil : trimmed
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
        // Engine stays warm — don't call audioEngine.stop()
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Stop audio engine to release mic (tap callback uses [weak self], safe if self is nil)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        // Note: deinit runs on whatever thread — whisper_free is thread-safe
        if let ctx = whisperContext {
            whisper_free(ctx)
        }
    }
}
