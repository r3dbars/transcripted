// WhisperEngine.swift
// Records audio and batch-transcribes using whisper.cpp (large-v3-turbo).
// No time limit, no streaming text — just waveform during recording, then full transcription.

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
    private var lastLevelUpdate: CFAbsoluteTime = 0
    private var isEnginePrewarmed = false

    // Live Apple Speech (display-only — Whisper owns the final transcript)
    @Published var liveTranscript: String = ""
    private var committedLiveText: String = ""  // Accumulates across task restarts
    private var liveSpeechRecognizer: SFSpeechRecognizer?
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private var isLiveSpeechActive = false  // Guards against restart after explicit stop
    private var configChangeObserver: NSObjectProtocol?

    // Whisper context — loaded once, reused across transcriptions
    private var whisperContext: OpaquePointer?  // whisper_context *

    // MARK: - Model Loading

    /// Load the GGML model file into memory. Call once (e.g., at app launch if Whisper is selected).
    func loadModel(path: String) -> Bool {
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
        AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        return name as String
    }

    // MARK: - Pre-warm

    /// Pre-warm the audio engine: prepare + start with NO tap installed.
    /// No orange mic dot appears (no tap = no audio capture). Next startRecording() is instant.
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
        } catch {
            print("⚠️ WHISPER | prewarm failed: \(error.localizedDescription), will cold-start on record")
        }

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
    }

    /// Audio device changed (AirPods connected, USB mic plugged in, etc.)
    /// Stop the engine and re-warm with the new device's format.
    private func handleAudioConfigChange() {
        let wasRecording = isRecording
        if wasRecording {
            // Mid-recording device switch — stop cleanly, user will need to restart
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
        } catch {
            print("⚠️ WHISPER | re-warm failed after device change: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        sampleBuffer.removeAll(keepingCapacity: true)

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        nativeSampleRate = nativeFormat.sampleRate

        // Force mono at native sample rate (same pattern as SpeechEngine)
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeSampleRate, channels: 1)!

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: monoFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // Consumer 1: Apple Speech (live display)
            self.liveRequest?.append(buffer)

            // Consumer 2: Whisper sample buffer (batch transcription)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            Task { @MainActor [weak self] in
                self?.sampleBuffer.append(contentsOf: samples)
            }

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
        if isEnginePrewarmed {
            isRecording = true
            liveTranscript = ""
            committedLiveText = ""
            startLiveSpeech()
            print("🎤 WHISPER | recording started (pre-warmed, \(inputDeviceName), \(nativeSampleRate)Hz)")
        } else {
            do {
                audioEngine.prepare()
                try audioEngine.start()
                isRecording = true
                isEnginePrewarmed = true  // Now warm for next time
                liveTranscript = ""
                committedLiveText = ""
                startLiveSpeech()
                print("🎤 WHISPER | recording started (cold-start, \(inputDeviceName), \(nativeSampleRate)Hz)")
            } catch {
                print("❌ WHISPER | audio engine failed: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        stopLiveSpeech()
        // Remove tap but keep engine running — stays warm for next session
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        audioLevel = 0
        print("⏹️ WHISPER | recording stopped, engine stays warm (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / nativeSampleRate))s)")
    }

    // MARK: - Live Apple Speech (display-only)

    private func startLiveSpeech() {
        // Initialize recognizer lazily
        if liveSpeechRecognizer == nil {
            liveSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let recognizer = liveSpeechRecognizer, recognizer.isAvailable else {
            print("⚠️ WHISPER | Apple Speech unavailable, skipping live transcript")
            return
        }

        isLiveSpeechActive = true
        startLiveSpeechTask(recognizer: recognizer)
        print("👂 WHISPER | live Apple Speech started")
    }

    /// Creates a fresh recognition request/task. Called on initial start AND on auto-restart
    /// after Apple Speech dies (silence timeout, error 203/216, isFinal).
    private func startLiveSpeechTask(recognizer: SFSpeechRecognizer) {
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
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // Combine committed text (from previous tasks) with current partial
                    let combined = self.committedLiveText.isEmpty
                        ? partialText
                        : self.committedLiveText + " " + partialText
                    self.liveTranscript = combined
                }

                // isFinal = task is done (silence or timeout) — commit and restart
                if result.isFinal {
                    let finalText = result.bestTranscription.formattedString
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isLiveSpeechActive else { return }
                        if !finalText.trimmingCharacters(in: .whitespaces).isEmpty {
                            self.committedLiveText = self.committedLiveText.isEmpty
                                ? finalText
                                : self.committedLiveText + " " + finalText
                        }
                        print("👂 WHISPER | live speech task ended (isFinal), restarting")
                        self.startLiveSpeechTask(recognizer: recognizer)
                    }
                }
            } else if let error = error {
                // Task died (error 203/216 = normal timeout, or other) — commit volatile text and restart
                Task { @MainActor [weak self] in
                    guard let self = self, self.isLiveSpeechActive else { return }
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

    /// Wrapper to pass OpaquePointer across concurrency boundaries (whisper_context is thread-safe).
    private struct SendablePointer: @unchecked Sendable { let ptr: OpaquePointer }

    /// Runs whisper_full() on a background thread via withCheckedContinuation.
    private nonisolated static func runWhisperInference(ctx: OpaquePointer, samples: [Float], inputRate: Double) async -> String? {
        let sendable = SendablePointer(ptr: ctx)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
        // Note: deinit runs on whatever thread — whisper_free is thread-safe
        if let ctx = whisperContext {
            whisper_free(ctx)
        }
    }
}
