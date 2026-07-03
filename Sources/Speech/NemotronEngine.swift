// NemotronEngine.swift
// FluidAudio-backed Nemotron streaming STT engine, beta-gated behind
// SpeechModelBetaPreferences. Like WhisperEngine, this engine only transcribes
// buffered samples — recording and mic capture stay in ParakeetEngine.

import AVFoundation
import FluidAudio
import Foundation

@MainActor
final class NemotronEngine: ObservableObject {
    @Published private(set) var modelDownloadState: ParakeetModelState = .notLoaded

    // 1120ms is the middle latency tier of the three Nemotron streaming
    // variants (560ms / 1120ms / 2240ms): a balance between chunk latency and
    // per-chunk accuracy for batch-style segment transcription.
    private static let variant: StreamingModelVariant = .nemotron1120ms

    private static let model: TranscriptionModelChoice = .nemotronStreaming

    private var manager: (any StreamingAsrManager)?
    private var initializationTask: Task<Void, Never>?
    // Serializes transcribeSamples calls: the streaming manager is stateful
    // (appendAudio → processBufferedAudio → finish → reset), so overlapping
    // segments must never interleave on the same manager.
    private var inFlightTranscription: Task<String, Error>?

    var isModelLoaded: Bool {
        manager != nil && modelDownloadState.isReady
    }

    func initialize() async {
        if isModelLoaded {
            return
        }

        if let initializationTask {
            await initializationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.load()
        }
        initializationTask = task
        await task.value
        if initializationTask == task {
            initializationTask = nil
        }
    }

    func transcribeSamples(_ samples: [Float], source: AudioSource) async throws -> String {
        let previous = inFlightTranscription
        let task = Task { @MainActor [weak self] () throws -> String in
            // Wait for the previous segment to fully finish (and reset the
            // manager) before starting; its outcome is its caller's problem.
            _ = try? await previous?.value
            guard let self else {
                throw NSError(domain: "NemotronEngine", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Nemotron engine was released."
                ])
            }
            return try await self.performTranscription(samples, source: source)
        }
        inFlightTranscription = task
        defer {
            if inFlightTranscription == task {
                inFlightTranscription = nil
            }
        }
        return try await task.value
    }

    func cleanup() {
        initializationTask?.cancel()
        initializationTask = nil
        inFlightTranscription?.cancel()
        inFlightTranscription = nil
        let manager = manager
        self.manager = nil
        modelDownloadState = .notLoaded
        Task {
            await manager?.cleanup()
        }
    }

    private func performTranscription(_ samples: [Float], source: AudioSource) async throws -> String {
        if !isModelLoaded {
            await initialize()
        }

        guard let manager, isModelLoaded else {
            EventReporter.shared.capture(
                level: .error,
                engine: Self.model.engineName,
                event: "asr_manager_unavailable",
                message: "Nemotron streaming model is not loaded",
                context: ["model": Self.model.rawValue]
            )
            throw NSError(domain: "NemotronEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(Self.model.title) is not loaded."
            ])
        }

        guard !samples.isEmpty else { return "" }

        let sourceDescription = source == .microphone ? "microphone" : "system"
        guard TranscriptedConstants.hasMinimumParakeetAudioSamples(samples.count) else {
            let duration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            EventReporter.shared.capture(
                level: .warning,
                engine: Self.model.engineName,
                event: "segment_too_short",
                message: "Skipped short audio segment before Nemotron transcription",
                context: [
                    "audio_duration_s": String(format: "%.2f", duration),
                    "minimum_duration_s": String(format: "%.2f", TranscriptedConstants.parakeetMinimumAudioDuration),
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                    "model": Self.model.rawValue,
                ]
            )
            return ""
        }

        guard let buffer = Self.makePCMBuffer(from: samples) else {
            throw NSError(domain: "NemotronEngine", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't build an audio buffer for Nemotron transcription."
            ])
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            let text = try await manager.finish()
            // Reset so the next segment starts from a clean streaming state.
            try await manager.reset()

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0

            print("✅ NEMOTRON | \(Self.model.title) transcribed \(sourceDescription) in \(String(format: "%.2f", elapsed))s, chars=\(trimmed.count)")
            EventReporter.shared.capture(
                level: .info,
                engine: Self.model.engineName,
                event: source == .microphone ? "dictation_transcribed" : "meeting_segment_transcribed",
                message: "Nemotron segment transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "model": Self.model.rawValue,
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.2f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(trimmed.count)",
                    "source": sourceDescription,
                ]
            )

            // Apply the user's custom dictionary, mirroring ParakeetEngine and
            // WhisperEngine so proper-noun corrections work on every engine.
            return CustomDictionaryTextProcessor.apply(to: trimmed)
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            EventReporter.shared.capture(
                level: .error,
                engine: Self.model.engineName,
                event: "transcription_failed",
                message: error.localizedDescription,
                context: [
                    "model": Self.model.rawValue,
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                    "elapsed": String(format: "%.2f", elapsed),
                ]
            )
            // Best-effort recovery so a failed segment does not poison the
            // streaming state for the next one.
            try? await manager.reset()
            throw error
        }
    }

    private func load() async {
        if manager == nil {
            manager = Self.variant.createManager()
        }
        guard let manager else { return }

        // loadModels() downloads from HuggingFace into FluidAudio's model
        // cache on first use, then loads from disk. There is no per-file
        // progress callback, so publish a coarse downloading → ready state.
        modelDownloadState = .downloading(progress: 0)
        print("🌐 NEMOTRON | preparing \(Self.model.title)...")

        do {
            try await manager.loadModels()

            guard !Task.isCancelled else { return }
            modelDownloadState = .ready
            EventReporter.shared.capture(
                level: .info,
                engine: Self.model.engineName,
                event: "model_ready",
                message: "\(Self.model.title) initialized successfully",
                context: ["model": Self.model.rawValue]
            )
        } catch {
            let friendlyMessage = "Couldn't load \(Self.model.title): \(error.localizedDescription)"
            print("❌ NEMOTRON | \(friendlyMessage)")
            modelDownloadState = .failed(friendlyMessage)
            EventReporter.shared.capture(
                level: .error,
                engine: Self.model.engineName,
                event: "model_init_failed",
                message: friendlyMessage,
                context: ["model": Self.model.rawValue]
            )
        }
    }

    /// Wraps 16kHz mono Float32 samples in an AVAudioPCMBuffer for the
    /// streaming manager.
    private static func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: TranscriptedConstants.parakeetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channelData = buffer.floatChannelData
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }
        return buffer
    }
}

private extension ParakeetModelState {
    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}
