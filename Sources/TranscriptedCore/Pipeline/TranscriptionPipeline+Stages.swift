import Foundation
@preconcurrency import AVFoundation
import Accelerate
import FluidAudio

// MARK: - Shared Pipeline Stages

extension Transcription {

    nonisolated static func longestAudioDuration(micURL: URL?, systemURL: URL) throws -> TimeInterval {
        let systemDuration: TimeInterval
        do {
            systemDuration = try audioDuration(at: systemURL)
        } catch {
            // A corrupt system track is recoverable when the microphone track
            // survived. Do not fail before the decode fallback above can route
            // the meeting through the microphone-only path.
            if let micURL, let micDuration = try? audioDuration(at: micURL) {
                return micDuration
            }
            throw error
        }

        var durations = [systemDuration]
        if let micURL, let micDuration = try? audioDuration(at: micURL) {
            durations.append(micDuration)
        }
        return durations.max() ?? 0
    }

    /// Loads one track as 16 kHz mono, keeping a load failure as a value so
    /// the caller can resample both tracks at once and still handle each
    /// failure on its own. nil when there is no track.
    nonisolated static func loadResampledTrack(url: URL?) -> Result<[Float], Error>? {
        guard let url else { return nil }
        // The caller times both loads together; don't record each one too.
        return MeetingPipelineTimings.$current.withValue(nil) {
            Result { try AudioResampler.loadAndResample(url: url, targetRate: 16000) }
        }
    }

    nonisolated static func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// The diarizer's backend and voiceprint model for the call about to run.
    nonisolated static func diarizationRunDescriptor(of diarization: any DiarizationEngine) async -> DiarizationRunDescriptor {
        await MainActor.run { diarization.activeRunDescriptor }
    }

    /// A silent system-audio channel is valid when the meeting still has a mic
    /// track. Treat only the diarizer's explicit no-speech result as an empty
    /// remote channel; model, format, cancellation, and other failures must
    /// continue to propagate.
    nonisolated static func diarizeSystemAudio(
        samples: [Float],
        diarization: any DiarizationEngine,
        hasMicTrack: Bool,
        clusteringThreshold: Double? = nil
    ) async throws -> [SpeakerSegment] {
        do {
            return try await diarization.diarizeOffline(
                samples: samples,
                sampleRate: 16000,
                clusteringThreshold: clusteringThreshold
            )
        } catch {
            guard hasMicTrack, isExplicitNoSpeechError(error) else { throw error }
            AppLogger.transcription.info("System audio contained no speech; continuing with mic track")
            return []
        }
    }

    /// Transcribes one batch from `SpeechSegmentBatcher`: several segments in
    /// one packed call when the engine supports it, else one call each.
    /// Returns one text per segment, in order. A packed call that fails for
    /// any reason other than cancellation falls back to one call per segment,
    /// so packing can make a meeting faster but never lose it.
    nonisolated static func transcribeSegmentBatch(
        _ segments: [[Float]],
        engine: any SpeechToTextEngine,
        source: AudioSource,
        language: TranscriptionLanguageContext
    ) async throws -> [String] {
        if segments.count > 1 {
            do {
                if let texts = try await engine.transcribePackedSegments(segments, source: source, language: language),
                   texts.count == segments.count {
                    return texts
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                AppLogger.transcription.warning("Packed speech-to-text call failed; transcribing segments one by one", [
                    "segments": "\(segments.count)",
                    "errorType": "\(type(of: error))"
                ])
            }
        }
        var texts: [String] = []
        texts.reserveCapacity(segments.count)
        for samples in segments {
            try Task.checkCancellation()
            texts.append(try await engine.transcribeSegment(samples: samples, source: source, language: language))
        }
        return texts
    }

    nonisolated static func isExplicitNoSpeechError(_ error: Error) -> Bool {
        if let diarizationError = error as? DiarizationResultError,
           case .noSpeechDetected = diarizationError {
            return true
        }
        if let pipelineError = error as? PipelineError,
           case .noSpeechDetected = pipelineError {
            return true
        }
        return false
    }

    // MARK: - Utterance Merging

    /// Merge consecutive utterances from the same speaker when the time gap between them
    /// is smaller than `maxGap` seconds. This produces cleaner transcripts by joining
    /// fragments that the diarizer split mid-sentence.
    ///
    /// A `maxDuration` cap prevents runaway merges — even if the speaker and gap criteria
    /// are met, an utterance won't grow beyond this many seconds of continuous speech.
    ///
    /// `interruptingSegments` are diarized turns (after speaker-id remap) that may
    /// not have been transcribed — the pipeline skips slices under 1 s for STT.
    /// A different speaker occupying `(current.end, next.start)` blocks the merge
    /// so a dropped 0.3 s interjection still keeps the two sides as two turns.
    nonisolated static func mergeConsecutiveUtterances(
        _ utterances: [TranscriptionUtterance],
        maxGap: Double,
        maxDuration: Double = 30.0,
        interruptingSegments: [SpeakerSegment] = []
    ) -> [TranscriptionUtterance] {
        guard utterances.count > 1 else { return utterances }

        var merged: [TranscriptionUtterance] = []
        var current = utterances[0]

        for next in utterances.dropFirst() {
            let sameSpeaker = current.speakerId == next.speakerId
                && current.channel == next.channel
            let smallGap = (next.start - current.end) < maxGap
            let withinDurationCap = (next.end - current.start) <= maxDuration
            let interrupted = gapHasOtherSpeaker(
                speakerId: current.speakerId,
                from: current.end,
                to: next.start,
                in: interruptingSegments
            )

            if sameSpeaker && smallGap && withinDurationCap && !interrupted {
                // Merge: extend current to cover both, join text
                current = TranscriptionUtterance(
                    start: current.start,
                    end: next.end,
                    channel: current.channel,
                    speakerId: current.speakerId,
                    persistentSpeakerId: current.persistentSpeakerId ?? next.persistentSpeakerId,
                    matchSimilarity: current.matchSimilarity ?? next.matchSimilarity,
                    transcript: current.transcript.trimmingCharacters(in: .whitespaces)
                        + " " + next.transcript.trimmingCharacters(in: .whitespaces)
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    /// True when a different diarized speaker occupies the open gap
    /// `(from, to)`. Same-speaker occupancy does not block a merge.
    nonisolated static func gapHasOtherSpeaker(
        speakerId: Int,
        from start: Double,
        to end: Double,
        in segments: [SpeakerSegment]
    ) -> Bool {
        guard end > start else { return false }
        return segments.contains { segment in
            segment.speakerId != speakerId
                && segment.startTime < end
                && segment.endTime > start
        }
    }

    // MARK: - Silence-Based Speech Segmentation

    struct PreparedMicSegment {
        let samples: [Float]
        let analysis: AudioSignalAnalysis
        let gain: Float
        let paddedSampleCount: Int
    }

    nonisolated static func prepareMicSegmentForTranscription(
        samples: [Float],
        sampleRate: Double,
        maxGain: Float = 12.0,
        ignoringSpikes: Bool = false
    ) -> PreparedMicSegment? {
        guard !samples.isEmpty,
              AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else { return nil }

        let analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: sampleRate)
        if samples.count < AudioSignalRecovery.parakeetMinimumInferenceSamples, !analysis.hasSpeechCandidate {
            return nil
        }

        let normalization = AudioSignalRecovery.normalizeForSpeech(
            samples: samples,
            sampleRate: sampleRate,
            analysis: analysis,
            maxGain: maxGain,
            ignoringSpikes: ignoringSpikes
        )
        let padded = AudioSignalRecovery.padForParakeet(samples: normalization.samples)

        return PreparedMicSegment(
            samples: padded,
            analysis: analysis,
            gain: normalization.gain,
            paddedSampleCount: padded.count - normalization.samples.count
        )
    }

    /// A time range representing a speech segment in the audio.
    struct SpeechSegment {
        let start: Double   // seconds
        let end: Double     // seconds
    }

    /// Detect speech segments by finding silence gaps in the audio.
    /// Computes RMS energy per frame and splits at gaps where energy drops
    /// below threshold for at least `minSilenceDuration`.
    ///
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 audio samples
    ///   - sampleRate: Sample rate (16000)
    ///   - analysis: `AudioSignalRecovery.analyze` of these exact samples, when
    ///     the caller already has it. It's only a shortcut: one that doesn't
    ///     match the buffer's length and rate is ignored and recomputed.
    /// - Returns: Array of speech segments with start/end times
    nonisolated static func detectSpeechSegments(
        samples: [Float],
        sampleRate: Double,
        analysis precomputedAnalysis: AudioSignalAnalysis? = nil
    ) -> [SpeechSegment] {
        guard !samples.isEmpty,
              AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else { return [] }

        let frameSamples = Int(sampleRate * 0.025)  // 25ms frames (400 samples at 16kHz)
        let hopSamples = Int(sampleRate * 0.010)    // 10ms hop
        let analysis: AudioSignalAnalysis
        if let precomputedAnalysis,
           precomputedAnalysis.sampleCount == samples.count,
           precomputedAnalysis.sampleRate == sampleRate {
            analysis = precomputedAnalysis
        } else {
            analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: sampleRate)
        }
        let silenceThreshold = AudioSignalRecovery.speechDetectionThreshold(for: analysis)
        let minSilenceDuration: Double = 0.4        // 400ms gap to split
        let minSegmentDuration: Double = 0.5        // Don't create segments shorter than this

        // Compute RMS energy per frame
        let totalFrames = max(1, (samples.count - frameSamples) / hopSamples + 1)
        var isVoiced = [Bool](repeating: false, count: totalFrames)

        samples.withUnsafeBufferPointer { ptr in
            // Security: guard against nil baseAddress (empty buffer) before pointer arithmetic
            guard let baseAddr = ptr.baseAddress else { return }
            for i in 0..<totalFrames {
                let start = i * hopSamples
                let end = min(start + frameSamples, samples.count)
                let count = end - start
                guard count > 0 else { continue }

                var sumSquares: Float = 0
                vDSP_dotpr(baseAddr + start, 1,
                           baseAddr + start, 1,
                           &sumSquares,
                           vDSP_Length(count))
                let rms = sqrt(sumSquares / Float(count))
                isVoiced[i] = rms >= silenceThreshold
            }
        }

        // Find speech regions: contiguous voiced frames, split at silence gaps
        var segments: [SpeechSegment] = []
        var speechStart: Int? = nil
        var silenceFrameCount = 0
        let minSilenceFrames = Int(minSilenceDuration / 0.010)

        for i in 0..<totalFrames {
            if isVoiced[i] {
                if speechStart == nil {
                    speechStart = i
                }
                silenceFrameCount = 0
            } else {
                silenceFrameCount += 1
                if let start = speechStart, silenceFrameCount >= minSilenceFrames {
                    // End of speech region — segment boundary
                    let segStart = Double(start * hopSamples) / sampleRate
                    let segEnd = Double((i - silenceFrameCount + 1) * hopSamples) / sampleRate
                    if segEnd - segStart >= minSegmentDuration {
                        segments.append(SpeechSegment(start: segStart, end: segEnd))
                    }
                    speechStart = nil
                }
            }
        }

        // Close final segment
        if let start = speechStart {
            let segStart = Double(start * hopSamples) / sampleRate
            let segEnd = Double(samples.count) / sampleRate
            if segEnd - segStart >= minSegmentDuration {
                segments.append(SpeechSegment(start: segStart, end: segEnd))
            }
        }

        // Fallback: if no segments detected (very quiet recording or constant noise),
        // treat the entire track as one segment
        if segments.isEmpty {
            segments.append(SpeechSegment(start: 0, end: Double(samples.count) / sampleRate))
        }

        return segments
    }
}
