import Foundation
@preconcurrency import AVFoundation
import Accelerate
import FluidAudio

// MARK: - Local Multichannel Transcription

extension Transcription {

    /// Transcribe system audio using local Parakeet STT + offline diarization,
    /// with optional mic audio for mixed live meeting captures.
    ///
    /// Pipeline:
    /// 1. Load & resample the captured audio files to 16kHz mono
    /// 2. Run offline diarization (Nemotron or pyannote) on system audio -> speaker segments with embeddings
    /// 3. Transcribe each system-audio speaker segment with Parakeet
    /// 4. When present, transcribe mic audio with Parakeet.
    ///    - If `splitLocalSpeakers` is false (default), splits by silence and tags
    ///      every utterance as the single "You" speaker.
    ///    - If true, runs diarization on the mic channel too and threads
    ///      per-speaker embeddings through the same classification/matching path
    ///      used for system audio. Surfaces multiple local speakers in the naming sheet.
    /// 5. Match speaker embeddings against persistent SpeakerDatabase
    /// 6. Merge available utterances chronologically
    ///
    /// Note: nonisolated to keep heavy compute off the main thread
    nonisolated func transcribeMultichannel(
        micURL: URL?,
        systemURL: URL,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        speakerSeparation: SpeakerSeparationOptions? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {

        let parakeet = await MainActor.run { self.parakeet }
        let diarization = await MainActor.run { self.diarization }
        let speakerDB = await MainActor.run { self.speakerDB }
        // The voiceprint model releases after a minute idle; start reloading it
        // now so it overlaps resampling instead of the first re-embed.
        diarization.prewarmVoiceprintInBackground()

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        let processingStartTime = Date()

        do {
            let duration = try Self.longestAudioDuration(micURL: micURL, systemURL: systemURL)
            MeetingPipelineTimings.current?.recordRecordingLength(seconds: duration)

            onProgress?(0.0)

            // Step 1: Load and resample both audio files to 16kHz mono
            await MainActor.run {
                self.processingStatus = "Loading audio..."
            }

            AppLogger.transcription.info("Loading and resampling audio to 16kHz")
            let resampleStart = CFAbsoluteTimeGetCurrent()

            // Only an engine that detects the spoken language reads these
            // windows (Whisper); finding them scans both whole tracks. The
            // job's model is fixed by now, so this can be read before loading.
            var wantsLanguageSamples = false
            if languageSelection == .automatic {
                wantsLanguageSamples = await parakeet.usesRepresentativeLanguageSamples
            }

            // Both tracks become whole-meeting 16kHz buffers (~230MB per
            // channel per hour), declared `var` so each can be cleared (`= []`)
            // right after its last use below instead of staying alive for the
            // entire diarize → transcribe → merge run.
            //
            // The default mic path needs its buffer only in the mic phase. It
            // is measured here, released before the call track loads, and
            // loaded again at the start of the mic phase, so the two buffers
            // are never alive together and the mic isn't held through
            // diarization or system STT. Phase order, progress and error
            // handling stay the same.
            let releasesMicDuringSystemPhase = Self.releasesMicDuringSystemPhase(
                micURL: micURL,
                splitLocalSpeakers: splitLocalSpeakers,
                wantsLanguageSamples: wantsLanguageSamples
            )
            // Both load results are `var`s cleared right after unpacking: a
            // kept `Result` shares the array's storage, so `= []` on the
            // unpacked buffer alone wouldn't free it.
            var systemLoadResult: Result<[Float], Error>?
            var micLoadResult: Result<[Float], Error>? = nil
            if releasesMicDuringSystemPhase {
                micLoadResult = await MeetingPipelineTimings.measureAsync(.resample) {
                    Self.loadResampledTrack(url: micURL)
                }
            } else {
                // Resample both tracks at once. Each conversion streams 30 s
                // chunks into an output reserved up front, and both outputs are
                // held together below anyway, so running them in parallel only
                // adds one extra chunk buffer to the peak, not a second
                // whole-meeting copy. Timed once around the pair (wall time);
                // each load opts out so the overlap isn't counted twice.
                let (systemLoad, micLoad) = await MeetingPipelineTimings.measureAsync(.resample) {
                    async let systemLoad = Self.loadResampledTrack(url: systemURL)
                    async let micLoad = Self.loadResampledTrack(url: micURL)
                    return await (systemLoad, micLoad)
                }
                systemLoadResult = systemLoad
                micLoadResult = micLoad
            }

            var (micSamples, microphoneAudioOutcome) = Self.micTrack(from: micLoadResult)
            micLoadResult = nil
            if let _ = micURL {
                AppLogger.transcription.debug("Mic: \(micSamples.count) samples (\(String(format: "%.1f", Double(micSamples.count) / 16000))s)")
            } else {
                AppLogger.transcription.debug("Mic: skipped for system-audio-only transcription")
            }
            let micSignalAnalysis = Self.screenMicCaptureSignal(
                micURL: micURL,
                samples: &micSamples,
                outcome: &microphoneAudioOutcome
            )
            // Pre-compute mic energy per 100ms frame for embedding quality gating.
            // When the local user is speaking, system audio embeddings are contaminated
            // with their voice echo, producing unreliable remote speaker voiceprints.
            let micActivity = MeetingMicActivity(samples: micSamples, analysis: micSignalAnalysis)
            // What the system phase needs to know about the mic, kept as plain
            // values so it reads the same whether or not the buffer is released.
            let micSampleCount = micSamples.count
            let micTrackPresent = !micSamples.isEmpty

            if releasesMicDuringSystemPhase {
                micSamples = []
                systemLoadResult = await MeetingPipelineTimings.measureAsync(.resample) {
                    Self.loadResampledTrack(url: systemURL)
                }
            }
            var systemSamples: [Float]
            let systemAudioLoadError: Error?
            do {
                // Scoped so the unpacked tuple can't keep the buffer alive
                // past `systemSamples = []` below.
                let systemTrack = Self.systemTrack(from: systemLoadResult)
                systemSamples = systemTrack.samples
                systemAudioLoadError = systemTrack.loadError
            }
            systemLoadResult = nil

            let resampleTime = CFAbsoluteTimeGetCurrent() - resampleStart
            AppLogger.transcription.info("Resampling completed in \(String(format: "%.2f", resampleTime))s")

            AppLogger.transcription.debug("System: \(systemSamples.count) samples (\(String(format: "%.1f", Double(systemSamples.count) / 16000))s)")

            // Validate system audio has meaningful content (at least 1 second at 16kHz).
            // Without this, a failed system audio capture produces an empty transcript.
            let hasUsableSystemAudio = systemSamples.count >= 16000
            let systemAudioOutcome: TranscriptionResult.SystemAudioOutcome = hasUsableSystemAudio
                ? .usable
                : .unusable
            if !hasUsableSystemAudio {
                // The mic side degrades gracefully twice above; this side used
                // to throw even with a full-length mic track sitting next to
                // it — and `startTranscription` admits exactly that
                // combination by design (`hasUsableMicAudio` alone passes its
                // gate). `recordingTooShort` is both non-retryable and
                // non-recoverable, so that turned a good recording into a dead
                // failed-queue row the user could only dismiss. Route to the
                // mic-only pipeline instead, and only fail when neither track
                // has usable audio. `micSampleCount` is already 0 when the mic
                // track has no usable capture signal, so this reads real
                // usability rather than mere presence.
                if micURL != nil, micSampleCount >= 16000 {
                    AppLogger.transcription.warning("System audio too short or empty; transcribing microphone only", [
                        "systemSamples": "\(systemSamples.count)",
                        "micSamples": "\(micSampleCount)",
                        "fallback": "microphone_only"
                    ])
                    // Keep processing in this pipeline rather than delegating to
                    // the legacy single-"You" helper. The mic phase below
                    // preserves `splitLocalSpeakers`, including local diarization
                    // and speaker review when the user enabled it.
                    systemSamples = []
                } else {
                    AppLogger.transcription.error("System audio too short or empty", [
                        "samples": "\(systemSamples.count)",
                        "expectedMinimum": "16000"
                    ])
                    // Preserve the real decode/read failure for system-only
                    // recordings and imports. Converting it to a permanent
                    // `recordingTooShort(0)` hides retryable I/O or format errors.
                    if let systemAudioLoadError {
                        throw systemAudioLoadError
                    }
                    throw PipelineError.recordingTooShort(duration: Double(systemSamples.count) / 16000.0)
                }
            }

            let languageContext = try await parakeet.resolveLanguage(
                representativeSamples: wantsLanguageSamples
                    ? Self.representativeLanguageSamples(
                        tracks: [systemSamples, micSamples],
                        analyses: [nil, micSignalAnalysis]
                    ) : [],
                selection: languageSelection
            )

            onProgress?(0.10)

            // Step 2: Run offline diarization on system audio -> speaker segments
            await MainActor.run {
                self.processingStatus = "Analyzing speakers..."
            }

            AppLogger.transcription.info("Running offline diarization on system audio")
            // What diarized this meeting, read right before the first diarize
            // call so a Nemotron load failure records pyannote. Stays nil when
            // no diarizer runs.
            var diarizationRun: DiarizationRunDescriptor?
            let rawSegments: [SpeakerSegment]
            if hasUsableSystemAudio {
                diarizationRun = await Self.diarizationRunDescriptor(of: diarization)
                do {
                    rawSegments = try await Self.diarizeSystemAudio(
                        samples: systemSamples,
                        diarization: diarization,
                        hasMicTrack: micURL != nil && micTrackPresent,
                        clusteringThreshold: speakerSeparation?.clusteringThreshold
                    )
                } catch let error where Self.isExplicitNoSpeechError(error) {
                    // No mic track to carry the meeting. The diarizer's own
                    // speech detector can miss quiet or distant voices, so do
                    // not give up here: continue with no system segments and
                    // let the last-chance pass at the end look again. It
                    // throws the same `noSpeechDetected` when it finds nothing.
                    AppLogger.transcription.info("Diarizer found no speech in system audio; deferring to the last-chance pass")
                    rawSegments = []
                }
            } else {
                rawSegments = []
            }

            // Post-process diarization segments, but skip the broad pairwise merge
            // phase for PyAnnote/VBx output. Small-cluster absorption, unsupervised
            // split of a collapsed ID, same-voice consolidation (collapses one
            // over-segmented voice so the user names each person once), and
            // DB-informed split still run.
            let existingProfiles = speakerDB.allSpeakers()
            // Rejected-sample vetoes for matching (empty until a correction records one).
            let negativeExemplarsByProfile = speakerDB.negativeExemplarsByProfile()
            let speakerThresholds = diarization.activeSpeakerThresholds
            // Split generously, then merge smartly (SpeakerSeparation.swift): only when
            // the app turned it on for this meeting.
            let separatedSegments = speakerSeparation.map { SpeakerSeparation.apply(rawSegments, options: $0) } ?? rawSegments
            if speakerSeparation != nil {
                AppLogger.transcription.info("Applied speaker separation", [
                    "diarizer": "\(Set(rawSegments.map { $0.speakerId }).count)",
                    "after": "\(Set(separatedSegments.map { $0.speakerId }).count)",
                    "cap": speakerSeparation?.maxSpeakers.map { "\($0)" } ?? "none"
                ])
            }
            let speakerSegments = EmbeddingClusterer.postProcess(
                segments: separatedSegments,
                existingProfiles: existingProfiles,
                pairwiseMergeThreshold: nil,
                consolidationThreshold: speakerThresholds.consolidation,
                thresholds: speakerThresholds
            )

            let rawSpeakerCount = Set(rawSegments.map { $0.speakerId }).count
            let postProcessedSpeakerCount = Set(speakerSegments.map { $0.speakerId }).count
            AppLogger.transcription.info("Post-processed speaker segments", [
                "diarizer": "\(rawSpeakerCount)",
                "after": "\(postProcessedSpeakerCount)",
                "segments": "\(speakerSegments.count)"
            ])

            onProgress?(0.30)

            // Step 3: Transcribe each speaker segment with Parakeet
            await MainActor.run {
                self.processingStatus = "Transcribing system audio..."
            }

            var systemUtterances: [TranscriptionUtterance] = []
            var droppedSegments = 0
            let totalSegments = speakerSegments.count

            let identities = Self.resolveSystemSpeakerIdentities(
                speakerSegments: speakerSegments,
                existingProfiles: existingProfiles,
                negativeExemplarsByProfile: negativeExemplarsByProfile,
                speakerThresholds: speakerThresholds,
                speakerDB: speakerDB,
                micActiveFraction: { micActivity.activeFraction(startTime: $0, endTime: $1) }
            )
            let speakerMatchResults = identities.matchResults
            let speakerNewProfiles = identities.newProfiles
            let speakerIdRemap = identities.idRemap
            var systemSpeakerContexts = identities.speakerContexts

            func appendSystemUtterance(segment: SpeakerSegment, text: String) {
                // Skip empty transcriptions
                guard !text.isEmpty else { return }

                // Apply remap (unifies speakers that matched the same DB profile)
                let effectiveSpeakerId = speakerIdRemap[segment.speakerId] ?? segment.speakerId

                // Use the pre-computed per-speaker match result
                let persistentId: UUID?
                let similarity: Double?
                if let match = speakerMatchResults[effectiveSpeakerId] {
                    persistentId = match.persistentId
                    similarity = match.similarity
                } else {
                    persistentId = speakerNewProfiles[effectiveSpeakerId]
                    similarity = nil
                }

                systemUtterances.append(TranscriptionUtterance(
                    start: segment.startTime,
                    end: segment.endTime,
                    channel: 1,
                    speakerId: effectiveSpeakerId,
                    persistentSpeakerId: persistentId,
                    matchSimilarity: similarity,
                    transcript: text
                ))
            }

            // Short segments are packed into one full speech-to-text window
            // when the engine supports it (see SpeechSegmentPacking); the
            // utterances come out in the same order either way.
            var systemBatcher = SpeechSegmentBatcher<SpeakerSegment>(
                windowSamples: await parakeet.packedSegmentWindowSamples ?? 0
            )
            for (index, segment) in speakerSegments.enumerated() {
                // Allow cancellation between segments (user hit stop or app is terminating)
                try Task.checkCancellation()

                // Extract audio slice for this segment
                let segmentSamples = AudioResampler.extractSlice(
                    from: systemSamples,
                    sampleRate: 16000,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )

                // Skip segments shorter than 1s — Parakeet requires at least 16,000 samples.
                // A meeting made only of short answers is picked up by the
                // last-chance pass below, which pads them.
                guard segmentSamples.count >= 16000 else { droppedSegments += 1; continue }

                for batch in systemBatcher.add(segment, samples: segmentSamples) {
                    let texts = try await Self.transcribeSegmentBatch(
                        batch.map(\.samples),
                        engine: parakeet,
                        source: .system,
                        language: languageContext
                    )
                    for (entry, text) in zip(batch, texts) {
                        appendSystemUtterance(segment: entry.item, text: text)
                    }
                }

                // Update progress (30% to 65% during system transcription)
                let segmentProgress = 0.30 + (Double(index + 1) / Double(max(1, totalSegments))) * 0.35
                onProgress?(segmentProgress)
            }
            for batch in systemBatcher.finish() {
                let texts = try await Self.transcribeSegmentBatch(
                    batch.map(\.samples),
                    engine: parakeet,
                    source: .system,
                    language: languageContext
                )
                for (entry, text) in zip(batch, texts) {
                    appendSystemUtterance(segment: entry.item, text: text)
                }
            }

            // Segment slicing above was the last use of the whole-meeting
            // system buffer — release it before the mic phase so both
            // channels are never held through the rest of the pipeline.
            systemSamples = []

            AppLogger.transcription.info("System audio transcribed", ["utterances": "\(systemUtterances.count)", "speakers": "\(Set(systemUtterances.map { $0.speakerId }).count)"])

            var micUtterances: [TranscriptionUtterance] = []
            var micSpeakerContexts: [String: ChannelSpeakerContext] = [:]
            var newlyCreatedMicProfileIds: Set<UUID> = []
            var micDiarizerFoundNoSpeech = false

            if microphoneAudioOutcome == .usable, micURL != nil {
                do {
                    // Step 4: Transcribe mic audio.
                    // Two modes:
                    //   A) splitLocalSpeakers == false (default): silence-split, tag as single "You"
                    //   B) splitLocalSpeakers == true: diarize mic, run same classification path
                    //      used for system audio, emit per-speaker utterances
                    await MainActor.run {
                        self.processingStatus = "Transcribing mic audio..."
                    }
                    if releasesMicDuringSystemPhase, let micURL {
                        // Released before the call track loaded; a failure here
                        // takes the same fallback as any other mic failure.
                        micSamples = try Self.reloadReleasedMicTrack(url: micURL, expectedSampleCount: micSampleCount)
                    }

                    if splitLocalSpeakers {
                        // B) Mic diarization path
                        let diarizationMicSamples = AudioSignalRecovery.normalizeForSpeech(
                            samples: micSamples,
                            sampleRate: 16000,
                            analysis: micSignalAnalysis
                        ).samples
                        // Normalization above was the last use of the raw mic
                        // buffer in this mode — release it so only the normalized
                        // copy stays alive during mic diarization + transcription.
                        // (`diarizationMicSamples` itself dies at the end of this
                        // branch scope.)
                        micSamples = []
                        if diarizationRun == nil {
                            diarizationRun = await Self.diarizationRunDescriptor(of: diarization)
                        }
                        let micResult = try await Self.processMicChannelWithDiarization(
                            samples: diarizationMicSamples,
                            diarization: diarization,
                            parakeet: parakeet,
                            speakerDB: speakerDB,
                            existingProfiles: existingProfiles,
                            droppedSegments: &droppedSegments,
                            language: languageContext,
                            onProgress: onProgress
                        )
                        micUtterances = micResult.utterances
                        micSpeakerContexts = micResult.speakerContexts
                        newlyCreatedMicProfileIds = micResult.newlyCreatedProfileIds
                        AppLogger.transcription.info("Mic audio diarized + transcribed", [
                            "utterances": "\(micUtterances.count)",
                            "speakers": "\(Set(micUtterances.map { $0.speakerId }).count)",
                            "newProfiles": "\(newlyCreatedMicProfileIds.count)"
                        ])
                    } else {
                        // A) Default: silence-split, single speaker
                        // `micSamples` holds the same samples `micSignalAnalysis`
                        // measured (held or reloaded), so reuse it instead of
                        // scanning again.
                        let micSegments = Self.detectSpeechSegments(
                            samples: micSamples,
                            sampleRate: 16000,
                            analysis: micSignalAnalysis
                        )
                        AppLogger.transcription.info("Mic audio segmented by silence", ["segments": "\(micSegments.count)"])

                        struct PendingMicSegment {
                            let index: Int
                            let start: Double
                            let end: Double
                            let prepared: PreparedMicSegment
                        }
                        func appendMicUtterance(_ pending: PendingMicSegment, text: String) {
                            guard !text.isEmpty else {
                                var context = pending.prepared.analysis.context
                                context["segment_index"] = "\(pending.index)"
                                context["gain"] = String(format: "%.2f", pending.prepared.gain)
                                context["padded_samples"] = "\(pending.prepared.paddedSampleCount)"
                                AppLogger.transcription.warning("Mic segment returned empty transcription", context)
                                return
                            }

                            micUtterances.append(TranscriptionUtterance(
                                start: pending.start,
                                end: pending.end,
                                channel: 0,
                                speakerId: 0,
                                persistentSpeakerId: nil,
                                matchSimilarity: nil,
                                transcript: text
                            ))
                        }

                        var micBatcher = SpeechSegmentBatcher<PendingMicSegment>(
                            windowSamples: await parakeet.packedSegmentWindowSamples ?? 0
                        )
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

                            let pending = PendingMicSegment(
                                index: index,
                                start: segment.start,
                                end: segment.end,
                                prepared: preparedSegment
                            )
                            for batch in micBatcher.add(pending, samples: preparedSegment.samples) {
                                let texts = try await Self.transcribeSegmentBatch(
                                    batch.map(\.samples),
                                    engine: parakeet,
                                    source: .microphone,
                                    language: languageContext
                                )
                                for (entry, text) in zip(batch, texts) {
                                    appendMicUtterance(entry.item, text: text)
                                }
                            }

                            // Update progress (65% to 90% during mic transcription)
                            let micProgress = 0.65 + (Double(index + 1) / Double(max(1, micSegments.count))) * 0.25
                            onProgress?(micProgress)
                        }
                        for batch in micBatcher.finish() {
                            let texts = try await Self.transcribeSegmentBatch(
                                batch.map(\.samples),
                                engine: parakeet,
                                source: .microphone,
                                language: languageContext
                            )
                            for (entry, text) in zip(batch, texts) {
                                appendMicUtterance(entry.item, text: text)
                            }
                        }

                        // Segment slicing above was the last use of the
                        // whole-meeting mic buffer — release it before the
                        // merge/save phase.
                        micSamples = []

                        AppLogger.transcription.info("Mic audio transcribed", ["utterances": "\(micUtterances.count)"])
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Mic-only failures must not erase a completed system-audio
                    // transcript. Cancellation still wins; every other mic
                    // decode/diarization/STT failure becomes an honest partial
                    // result and keeps the original artifact for retry.
                    try Task.checkCancellation()
                    if Self.isExplicitNoSpeechError(error) {
                        // The mic diarizer's speech detector found nothing.
                        // That is an empty mic channel, not a broken one, and
                        // it used to end the whole meeting as "No speech
                        // found" even with a loud mic. Keep the outcome
                        // usable so the last-chance pass below can still
                        // silence-split the mic track. The diarizer throws
                        // before any speaker profile is written.
                        micSamples = []
                        micUtterances = []
                        micSpeakerContexts = [:]
                        newlyCreatedMicProfileIds = []
                        micDiarizerFoundNoSpeech = true
                        AppLogger.transcription.info("Mic diarizer found no speech; deferring to the last-chance pass")
                    } else {
                        guard !systemUtterances.isEmpty else {
                            throw error
                        }
                        micSamples = []
                        micUtterances = []
                        micSpeakerContexts = [:]
                        newlyCreatedMicProfileIds = []
                        microphoneAudioOutcome = .unusable
                        AppLogger.transcription.warning("Microphone processing failed; continuing with system audio", [
                            "fallback": "system_audio_only",
                            "errorType": "\(type(of: error))"
                        ])
                    }
                }
            } else {
                AppLogger.transcription.info("Mic audio skipped", ["reason": "system_audio_only"])
            }

            onProgress?(0.95)

            let processingTime = Date().timeIntervalSince(processingStartTime)

            // Last-chance pass over the tracks whose words depended on the
            // diarizer's speech detector, which can miss quiet or distant
            // voices:
            // - the call side, only when the whole meeting came out empty
            //   (otherwise a quiet remote track is not worth a second STT run);
            // - the split-mode mic whenever it produced no words, even if the
            //   call side did, so voices in the room are not dropped silently.
            // The default mic path already silence-split the whole mic track,
            // so repeating it would only reproduce the same empty result.
            let sweepsSystem = systemUtterances.isEmpty && micUtterances.isEmpty && hasUsableSystemAudio
            let sweepsMic = splitLocalSpeakers && microphoneAudioOutcome == .usable && micUtterances.isEmpty
            if sweepsSystem || sweepsMic {
                await MainActor.run {
                    self.processingStatus = "Checking again for quiet speech..."
                }
                var sweepTracks: [LastChanceSweepTrack] = []
                if sweepsSystem {
                    sweepTracks.append(LastChanceSweepTrack(url: systemURL, channel: .system))
                }
                if sweepsMic, let micURL {
                    sweepTracks.append(LastChanceSweepTrack(url: micURL, channel: .microphone))
                }
                let sweep = try await Self.lastChanceSpeechSweep(
                    tracks: sweepTracks,
                    parakeet: parakeet,
                    language: languageContext,
                    droppedSegments: &droppedSegments
                )
                // Any speaker the diarizer did find said nothing STT could
                // read, so its identity must not be pinned on the recovered
                // words. Recovered words stay unnamed ("Speaker 1" / "You").
                if !sweep.systemUtterances.isEmpty {
                    systemUtterances = sweep.systemUtterances
                    systemSpeakerContexts = [:]
                }
                if !sweep.micUtterances.isEmpty {
                    micUtterances = sweep.micUtterances
                    micSpeakerContexts = [:]
                    newlyCreatedMicProfileIds = []
                } else if micDiarizerFoundNoSpeech, !systemUtterances.isEmpty {
                    // Nothing recoverable in the room either. Say so in the
                    // saved transcript's health, as before this pass existed,
                    // instead of listing a healthy mic with no lines.
                    microphoneAudioOutcome = .unusable
                }
            }

            // Merge consecutive utterances from the same speaker when the gap is small.
            // Diarizer segments often break mid-sentence, producing fragments like:
            //   [00:03] "Opus four point six and"
            //   [00:10] "Sonnet four point six just went live"
            // Merging produces cleaner, more readable transcripts.
            let remappedSpeakerSegments = speakerSegments.map { segment in
                segment.withSpeakerId(speakerIdRemap[segment.speakerId] ?? segment.speakerId)
            }
            let mergedSystemUtterances = Self.mergeConsecutiveUtterances(
                systemUtterances,
                maxGap: 1.5,
                interruptingSegments: remappedSpeakerSegments
            )
            let mergedMicUtterances = Self.mergeConsecutiveUtterances(micUtterances, maxGap: 1.5)
            guard !mergedSystemUtterances.isEmpty || !mergedMicUtterances.isEmpty else {
                AppLogger.transcription.warning("No speech detected after local transcription", [
                    "droppedSegments": "\(droppedSegments)"
                ])
                throw PipelineError.noSpeechDetected
            }

            await MainActor.run {
                self.processingStatus = "Transcription complete!"
                self.isProcessing = false
            }

            onProgress?(1.0)

            AppLogger.transcription.info("Local transcription complete", [
                "micUtterances": "\(mergedMicUtterances.count)",
                "systemUtterances": "\(mergedSystemUtterances.count)",
                "systemSpeakers": "\(Set(mergedSystemUtterances.map { $0.speakerId }).count)",
                "processingTime": "\(String(format: "%.1f", processingTime))s",
                "mergedSystem": "\(systemUtterances.count) → \(mergedSystemUtterances.count)",
                "mergedMic": "\(micUtterances.count) → \(mergedMicUtterances.count)"
            ])

            return TranscriptionResult(
                micUtterances: mergedMicUtterances,
                systemUtterances: mergedSystemUtterances,
                systemSpeakerContexts: systemSpeakerContexts,
                micSpeakerContexts: micSpeakerContexts,
                newlyCreatedMicProfileIds: newlyCreatedMicProfileIds,
                duration: duration,
                processingTime: processingTime,
                droppedSegments: droppedSegments,
                microphoneAudioOutcome: microphoneAudioOutcome,
                systemAudioOutcome: systemAudioOutcome,
                languageContext: languageContext,
                diarization: diarizationRun
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
