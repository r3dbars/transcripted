import Foundation
@preconcurrency import AVFoundation
import Accelerate
import FluidAudio

// MARK: - Microphone-Only Transcription

extension Transcription {

    /// Recover/transcribe a live meeting when only the microphone WAV survived.
    /// Honors `splitLocalSpeakers` when the mic file is actually on disk; if
    /// that file is gone, stay on the single-"You" path.
    nonisolated func transcribeMicrophoneOnly(
        micURL: URL,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let parakeet = await MainActor.run { self.parakeet }

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing microphone audio..."
        }

        let processingStartTime = Date()

        do {
            onProgress?(0.0)
            await MainActor.run {
                self.processingStatus = "Loading microphone audio..."
            }

            var micSamples = try AudioResampler.loadAndResample(url: micURL, targetRate: 16000)
            let duration = try Self.audioDuration(at: micURL)
            MeetingPipelineTimings.current?.recordRecordingLength(seconds: duration)
            guard micSamples.count >= 16000 else {
                throw PipelineError.recordingTooShort(duration: Double(micSamples.count) / 16000.0)
            }

            await MainActor.run {
                self.processingStatus = "Transcribing microphone audio..."
            }

            // One scan of the whole mic track, shared by language sampling,
            // normalization and silence splitting below.
            let micSignalAnalysis = AudioSignalRecovery.analyze(samples: micSamples, sampleRate: 16000)
            // Only an engine that detects the spoken language reads these
            // windows (Whisper).
            var wantsLanguageSamples = false
            if languageSelection == .automatic {
                wantsLanguageSamples = await parakeet.usesRepresentativeLanguageSamples
            }
            let languageContext = try await parakeet.resolveLanguage(
                representativeSamples: wantsLanguageSamples
                    ? Self.representativeLanguageSamples(tracks: [micSamples], analyses: [micSignalAnalysis]) : [],
                selection: languageSelection
            )
            let shouldSplitLocalSpeakers = splitLocalSpeakers
                && FileManager.default.fileExists(atPath: micURL.path)
            if shouldSplitLocalSpeakers {
                let diarization = await MainActor.run { self.diarization }
                let speakerDB = await MainActor.run { self.speakerDB }
                let diarizationMicSamples = AudioSignalRecovery.normalizeForSpeech(
                    samples: micSamples,
                    sampleRate: 16000,
                    analysis: micSignalAnalysis
                ).samples
                micSamples = []
                var droppedSegments = 0
                let existingProfiles = speakerDB.allSpeakers()
                let micResult: MicChannelResult
                let diarizationRun = await Self.diarizationRunDescriptor(of: diarization)
                do {
                    micResult = try await Self.processMicChannelWithDiarization(
                        samples: diarizationMicSamples,
                        diarization: diarization,
                        parakeet: parakeet,
                        speakerDB: speakerDB,
                        existingProfiles: existingProfiles,
                        droppedSegments: &droppedSegments,
                        language: languageContext,
                        onProgress: onProgress
                    )
                } catch let error where Self.isExplicitNoSpeechError(error) {
                    // Empty, not broken: fall through to the last-chance pass.
                    AppLogger.transcription.info("Mic diarizer found no speech; deferring to the last-chance pass")
                    micResult = MicChannelResult(utterances: [], speakerContexts: [:], newlyCreatedProfileIds: [])
                }
                var splitMicUtterances = micResult.utterances
                var splitMicSpeakerContexts = micResult.speakerContexts
                var splitNewlyCreatedProfileIds = micResult.newlyCreatedProfileIds
                if splitMicUtterances.isEmpty {
                    // Same last-chance pass as the two-track pipeline: the
                    // diarizer found no words, so silence-split the mic track
                    // the way the default single-"You" mode does.
                    await MainActor.run {
                        self.processingStatus = "Checking again for quiet speech..."
                    }
                    splitMicUtterances = try await Self.lastChanceSpeechSweep(
                        tracks: [LastChanceSweepTrack(url: micURL, channel: .microphone)],
                        parakeet: parakeet,
                        language: languageContext,
                        droppedSegments: &droppedSegments
                    ).micUtterances
                    // Recovered words are not tied to any diarized voice.
                    splitMicSpeakerContexts = [:]
                    splitNewlyCreatedProfileIds = []
                }
                let mergedMicUtterances = Self.mergeConsecutiveUtterances(splitMicUtterances, maxGap: 1.5)
                guard !mergedMicUtterances.isEmpty else {
                    throw PipelineError.noSpeechDetected
                }

                let processingTime = Date().timeIntervalSince(processingStartTime)
                await MainActor.run {
                    self.processingStatus = "Transcription complete!"
                    self.isProcessing = false
                }
                onProgress?(1.0)

                AppLogger.transcription.info("Mic-only split transcription complete", [
                    "micUtterances": "\(mergedMicUtterances.count)",
                    "speakers": "\(Set(mergedMicUtterances.map { $0.speakerId }).count)",
                    "processingTime": "\(String(format: "%.1f", processingTime))s",
                    "droppedSegments": "\(droppedSegments)"
                ])

                return TranscriptionResult(
                    micUtterances: mergedMicUtterances,
                    systemUtterances: [],
                    micSpeakerContexts: splitMicSpeakerContexts,
                    newlyCreatedMicProfileIds: splitNewlyCreatedProfileIds,
                    duration: duration,
                    processingTime: processingTime,
                    droppedSegments: droppedSegments,
                    microphoneAudioOutcome: .usable,
                    systemAudioOutcome: .notProvided,
                    languageContext: languageContext,
                    diarization: diarizationRun
                )
            }

            let micSegments = Self.detectSpeechSegments(
                samples: micSamples,
                sampleRate: 16000,
                analysis: micSignalAnalysis
            )
            AppLogger.transcription.info("Mic-only audio segmented by silence", [
                "segments": "\(micSegments.count)"
            ])

            var micUtterances: [TranscriptionUtterance] = []
            var droppedSegments = 0
            for (index, segment) in micSegments.enumerated() {
                try Task.checkCancellation()
                let segmentSamples = AudioResampler.extractSlice(
                    from: micSamples,
                    sampleRate: 16000,
                    startTime: segment.start,
                    endTime: segment.end
                )
                guard let preparedSegment = Self.prepareMicSegmentForTranscription(
                    samples: segmentSamples,
                    sampleRate: 16000
                ) else {
                    droppedSegments += 1
                    continue
                }

                let text = try await parakeet.transcribeSegment(
                    samples: preparedSegment.samples,
                    source: .microphone,
                    language: languageContext
                )
                guard !text.isEmpty else {
                    droppedSegments += 1
                    continue
                }

                micUtterances.append(TranscriptionUtterance(
                    start: segment.start,
                    end: segment.end,
                    channel: 0,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: text
                ))

                let progress = 0.10 + (Double(index + 1) / Double(max(1, micSegments.count))) * 0.85
                onProgress?(progress)
            }

            micSamples = []
            let mergedMicUtterances = Self.mergeConsecutiveUtterances(micUtterances, maxGap: 1.5)
            guard !mergedMicUtterances.isEmpty else {
                throw PipelineError.noSpeechDetected
            }

            let processingTime = Date().timeIntervalSince(processingStartTime)
            await MainActor.run {
                self.processingStatus = "Transcription complete!"
                self.isProcessing = false
            }
            onProgress?(1.0)

            AppLogger.transcription.info("Mic-only transcription complete", [
                "micUtterances": "\(mergedMicUtterances.count)",
                "processingTime": "\(String(format: "%.1f", processingTime))s",
                "droppedSegments": "\(droppedSegments)"
            ])

            return TranscriptionResult(
                micUtterances: mergedMicUtterances,
                systemUtterances: [],
                duration: duration,
                processingTime: processingTime,
                droppedSegments: droppedSegments,
                microphoneAudioOutcome: .usable,
                systemAudioOutcome: .notProvided,
                languageContext: languageContext
            )
        } catch {
            await MainActor.run {
                self.error = "Transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }
}
