// ParakeetASRInference.swift
// The shared ASR inference slot for ParakeetEngine (queueing behind
// active decoder work, handoff, hasActiveASRWork) and the meeting
// pure-sample paths transcribeSamples / transcribePackedSamplesWithTokenTimes.
// Split out of ParakeetEngine.swift.
//
// These are internal collaborator methods on ParakeetEngine. ParakeetEngine
// (ParakeetEngine.swift) stays the public-API owner and @MainActor home for
// the state; this file only groups one slice of its implementation.

import FluidAudio
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    var hasActiveASRWork: Bool {
        asrInferenceGate.hasActiveWork
            || pureSampleTranscriptionActivityCount > 0
    }

    private func beginPureSampleTranscriptionActivity() {
        pureSampleTranscriptionActivityCount += 1
    }

    private func finishPureSampleTranscriptionActivity() {
        pureSampleTranscriptionActivityCount = max(0, pureSampleTranscriptionActivityCount - 1)
        finishDeferredModelTeardownIfIdle()
    }

    private func beginASRInference() async throws {
        let gate = asrInferenceGate
        try await gate.begin {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "asr_inference_deferred",
                message: "ASR inference request queued behind active decoder work",
                context: [
                    "active_count": "\(gate.activeCount)",
                    "handoff_count": "\(gate.handoffCount)",
                    "waiter_count": "\(gate.waiterCount)"
                ]
            )
        }
    }

    private func finishASRInference() {
        // A handoff keeps the decoder spoken for; teardown waits for the next finish.
        if asrInferenceGate.finish() { return }
        finishDeferredModelTeardownIfIdle()
    }

    /// The decoder layer count for `manager`. Read from the cache when
    /// `manager` is still the engine's live manager, so the common path skips
    /// an actor round trip before the encoder; otherwise one actor read.
    private func decoderLayerCount(for manager: AsrManager) async -> Int {
        if manager === asrManager, let cached = decoderLayerCountCache.count(for: manager) {
            return cached
        }
        let count = await manager.decoderLayerCount
        if manager === asrManager {
            decoderLayerCountCache.store(count, for: manager)
        }
        return count
    }

    func runASRInference(
        manager: AsrManager,
        samples: [Float]
    ) async throws -> String {
        let queueStartedAt = ProcessInfo.processInfo.systemUptime
        try await beginASRInference()
        let inferenceStartedAt = ProcessInfo.processInfo.systemUptime
        defer {
            let finishedAt = ProcessInfo.processInfo.systemUptime
            let queueWaitMS = (inferenceStartedAt - queueStartedAt) * 1_000
            let inferenceMS = (finishedAt - inferenceStartedAt) * 1_000
            // Aggregate local diagnostics only; existing end-to-end timing keeps
            // its semantics and neither samples nor transcript text are logged.
            AppLogger.transcription.info("PARAKEET | ASR queue_wait_ms=\(String(format: "%.2f", queueWaitMS)) inference_ms=\(String(format: "%.2f", inferenceMS))")
        }
        do {
            try Task.checkCancellation()
            // FluidAudio 0.15.x hands decoder-state ownership to the caller. Every batch
            // segment gets a fresh state so concurrent mic/system segments can never
            // contaminate each other's decoder context (0.7.9 kept per-source state
            // internally, keyed by the removed `source:` parameter).
            let decoderLayers = await decoderLayerCount(for: manager)
            try Task.checkCancellation()
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            try Task.checkCancellation()
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

    // MARK: - Pure-Sample Transcription (for Meeting pipeline)

    /// Transcribe pre-resampled 16kHz mono Float32 samples directly, bypassing
    /// ParakeetEngine's recording lifecycle and audio buffering.
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
        try Task.checkCancellation()
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
                samples: samples
            )
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
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

    /// One Parakeet call over several meeting segments packed end to end
    /// (`SpeechSegmentPacking`), returning each token with its start time so
    /// the caller can split the text back per segment. nil when the model
    /// isn't loaded, the audio doesn't fit one window, or the result carries
    /// no token times; the caller then transcribes the segments one by one.
    func transcribePackedSamplesWithTokenTimes(_ samples: [Float]) async throws -> [TimedTranscriptToken]? {
        try Task.checkCancellation()
        beginPureSampleTranscriptionActivity()
        defer { finishPureSampleTranscriptionActivity() }

        guard let manager = asrManager, asrManagerReady else { return nil }
        guard samples.count >= Int(TranscriptedConstants.parakeetSampleRate),
              samples.count <= ASRConstants.maxModelSamples else { return nil }

        let startTime = CFAbsoluteTimeGetCurrent()
        try await beginASRInference()
        let tokens: [TimedTranscriptToken]?
        do {
            try Task.checkCancellation()
            let decoderLayers = await decoderLayerCount(for: manager)
            try Task.checkCancellation()
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            try Task.checkCancellation()
            // Copy out of the CoreML-backed result before it is released.
            tokens = withExtendedLifetime(result) {
                let text = String(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timings = result.tokenTimings, !timings.isEmpty else {
                    return text.isEmpty ? [] : nil
                }
                return timings.map { TimedTranscriptToken(text: String($0.token), startSeconds: $0.startTime) }
            }
            finishASRInference()
        } catch {
            finishASRInference()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "meeting_packed_segments_transcribed",
            message: "Packed meeting segments transcribed in \(String(format: "%.2f", elapsed))s",
            context: [
                "elapsed_s": String(format: "%.3f", elapsed),
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "rtf": String(format: "%.3f", audioDuration > 0 ? elapsed / audioDuration : 0),
                "tokens": "\(tokens?.count ?? 0)",
            ])
        return tokens
    }
}
