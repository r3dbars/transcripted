// WhisperEngine.swift
// Records audio and batch-transcribes using whisper.cpp (large-v3-turbo).
// No time limit, no streaming text — just waveform during recording, then full transcription.

import AVFoundation
import Foundation

@MainActor
class WhisperEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0  // 0.0–1.0, RMS level for waveform

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private var nativeSampleRate: Double = 48000
    private var lastLevelUpdate: CFAbsoluteTime = 0

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

            // Accumulate raw samples
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            Task { @MainActor [weak self] in
                self?.sampleBuffer.append(contentsOf: samples)
            }

            // RMS audio level (~20Hz throttled) for waveform animation
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

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            print("🎤 WHISPER | recording started (rate=\(nativeSampleRate)Hz)")
        } catch {
            print("❌ WHISPER | audio engine failed: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        audioLevel = 0
        print("⏹️ WHISPER | recording stopped (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / nativeSampleRate))s)")
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
        if isRecording { stopRecording() }
        sampleBuffer.removeAll()
        isTranscribing = false
    }

    deinit {
        // Note: deinit runs on whatever thread — whisper_free is thread-safe
        if let ctx = whisperContext {
            whisper_free(ctx)
        }
    }
}
