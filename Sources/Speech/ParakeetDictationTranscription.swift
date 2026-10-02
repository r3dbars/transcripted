// ParakeetDictationTranscription.swift
// Recorded-take buffering and dictation transcription for ParakeetEngine:
// draining tap batches into the rate-aware timeline, preserve/interrupt
// helpers, resampling, the recorded-transcription lease, the external
// engine drain, and transcribe() with its empty-result retry. Split out of
// ParakeetEngine.swift.
//
// These are internal collaborator methods on ParakeetEngine. ParakeetEngine
// (ParakeetEngine.swift) stays the public-API owner and @MainActor home for
// the state; this file only groups one slice of its implementation.

import Foundation
import TranscriptedCore

extension ParakeetEngine {
    // MARK: - Recorded Audio Buffering

    func drainPendingSamplesIntoTimeline() {
        let segments = pendingSamplesLock.withLock { pendingSamples.drain() }
        for segment in segments {
            recoveredRecordingTimeline.append(segment.samples, sampleRate: segment.sampleRate)
        }
    }

    func beginFreshRecordingSession() {
        recordingIdentity = UUID()
        recordedTranscriptionOwnership.revoke()
        isTranscribing = false
    }

    func preserveCurrentRecordingBuffersForRecovery() {
        drainPendingSamplesIntoTimeline()
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty
    }

    func clearRecoveredRecordingTimeline(keepingCapacity: Bool = true) {
        recoveredRecordingTimeline.removeAll(keepingCapacity: keepingCapacity)
        preservingRecordingAcrossRecovery = false
    }

    func interruptRecordingAndClearRecoveredTimeline() {
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        markRecordingInterrupted()
    }

    func interruptRecordingPreservingRecoveredTimeline() {
        markRecordingInterrupted()
    }

    private func markRecordingInterrupted() {
        // Retained audio is available for an explicit recovery action; it is
        // not permission to restart capture or append it to the next dictation.
        preservingRecordingAcrossRecovery = false
        configChangeWasRecording = false
        recordingInterrupted = true
    }

    func loadRecordedSamplesForDictationBenchmark(_ samples: [Float], sampleRate: Double) {
        beginFreshRecordingSession()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        recoveredRecordingTimeline.removeAll(keepingCapacity: true)
        recoveredRecordingTimeline.append(samples, sampleRate: sampleRate)
        preservingRecordingAcrossRecovery = false
        updateNativeSampleRate(sampleRate)
        isRecording = false
        isTranscribing = false
        recordingInterrupted = false
        audioLevel = 0
    }

    private func drainRecordedSamplesForInference() async -> RecordedSpeechSamples? {
        drainPendingSamplesIntoTimeline()
        // Keep native audio until conversion succeeds. A converter failure is
        // retryable and must not consume the only surviving recording.
        let claim = ParakeetRecordedSamplesClaim(recordingIdentity: recordingIdentity, revision: recordedSamplesRevision)
        guard let recorded = await resampleRecordedSegments(recoveredRecordingTimeline.segments),
              claim.isCurrent(recordingIdentity: recordingIdentity, revision: recordedSamplesRevision, cancelled: Task.isCancelled) else { return nil }
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        return recorded
    }

    private func consumeRecordedSamples(
        preparedRecording: RecordedSpeechSamples?
    ) async -> RecordedSpeechSamples? {
        guard let preparedRecording else {
            return await drainRecordedSamplesForInference()
        }

        // The persistence snapshot already resampled this exact stopped
        // recording. Consume the native buffers without repeating that work.
        drainPendingSamplesIntoTimeline()
        guard preparedRecording.claim.isCurrent(
            recordingIdentity: recordingIdentity,
            revision: recordedSamplesRevision,
            cancelled: Task.isCancelled
        ) else { return nil }
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        return preparedRecording
    }

    func snapshotRecordedSamplesForPersistence() async -> RecordedSpeechSamples? {
        drainPendingSamplesIntoTimeline()

        return await resampleRecordedSegments(recoveredRecordingTimeline.segments)
    }

    private func resampleRecordedSegments(_ segments: [RecordedAudioSegment]) async -> RecordedSpeechSamples? {
        let nativeSampleCount = segments.reduce(0) { $0 + $1.samples.count }
        guard nativeSampleCount > 0 else { return nil }
        let claim = ParakeetRecordedSamplesClaim(recordingIdentity: recordingIdentity, revision: recordedSamplesRevision)
        do {
            let samples16k = try await Task.detached(priority: .userInitiated) {
                try RecordedAudioTimeline.speechSamples(from: segments) { samples, sampleRate in
                    try AudioResampler.resampleForSpeech(
                        samples,
                        from: sampleRate,
                        to: TranscriptedConstants.parakeetSampleRate
                    )
                }
            }.value
            guard claim.isCurrent(recordingIdentity: recordingIdentity, revision: recordedSamplesRevision, cancelled: Task.isCancelled) else { return nil }
            return RecordedSpeechSamples(nativeSampleCount: nativeSampleCount, samples16k: samples16k, claim: claim)
        } catch {
            guard claim.isCurrent(recordingIdentity: recordingIdentity, revision: recordedSamplesRevision, cancelled: Task.isCancelled) else { return nil }
            lastEmptyTranscriptionReason = .modelFailure
            EventReporter.shared.capture(
                level: .error, engine: "parakeet", event: "audio_conversion_failed",
                message: "Recorded audio conversion failed; native samples retained for retry"
            )
            return nil
        }
    }

    // MARK: - Transcription

    func drainRecordedSamplesForExternalTranscription(
        engineName: String,
        preparedRecording: RecordedSpeechSamples? = nil
    ) async -> RecordedSpeechSamples? {
        lastEmptyTranscriptionReason = nil
        guard !isTranscribing else {
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress"
            )
            return nil
        }

        drainPendingSamplesIntoTimeline()

        guard preparedRecording != nil || !recoveredRecordingTimeline.isEmpty else {
            lastEmptyTranscriptionReason = .recordingTooShort
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called"
            )
            return nil
        }

        guard let transcriptionLease = beginRecordedTranscription() else { return nil }
        let recorded = await consumeRecordedSamples(preparedRecording: preparedRecording)
        if Task.isCancelled {
            finishTranscription(ownedBy: transcriptionLease, clearSamples: recorded != nil)
            return nil
        }
        guard ownsRecordedTranscription(transcriptionLease) else { return nil }
        guard let recorded else {
            lastEmptyTranscriptionReason = DictationEmptyInferencePolicy.reasonAfterEmptyConversion(
                current: lastEmptyTranscriptionReason,
                retainsNativeAudio: !recoveredRecordingTimeline.isEmpty
            )
            finishTranscription(ownedBy: transcriptionLease, clearSamples: false)
            return nil
        }
        let nativeCount = recorded.nativeSampleCount
        let resampled = recorded.samples16k
        AppLogger.transcription.info("\(engineName.uppercased()) | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            lastEmptyTranscriptionReason = .recordingTooShort
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            AppLogger.transcription.warning("\(engineName.uppercased()) | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            finishTranscription(ownedBy: transcriptionLease)
            return nil
        }

        return RecordedSpeechSamples(nativeSampleCount: nativeCount, samples16k: resampled, claim: recorded.claim)
    }

    var currentRecordedTranscriptionLease: ParakeetRecordedTranscriptionLease? {
        recordedTranscriptionOwnership.activeLease
    }

    var currentRecordedSamplesRevision: UInt64 { recordedSamplesRevision }

    func ownsRecordedTranscription(
        _ lease: ParakeetRecordedTranscriptionLease,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        recordedTranscriptionOwnership.owns(lease, recordingIdentity: recordingIdentity)
            && (expectedRevision == nil || expectedRevision == recordedSamplesRevision)
    }

    private func beginRecordedTranscription() -> ParakeetRecordedTranscriptionLease? {
        guard let lease = recordedTranscriptionOwnership.begin(recordingIdentity: recordingIdentity) else { return nil }
        isTranscribing = true
        return lease
    }

    func finishExternalTranscription(
        ownedBy lease: ParakeetRecordedTranscriptionLease,
        expectedRevision: UInt64
    ) {
        finishTranscription(
            ownedBy: lease,
            clearSamples: recordedSamplesRevision == expectedRevision
        )
    }

    private func finishTranscription(
        ownedBy lease: ParakeetRecordedTranscriptionLease,
        clearSamples: Bool = true
    ) {
        guard recordedTranscriptionOwnership.finish(lease, recordingIdentity: recordingIdentity) else { return }
        isTranscribing = false
        if clearSamples { clearRecoveredRecordingTimeline(keepingCapacity: true) }
        finishDeferredModelTeardownIfIdle()
    }

    func transcribe(preparedRecording: RecordedSpeechSamples? = nil) async -> String? {
        guard !Task.isCancelled else { return nil }
        lastEmptyTranscriptionReason = nil
        guard !isTranscribing else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress")
            return nil
        }
        drainPendingSamplesIntoTimeline()
        guard preparedRecording != nil || !recoveredRecordingTimeline.isEmpty else {
            lastEmptyTranscriptionReason = .recordingTooShort
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called")
            return nil
        }
        guard let manager = asrManager, asrManagerReady else {
            AppLogger.transcription.error("PARAKEET | ASR manager not available")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcription")
            return nil
        }

        guard let transcriptionLease = beginRecordedTranscription() else { return nil }
        let startTime = CFAbsoluteTimeGetCurrent()

        let recorded = await consumeRecordedSamples(preparedRecording: preparedRecording)
        if Task.isCancelled {
            finishTranscription(ownedBy: transcriptionLease, clearSamples: recorded != nil)
            return nil
        }
        guard ownsRecordedTranscription(transcriptionLease) else { return nil }
        guard let recorded else {
            lastEmptyTranscriptionReason = DictationEmptyInferencePolicy.reasonAfterEmptyConversion(
                current: lastEmptyTranscriptionReason,
                retainsNativeAudio: !recoveredRecordingTimeline.isEmpty
            )
            finishTranscription(ownedBy: transcriptionLease, clearSamples: false)
            return nil
        }
        let consumedRevision = recordedSamplesRevision
        let nativeCount = recorded.nativeSampleCount
        let resampled = recorded.samples16k
        AppLogger.transcription.info("PARAKEET | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            lastEmptyTranscriptionReason = .recordingTooShort
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            AppLogger.transcription.warning("PARAKEET | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            finishTranscription(ownedBy: transcriptionLease)
            return nil
        }

        do {
            let resultText = try await runASRInference(
                manager: manager,
                samples: resampled
            )
            guard ownsRecordedTranscription(
                transcriptionLease,
                expectedRevision: consumedRevision
            ), !Task.isCancelled else {
                finishTranscription(ownedBy: transcriptionLease, clearSamples: false)
                return nil
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = CustomDictionaryTextProcessor.apply(to: trimmed)

            let audioDuration = Double(resampled.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
            AppLogger.transcription.info("PARAKEET | transcribed in \(String(format: "%.2f", elapsed))s, chars=\(corrected.count)")

            if trimmed.isEmpty {
                let analysis = DictationAudioRecovery.analyze(
                    samples: resampled,
                    sampleRate: TranscriptedConstants.parakeetSampleRate
                )
                var emptyContext = ["samples": "\(nativeCount)"]
                emptyContext.merge(analysis.context) { current, _ in current }
                var retryOutcome: DictationEmptyInferencePolicy.RetryOutcome = .notAttempted

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
                            samples: retrySamples
                        )
                        guard ownsRecordedTranscription(
                            transcriptionLease,
                            expectedRevision: consumedRevision
                        ), !Task.isCancelled else {
                            finishTranscription(ownedBy: transcriptionLease, clearSamples: false)
                            return nil
                        }
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
                            finishTranscription(ownedBy: transcriptionLease)
                            return retryCorrected
                        }

                        emptyContext["retry_empty"] = "true"
                        retryOutcome = .empty
                        emptyContext["retry_elapsed_s"] = String(format: "%.3f", retryElapsed)
                        emptyContext["retry_samples"] = "\(retrySamples.count)"
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        guard ownsRecordedTranscription(
                            transcriptionLease,
                            expectedRevision: consumedRevision
                        ) else {
                            finishTranscription(ownedBy: transcriptionLease, clearSamples: false)
                            return nil
                        }
                        emptyContext["retry_error"] = error.localizedDescription
                        retryOutcome = .failed
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

                emptyContext["retry_outcome"] = "\(retryOutcome)"
                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_empty",
                    message: "Parakeet returned no text after \(String(format: "%.1f", elapsed))s inference",
                    context: emptyContext)
                lastEmptyTranscriptionReason = DictationEmptyInferencePolicy.reason(
                    hasUsableSpeechSignal: analysis.hasUsableSpeechSignal
                )
                finishTranscription(ownedBy: transcriptionLease)
                return nil
            }

            finishTranscription(ownedBy: transcriptionLease)

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
            if Task.isCancelled || error is CancellationError {
                finishTranscription(ownedBy: transcriptionLease, clearSamples: false)
                return nil
            }
            guard ownsRecordedTranscription(
                transcriptionLease,
                expectedRevision: consumedRevision
            ) else {
                finishTranscription(ownedBy: transcriptionLease, clearSamples: false)
                return nil
            }
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
                lastEmptyTranscriptionReason = .recordingTooShort
                finishTranscription(ownedBy: transcriptionLease)
                return nil
            }

            AppLogger.transcription.error("PARAKEET | transcription failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "transcription_failed",
                message: error.localizedDescription,
                context: ["samples": "\(nativeCount)", "elapsed": String(format: "%.2f", elapsed)])
            lastEmptyTranscriptionReason = .modelFailure
            finishTranscription(ownedBy: transcriptionLease)
            return nil
        }
    }
}
