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
    /// 2. Run PyAnnote offline diarization on system audio -> speaker segments with embeddings
    /// 3. Transcribe each system-audio speaker segment with Parakeet
    /// 4. When present, transcribe mic audio with Parakeet.
    ///    - If `splitLocalSpeakers` is false (default), splits by silence and tags
    ///      every utterance as the single "You" speaker.
    ///    - If true, runs PyAnnote diarization on the mic channel too and threads
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
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {

        let parakeet = await MainActor.run { self.parakeet }
        let diarization = await MainActor.run { self.diarization }
        let speakerDB = await MainActor.run { self.speakerDB }

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        let processingStartTime = Date()

        do {
            let duration = try Self.longestAudioDuration(micURL: micURL, systemURL: systemURL)

            onProgress?(0.0)

            // Step 1: Load and resample both audio files to 16kHz mono
            await MainActor.run {
                self.processingStatus = "Loading audio..."
            }

            AppLogger.transcription.info("Loading and resampling audio to 16kHz")
            let resampleStart = CFAbsoluteTimeGetCurrent()

            // Load sequentially to avoid both resampling buffers in memory simultaneously.
            // async let forces concurrent resampling (~460MB peak for long recordings);
            // sequential means only one resampling buffer exists at a time.
            let systemSamples = try AudioResampler.loadAndResample(url: systemURL, targetRate: 16000)
            let micSamples: [Float]
            if let micURL {
                micSamples = try AudioResampler.loadAndResample(url: micURL, targetRate: 16000)
            } else {
                micSamples = []
            }

            let resampleTime = CFAbsoluteTimeGetCurrent() - resampleStart
            AppLogger.transcription.info("Resampling completed in \(String(format: "%.2f", resampleTime))s")

            AppLogger.transcription.debug("System: \(systemSamples.count) samples (\(String(format: "%.1f", Double(systemSamples.count) / 16000))s)")
            if let _ = micURL {
                AppLogger.transcription.debug("Mic: \(micSamples.count) samples (\(String(format: "%.1f", Double(micSamples.count) / 16000))s)")
            } else {
                AppLogger.transcription.debug("Mic: skipped for system-audio-only transcription")
            }

            let micSignalAnalysis: AudioSignalAnalysis?
            if micURL != nil, !micSamples.isEmpty {
                let rawMicAnalysis = AudioSignalRecovery.analyze(samples: micSamples, sampleRate: 16000)
                var context = rawMicAnalysis.context
                context["suggested_gain"] = String(format: "%.2f", AudioSignalRecovery.normalizationGain(for: rawMicAnalysis))
                AppLogger.transcription.info("Analyzed meeting mic signal", context)
                micSignalAnalysis = rawMicAnalysis
            } else {
                micSignalAnalysis = nil
            }

            // Validate system audio has meaningful content (at least 1 second at 16kHz).
            // Without this, a failed system audio capture produces an empty transcript.
            guard systemSamples.count >= 16000 else {
                AppLogger.transcription.error("System audio too short or empty", [
                    "samples": "\(systemSamples.count)",
                    "expectedMinimum": "16000"
                ])
                throw PipelineError.recordingTooShort(duration: Double(systemSamples.count) / 16000.0)
            }

            // Pre-compute mic energy per 100ms frame for embedding quality gating.
            // When the local user is speaking, system audio embeddings are contaminated
            // with their voice echo, producing unreliable remote speaker voiceprints.
            let micEnergyFrameDuration = 0.1  // 100ms frames
            let micFrameSize = Int(16000.0 * micEnergyFrameDuration)  // 1600 samples
            let micFrameCount = micSamples.count / micFrameSize
            var micEnergyPerFrame = [Float](repeating: 0, count: micFrameCount)

            micSamples.withUnsafeBufferPointer { ptr in
                // Security: guard against nil baseAddress (empty buffer) before pointer arithmetic
                guard let baseAddr = ptr.baseAddress else { return }
                for i in 0..<micFrameCount {
                    let start = i * micFrameSize
                    var sumSquares: Float = 0
                    vDSP_dotpr(baseAddr + start, 1,
                               baseAddr + start, 1,
                               &sumSquares,
                               vDSP_Length(micFrameSize))
                    micEnergyPerFrame[i] = sqrt(sumSquares / Float(micFrameSize))
                }
            }
            let micActiveThreshold = AudioSignalRecovery.speechDetectionThreshold(
                for: micSignalAnalysis ?? AudioSignalRecovery.analyze(samples: [], sampleRate: 16000)
            )

            /// Returns the fraction of a time range where the local mic was active (0.0-1.0).
            func micActiveFraction(startTime: Double, endTime: Double) -> Double {
                let startFrame = max(0, Int(startTime / micEnergyFrameDuration))
                let endFrame = min(micFrameCount, Int(endTime / micEnergyFrameDuration))
                guard endFrame > startFrame else { return 0 }
                var activeCount = 0
                for i in startFrame..<endFrame where micEnergyPerFrame[i] >= micActiveThreshold { activeCount += 1 }
                return Double(activeCount) / Double(endFrame - startFrame)
            }

            onProgress?(0.10)

            // Step 2: Run offline diarization on system audio -> speaker segments
            await MainActor.run {
                self.processingStatus = "Analyzing speakers..."
            }

            AppLogger.transcription.info("Running offline diarization on system audio")
            let rawSegments = try await diarization.diarizeOffline(samples: systemSamples, sampleRate: 16000)

            // Post-process diarization segments, but skip the broad pairwise merge
            // phase for PyAnnote/VBx output. Small-cluster absorption, same-voice
            // consolidation (collapses one over-segmented voice so the user names
            // each person once), and DB-informed split still run.
            let existingProfiles = speakerDB.allSpeakers()
            let speakerSegments = EmbeddingClusterer.postProcess(
                segments: rawSegments,
                existingProfiles: existingProfiles,
                pairwiseMergeThreshold: nil
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

            // Aggregate embeddings per Sortformer speaker ID for stable matching.
            // Instead of matching each segment independently (noisy), we compute
            // a mean embedding per speaker and match that once against the DB.
            // Quality gate: skip low-quality segments to prevent noisy embeddings
            // from polluting the speaker database.
            var embeddingsPerSpeaker: [Int: [[Float]]] = [:]
            var embeddingWeights: [Int: [Float]] = [:]  // 1.0 = clean, 0.3 = mic-contaminated
            var filteredSegmentCount = 0
            var micContaminatedCount = 0
            for segment in speakerSegments {
                if let embedding = segment.embedding, !embedding.isEmpty {
                    // Skip segments with very low quality scores — they produce noisy embeddings
                    if segment.qualityScore < 0.3 {
                        filteredSegmentCount += 1
                        continue
                    }
                    // Skip very short segments (< 1.0s) — insufficient audio for reliable voiceprint
                    if segment.duration < 1.0 {
                        filteredSegmentCount += 1
                        continue
                    }

                    // Mic energy gating: when the local user was speaking, system audio
                    // embeddings are contaminated with their voice (Zoom echo residual).
                    let micFraction = micActiveFraction(startTime: segment.startTime, endTime: segment.endTime)

                    guard let weight = Self.embeddingWeight(forMicFraction: micFraction) else {
                        // >80% overlap with local mic: skip entirely
                        micContaminatedCount += 1
                        continue
                    }
                    embeddingsPerSpeaker[segment.speakerId, default: []].append(embedding)
                    embeddingWeights[segment.speakerId, default: []].append(weight)
                }
            }
            if filteredSegmentCount > 0 {
                AppLogger.transcription.info("Filtered low-quality segments from embedding aggregation", ["filtered": "\(filteredSegmentCount)", "total": "\(speakerSegments.count)"])
            }
            if micContaminatedCount > 0 {
                AppLogger.transcription.info("Mic-contaminated segments excluded from embedding aggregation", [
                    "excluded": "\(micContaminatedCount)",
                    "total": "\(speakerSegments.count)"
                ])
            }

            // Ghost speaker fix: speakers whose segments were ALL filtered out have no
            // aggregated embedding. Use their best available raw segment embedding as a
            // fallback so every utterance gets a persistent UUID (critical for agent output).
            let allSpeakerIds = Set(speakerSegments.map { $0.speakerId })
            let ghostSpeakerIds = allSpeakerIds.subtracting(embeddingsPerSpeaker.keys)
            var ghostSpeakerIdSet = Set<Int>()
            for ghostId in ghostSpeakerIds {
                let bestSegment = speakerSegments
                    .filter { segment in
                        guard segment.speakerId == ghostId, let embedding = segment.embedding else { return false }
                        return !embedding.isEmpty
                    }
                    .max(by: { $0.qualityScore < $1.qualityScore })
                if let segment = bestSegment, let embedding = segment.embedding {
                    embeddingsPerSpeaker[ghostId] = [embedding]
                    ghostSpeakerIdSet.insert(ghostId)
                    AppLogger.transcription.info("Ghost speaker recovered with best-effort embedding", [
                        "speakerId": "\(ghostId)",
                        "qualityScore": String(format: "%.2f", segment.qualityScore)
                    ])
                }
            }

            // Match each speaker's mean embedding against the DB once
            // (existingProfiles was already snapshotted above for post-processing)
            var speakerMatchResults: [Int: (persistentId: UUID, similarity: Double)] = [:]
            var speakerNewProfiles: [Int: UUID] = [:]
            var speakerIdRemap: [Int: Int] = [:]

            // Pre-compute unweighted means for non-ghost speakers so the ghost merge inner
            // loop doesn't recompute the same means once per ghost (O(G×N) → O(N)).
            let nonGhostMeans: [Int: [Float]] = embeddingsPerSpeaker
                .filter { !ghostSpeakerIdSet.contains($0.key) }
                .reduce(into: [:]) { $0[$1.key] = Self.computeMeanEmbedding($1.value) }

            for (speakerId, embeddings) in embeddingsPerSpeaker {
                let weights = embeddingWeights[speakerId] ?? Array(repeating: Float(1.0), count: embeddings.count)
                let meanEmbedding = Self.computeWeightedMeanEmbedding(embeddings, weights: weights)

                let isGhost = ghostSpeakerIdSet.contains(speakerId)

                // Ghost speakers have unreliable embeddings (laughter, coughs, codec artifacts).
                // Prefer force-merging into the closest real speaker, but if every detected
                // speaker is a ghost we still need a persistent UUID for later transcript
                // metadata updates, so fall back to creating a best-effort profile.
                if isGhost {
                    let mergeCandidate = Self.bestGhostSpeakerMergeCandidate(
                        for: meanEmbedding,
                        nonGhostMeans: nonGhostMeans
                    )
                    if let candidate = mergeCandidate, candidate.similarity >= Self.ghostSpeakerMergeSimilarityFloor {
                        speakerIdRemap[speakerId] = candidate.speakerId
                        AppLogger.transcription.info("Ghost speaker force-merged", [
                            "ghostSpk": "\(speakerId)",
                            "into": "\(candidate.speakerId)",
                            "similarity": String(format: "%.3f", candidate.similarity),
                            "threshold": String(format: "%.2f", Self.ghostSpeakerMergeSimilarityFloor)
                        ])
                    } else {
                        let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                        speakerNewProfiles[speakerId] = newProfile.id
                        var context = [
                            "speakerId": "\(speakerId)",
                            "threshold": String(format: "%.2f", Self.ghostSpeakerMergeSimilarityFloor)
                        ]
                        if let candidate = mergeCandidate {
                            context["bestNonGhostSpk"] = "\(candidate.speakerId)"
                            context["similarity"] = String(format: "%.3f", candidate.similarity)
                            context["reason"] = "below-minimum-similarity"
                        } else {
                            context["reason"] = "no-non-ghost-speaker-to-merge-into"
                        }
                        AppLogger.transcription.warning("Ghost speaker kept as standalone best-effort profile", context)
                    }
                    continue
                }

                // Adaptive threshold: require higher similarity when we have fewer segments.
                // A single 2s segment can false-match at 0.79; 4+ segments give a reliable mean.
                let adaptiveThreshold: Double = switch embeddings.count {
                    case 1: 0.85       // single segment — need near-certainty
                    case 2...3: 0.78   // few segments — still cautious
                    default: 0.70      // 4+ segments — reliable mean embedding
                }

                // Match only against profiles that existed BEFORE this recording
                if let matchResult = Self.matchAgainstProfiles(meanEmbedding, profiles: existingProfiles, threshold: adaptiveThreshold) {
                    speakerMatchResults[speakerId] = (matchResult.profileId, matchResult.similarity)
                    _ = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: matchResult.profileId)
                    let matchedProfile = existingProfiles.first(where: { $0.id == matchResult.profileId })
                    AppLogger.transcription.info("Speaker matched DB profile", [
                        "speakerId": "\(speakerId)",
                        "similarity": String(format: "%.3f", matchResult.similarity),
                        "threshold": String(format: "%.2f", adaptiveThreshold),
                        "segmentsAveraged": "\(embeddings.count)",
                        "profileId": matchResult.profileId.uuidString,
                        "profileCallCount": "\(matchedProfile?.callCount ?? 0)"
                    ])
                } else {
                    let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                    speakerNewProfiles[speakerId] = newProfile.id
                    AppLogger.transcription.info("Speaker new profile created", [
                        "speakerId": "\(speakerId)",
                        "threshold": String(format: "%.2f", adaptiveThreshold),
                        "segmentsAveraged": "\(embeddings.count)"
                    ])
                }
            }

            // Merge speaker IDs that matched the same DB profile.
            // Fixes cross-cluster fragmentation: if Sortformer split one person
            // into spk1 and spk3, and DB matching identified both as the same
            // profile, unify them under the speaker ID with the most segments.
            let profileToSpeakers = Dictionary(grouping: speakerMatchResults.keys) { speakerMatchResults[$0]?.persistentId }
            for (profileId, matchedSpeakerIds) in profileToSpeakers where profileId != nil && matchedSpeakerIds.count >= 2 {
                let sorted = matchedSpeakerIds.sorted { a, b in
                    embeddingsPerSpeaker[a]?.count ?? 0 > embeddingsPerSpeaker[b]?.count ?? 0
                }
                let canonical = sorted[0]
                for other in sorted.dropFirst() {
                    speakerIdRemap[other] = canonical
                }
                AppLogger.transcription.info("Merged speaker IDs with same DB profile", [
                    "merged": sorted.dropFirst().map { "spk\($0)" }.joined(separator: "+"),
                    "canonical": "spk\(canonical)"
                ])
            }

            var systemSpeakerContexts: [String: ChannelSpeakerContext] = [:]
            let effectiveSpeakerIds = Set(
                speakerSegments.map { speakerIdRemap[$0.speakerId] ?? $0.speakerId }
            )

            for effectiveSpeakerId in effectiveSpeakerIds {
                let persistentId = speakerMatchResults[effectiveSpeakerId]?.persistentId
                    ?? speakerNewProfiles[effectiveSpeakerId]
                guard let persistentId else { continue }

                let sessionEmbedding: [Float]?
                if let embeddings = embeddingsPerSpeaker[effectiveSpeakerId], !embeddings.isEmpty {
                    let weights = embeddingWeights[effectiveSpeakerId]
                        ?? Array(repeating: Float(1.0), count: embeddings.count)
                    sessionEmbedding = Self.computeWeightedMeanEmbedding(embeddings, weights: weights)
                } else {
                    sessionEmbedding = nil
                }

                let matchedProfileSnapshot = speakerMatchResults[effectiveSpeakerId]
                    .flatMap { match in
                        existingProfiles.first(where: { $0.id == match.persistentId })
                    }

                systemSpeakerContexts[String(effectiveSpeakerId)] = ChannelSpeakerContext(
                    persistentSpeakerId: persistentId,
                    sessionEmbedding: sessionEmbedding,
                    matchedProfileSnapshot: matchedProfileSnapshot,
                    matchSimilarity: speakerMatchResults[effectiveSpeakerId]?.similarity
                )
            }

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

                // Skip segments shorter than 1s — Parakeet requires at least 16,000 samples
                guard segmentSamples.count >= 16000 else { droppedSegments += 1; continue }

                let text = try await parakeet.transcribeSegment(samples: segmentSamples, source: .system)

                // Skip empty transcriptions
                guard !text.isEmpty else { continue }

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

                // Update progress (30% to 65% during system transcription)
                let segmentProgress = 0.30 + (Double(index + 1) / Double(max(1, totalSegments))) * 0.35
                onProgress?(segmentProgress)
            }

            AppLogger.transcription.info("System audio transcribed", ["utterances": "\(systemUtterances.count)", "speakers": "\(Set(systemUtterances.map { $0.speakerId }).count)"])

            var micUtterances: [TranscriptionUtterance] = []
            var micSpeakerContexts: [String: ChannelSpeakerContext] = [:]
            var newlyCreatedMicProfileIds: Set<UUID> = []

            if micURL != nil {
                // Step 4: Transcribe mic audio.
                // Two modes:
                //   A) splitLocalSpeakers == false (default): silence-split, tag as single "You"
                //   B) splitLocalSpeakers == true: diarize mic, run same classification path
                //      used for system audio, emit per-speaker utterances
                await MainActor.run {
                    self.processingStatus = "Transcribing mic audio..."
                }

                if splitLocalSpeakers {
                    // B) Mic diarization path
                    let diarizationMicSamples = AudioSignalRecovery.normalizeForSpeech(
                        samples: micSamples,
                        sampleRate: 16000,
                        analysis: micSignalAnalysis
                    ).samples
                    let micResult = try await Self.processMicChannelWithDiarization(
                        samples: diarizationMicSamples,
                        diarization: diarization,
                        parakeet: parakeet,
                        speakerDB: speakerDB,
                        existingProfiles: existingProfiles,
                        droppedSegments: &droppedSegments,
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
                    let micSegments = Self.detectSpeechSegments(samples: micSamples, sampleRate: 16000)
                    AppLogger.transcription.info("Mic audio segmented by silence", ["segments": "\(micSegments.count)"])

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

                        let text = try await parakeet.transcribeSegment(samples: preparedSegment.samples, source: .microphone)
                        guard !text.isEmpty else {
                            var context = preparedSegment.analysis.context
                            context["segment_index"] = "\(index)"
                            context["gain"] = String(format: "%.2f", preparedSegment.gain)
                            context["padded_samples"] = "\(preparedSegment.paddedSampleCount)"
                            AppLogger.transcription.warning("Mic segment returned empty transcription", context)
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

                        // Update progress (65% to 90% during mic transcription)
                        let micProgress = 0.65 + (Double(index + 1) / Double(max(1, micSegments.count))) * 0.25
                        onProgress?(micProgress)
                    }

                    AppLogger.transcription.info("Mic audio transcribed", ["utterances": "\(micUtterances.count)"])
                }
            } else {
                AppLogger.transcription.info("Mic audio skipped", ["reason": "system_audio_only"])
            }

            onProgress?(0.95)

            let processingTime = Date().timeIntervalSince(processingStartTime)

            // Merge consecutive utterances from the same speaker when the gap is small.
            // Diarizer segments often break mid-sentence, producing fragments like:
            //   [00:03] "Opus four point six and"
            //   [00:10] "Sonnet four point six just went live"
            // Merging produces cleaner, more readable transcripts.
            let mergedSystemUtterances = Self.mergeConsecutiveUtterances(systemUtterances, maxGap: 1.5)
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
                droppedSegments: droppedSegments
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

    nonisolated private static func longestAudioDuration(micURL: URL?, systemURL: URL) throws -> TimeInterval {
        var durations = [try audioDuration(at: systemURL)]
        if let micURL {
            durations.append(try audioDuration(at: micURL))
        }
        return durations.max() ?? 0
    }

    nonisolated private static func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Mic Channel Diarization

    /// Result of running diarization + classification on the mic channel.
    struct MicChannelResult {
        let utterances: [TranscriptionUtterance]
        let speakerContexts: [String: ChannelSpeakerContext]
        let newlyCreatedProfileIds: Set<UUID>
    }

    struct GhostSpeakerMergeCandidate: Equatable {
        let speakerId: Int
        let similarity: Double
    }

    /// Ghost speakers only have a best-effort embedding from segments that were
    /// too short, low-quality, or contaminated for normal profile matching. Keep
    /// the auto-merge floor high enough that uncertain voices survive to review.
    nonisolated static let ghostSpeakerMergeSimilarityFloor: Double = 0.72

    nonisolated static func bestGhostSpeakerMergeCandidate(
        for meanEmbedding: [Float],
        nonGhostMeans: [Int: [Float]]
    ) -> GhostSpeakerMergeCandidate? {
        var bestCandidate: GhostSpeakerMergeCandidate?
        for (otherId, otherMean) in nonGhostMeans {
            let similarity = cosineSimilarityStatic(meanEmbedding, otherMean)
            guard bestCandidate == nil || similarity > bestCandidate!.similarity else { continue }
            bestCandidate = GhostSpeakerMergeCandidate(speakerId: otherId, similarity: similarity)
        }
        return bestCandidate
    }

    /// Diarize + transcribe the mic channel when local-speaker split is on.
    /// Mirrors the system-audio classification path but skips the cross-channel
    /// contamination gate (there's nothing to gate against inside mic processing itself).
    /// Uses the pre-run `existingProfiles` snapshot so both channels match against
    /// the same stable set of DB profiles.
    nonisolated static func processMicChannelWithDiarization(
        samples: [Float],
        diarization: any DiarizationEngine,
        parakeet: any SpeechToTextEngine,
        speakerDB: any SpeakerStore,
        existingProfiles: [SpeakerProfile],
        droppedSegments: inout Int,
        onProgress: ((Double) -> Void)?
    ) async throws -> MicChannelResult {

        AppLogger.transcription.info("Running offline diarization on mic audio")
        let rawSegments = try await diarization.diarizeOffline(samples: samples, sampleRate: 16000)

        let speakerSegments = EmbeddingClusterer.postProcess(
            segments: rawSegments,
            existingProfiles: existingProfiles,
            pairwiseMergeThreshold: nil
        )

        let rawSpeakerCount = Set(rawSegments.map { $0.speakerId }).count
        let postProcessedSpeakerCount = Set(speakerSegments.map { $0.speakerId }).count
        AppLogger.transcription.info("Post-processed mic speaker segments", [
            "diarizer": "\(rawSpeakerCount)",
            "after": "\(postProcessedSpeakerCount)",
            "segments": "\(speakerSegments.count)"
        ])

        // Aggregate embeddings per diarizer speaker ID. Same quality gates as the system
        // path (>=0.3 quality, >=1.0s duration). No cross-channel contamination gate —
        // codex review flagged symmetric weighting as a recall killer for normal cross-talk.
        var embeddingsPerSpeaker: [Int: [[Float]]] = [:]
        var filteredSegmentCount = 0
        for segment in speakerSegments {
            if let embedding = segment.embedding, !embedding.isEmpty {
                if segment.qualityScore < 0.3 { filteredSegmentCount += 1; continue }
                if segment.duration < 1.0 { filteredSegmentCount += 1; continue }
                embeddingsPerSpeaker[segment.speakerId, default: []].append(embedding)
            }
        }
        if filteredSegmentCount > 0 {
            AppLogger.transcription.info("Filtered low-quality mic segments", [
                "filtered": "\(filteredSegmentCount)",
                "total": "\(speakerSegments.count)"
            ])
        }

        // Ghost speaker fix: same as system path.
        let allSpeakerIds = Set(speakerSegments.map { $0.speakerId })
        let ghostSpeakerIds = allSpeakerIds.subtracting(embeddingsPerSpeaker.keys)
        var ghostSpeakerIdSet = Set<Int>()
        for ghostId in ghostSpeakerIds {
            let bestSegment = speakerSegments
                .filter { segment in
                    guard segment.speakerId == ghostId, let embedding = segment.embedding else { return false }
                    return !embedding.isEmpty
                }
                .max(by: { $0.qualityScore < $1.qualityScore })
            if let segment = bestSegment, let embedding = segment.embedding {
                embeddingsPerSpeaker[ghostId] = [embedding]
                ghostSpeakerIdSet.insert(ghostId)
            }
        }

        var speakerMatchResults: [Int: (persistentId: UUID, similarity: Double)] = [:]
        var speakerNewProfiles: [Int: UUID] = [:]
        var speakerIdRemap: [Int: Int] = [:]
        var newlyCreatedProfileIds: Set<UUID> = []

        // Pre-compute unweighted means for non-ghost speakers so the ghost merge inner
        // loop doesn't recompute the same means once per ghost (O(G×N) → O(N)).
        let nonGhostMeans: [Int: [Float]] = embeddingsPerSpeaker
            .filter { !ghostSpeakerIdSet.contains($0.key) }
            .reduce(into: [:]) { $0[$1.key] = Self.computeMeanEmbedding($1.value) }

        for (speakerId, embeddings) in embeddingsPerSpeaker {
            let meanEmbedding = Self.computeMeanEmbedding(embeddings)
            let isGhost = ghostSpeakerIdSet.contains(speakerId)

            if isGhost {
                let mergeCandidate = Self.bestGhostSpeakerMergeCandidate(
                    for: meanEmbedding,
                    nonGhostMeans: nonGhostMeans
                )
                if let candidate = mergeCandidate, candidate.similarity >= Self.ghostSpeakerMergeSimilarityFloor {
                    speakerIdRemap[speakerId] = candidate.speakerId
                } else {
                    let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                    speakerNewProfiles[speakerId] = newProfile.id
                    newlyCreatedProfileIds.insert(newProfile.id)
                }
                continue
            }

            let adaptiveThreshold: Double = switch embeddings.count {
                case 1: 0.85
                case 2...3: 0.78
                default: 0.70
            }

            if let matchResult = Self.matchAgainstProfiles(meanEmbedding, profiles: existingProfiles, threshold: adaptiveThreshold) {
                speakerMatchResults[speakerId] = (matchResult.profileId, matchResult.similarity)
                _ = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: matchResult.profileId)
            } else {
                let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                speakerNewProfiles[speakerId] = newProfile.id
                newlyCreatedProfileIds.insert(newProfile.id)
            }
        }

        // Cross-cluster merge: same-DB-profile speakers collapse.
        let profileToSpeakers = Dictionary(grouping: speakerMatchResults.keys) { speakerMatchResults[$0]?.persistentId }
        for (profileId, matchedSpeakerIds) in profileToSpeakers where profileId != nil && matchedSpeakerIds.count >= 2 {
            let sorted = matchedSpeakerIds.sorted { a, b in
                embeddingsPerSpeaker[a]?.count ?? 0 > embeddingsPerSpeaker[b]?.count ?? 0
            }
            let canonical = sorted[0]
            for other in sorted.dropFirst() { speakerIdRemap[other] = canonical }
        }

        // Build speaker contexts keyed by effective speakerId (post-remap).
        var speakerContexts: [String: ChannelSpeakerContext] = [:]
        let effectiveSpeakerIds = Set(speakerSegments.map { speakerIdRemap[$0.speakerId] ?? $0.speakerId })
        for effectiveSpeakerId in effectiveSpeakerIds {
            let persistentId = speakerMatchResults[effectiveSpeakerId]?.persistentId
                ?? speakerNewProfiles[effectiveSpeakerId]
            guard let persistentId else { continue }

            let sessionEmbedding: [Float]?
            if let embeddings = embeddingsPerSpeaker[effectiveSpeakerId], !embeddings.isEmpty {
                sessionEmbedding = Self.computeMeanEmbedding(embeddings)
            } else {
                sessionEmbedding = nil
            }
            let matchedProfileSnapshot = speakerMatchResults[effectiveSpeakerId]
                .flatMap { match in existingProfiles.first(where: { $0.id == match.persistentId }) }

            speakerContexts[String(effectiveSpeakerId)] = ChannelSpeakerContext(
                persistentSpeakerId: persistentId,
                sessionEmbedding: sessionEmbedding,
                matchedProfileSnapshot: matchedProfileSnapshot,
                matchSimilarity: speakerMatchResults[effectiveSpeakerId]?.similarity
            )
        }

        // Transcribe each segment
        var utterances: [TranscriptionUtterance] = []
        let totalSegments = speakerSegments.count
        for (index, segment) in speakerSegments.enumerated() {
            try Task.checkCancellation()

            let segmentSamples = AudioResampler.extractSlice(
                from: samples,
                sampleRate: 16000,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
            guard let preparedSegment = Self.prepareMicSegmentForTranscription(
                samples: segmentSamples,
                sampleRate: 16000
            ) else {
                droppedSegments += 1
                continue
            }

            let text = try await parakeet.transcribeSegment(samples: preparedSegment.samples, source: .microphone)
            guard !text.isEmpty else {
                var context = preparedSegment.analysis.context
                context["segment_index"] = "\(index)"
                context["gain"] = String(format: "%.2f", preparedSegment.gain)
                context["padded_samples"] = "\(preparedSegment.paddedSampleCount)"
                AppLogger.transcription.warning("Mic diarization segment returned empty transcription", context)
                continue
            }

            let effectiveSpeakerId = speakerIdRemap[segment.speakerId] ?? segment.speakerId
            let persistentId: UUID?
            let similarity: Double?
            if let match = speakerMatchResults[effectiveSpeakerId] {
                persistentId = match.persistentId
                similarity = match.similarity
            } else {
                persistentId = speakerNewProfiles[effectiveSpeakerId]
                similarity = nil
            }

            utterances.append(TranscriptionUtterance(
                start: segment.startTime,
                end: segment.endTime,
                channel: 0,  // mic
                speakerId: effectiveSpeakerId,
                persistentSpeakerId: persistentId,
                matchSimilarity: similarity,
                transcript: text
            ))

            let progress = 0.65 + (Double(index + 1) / Double(max(1, totalSegments))) * 0.25
            onProgress?(progress)
        }

        return MicChannelResult(
            utterances: utterances,
            speakerContexts: speakerContexts,
            newlyCreatedProfileIds: newlyCreatedProfileIds
        )
    }

    // MARK: - Embedding Quality

    /// Calculate embedding weight based on mic activity fraction during a system audio segment.
    /// Returns nil if the segment should be excluded entirely (>80% mic overlap).
    /// Uses a 4-tier gradient to avoid sharp threshold cliffs:
    ///   - >80%: excluded (mic voice dominates system audio)
    ///   - 50-80%: weight 0.2 (heavily contaminated)
    ///   - 30-50%: weight 0.5 (moderately contaminated)
    ///   - <30%: weight 1.0 (clean)
    nonisolated static func embeddingWeight(forMicFraction micFraction: Double) -> Float? {
        if micFraction > 0.8 { return nil }
        switch micFraction {
        case 0.5...: return 0.2
        case 0.3...: return 0.5
        default: return 1.0
        }
    }

    // MARK: - Utterance Merging

    /// Merge consecutive utterances from the same speaker when the time gap between them
    /// is smaller than `maxGap` seconds. This produces cleaner transcripts by joining
    /// fragments that the diarizer split mid-sentence.
    ///
    /// A `maxDuration` cap prevents runaway merges — even if the speaker and gap criteria
    /// are met, an utterance won't grow beyond this many seconds of continuous speech.
    nonisolated static func mergeConsecutiveUtterances(
        _ utterances: [TranscriptionUtterance],
        maxGap: Double,
        maxDuration: Double = 30.0
    ) -> [TranscriptionUtterance] {
        guard utterances.count > 1 else { return utterances }

        var merged: [TranscriptionUtterance] = []
        var current = utterances[0]

        for next in utterances.dropFirst() {
            let sameSpeaker = current.speakerId == next.speakerId
                && current.channel == next.channel
            let smallGap = (next.start - current.end) < maxGap
            let withinDurationCap = (next.end - current.start) <= maxDuration

            if sameSpeaker && smallGap && withinDurationCap {
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

    // MARK: - Silence-Based Speech Segmentation

    struct PreparedMicSegment {
        let samples: [Float]
        let analysis: AudioSignalAnalysis
        let gain: Float
        let paddedSampleCount: Int
    }

    nonisolated static func prepareMicSegmentForTranscription(
        samples: [Float],
        sampleRate: Double
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
            analysis: analysis
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
    /// - Returns: Array of speech segments with start/end times
    nonisolated static func detectSpeechSegments(
        samples: [Float],
        sampleRate: Double
    ) -> [SpeechSegment] {
        guard !samples.isEmpty,
              AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else { return [] }

        let frameSamples = Int(sampleRate * 0.025)  // 25ms frames (400 samples at 16kHz)
        let hopSamples = Int(sampleRate * 0.010)    // 10ms hop
        let analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: sampleRate)
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
