import Foundation
@preconcurrency import AVFoundation
import Accelerate

// MARK: - Local Multichannel Transcription

@available(macOS 26.0, *)
extension Transcription {

    /// Transcribe mic + system audio using local Parakeet STT + offline diarization.
    ///
    /// Pipeline:
    /// 1. Load & resample both audio files to 16kHz mono
    /// 2. Run Sortformer on system audio -> speaker segments with timestamps + embeddings
    /// 3. Transcribe each speaker segment individually with Parakeet
    /// 4. Transcribe mic audio with Parakeet (full track, split by silence)
    /// 5. Match speaker embeddings against persistent SpeakerDatabase
    /// 6. Merge mic + system utterances chronologically
    ///
    /// Note: nonisolated to keep heavy compute off the main thread
    nonisolated func transcribeMultichannel(
        micURL: URL,
        systemURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        let processingStartTime = Date()

        do {
            // Get recording duration from original mic file
            let micFile = try AVAudioFile(forReading: micURL)
            let duration = Double(micFile.length) / micFile.processingFormat.sampleRate

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
            let systemSamples = try await AudioResampler.loadAndResample(url: systemURL, targetRate: 16000)
            let micSamples = try await AudioResampler.loadAndResample(url: micURL, targetRate: 16000)

            let resampleTime = CFAbsoluteTimeGetCurrent() - resampleStart
            AppLogger.transcription.info("Resampling completed in \(String(format: "%.2f", resampleTime))s")

            AppLogger.transcription.debug("System: \(systemSamples.count) samples (\(String(format: "%.1f", Double(systemSamples.count) / 16000))s)")
            AppLogger.transcription.debug("Mic: \(micSamples.count) samples (\(String(format: "%.1f", Double(micSamples.count) / 16000))s)")

            // Pre-compute mic energy per 100ms frame for embedding quality gating.
            // When the local user is speaking, system audio embeddings are contaminated
            // with their voice echo, producing unreliable remote speaker voiceprints.
            let micEnergyFrameDuration = 0.1  // 100ms frames
            let micFrameSize = Int(16000.0 * micEnergyFrameDuration)  // 1600 samples
            let micFrameCount = micSamples.count / micFrameSize
            var micEnergyPerFrame = [Float](repeating: 0, count: micFrameCount)

            micSamples.withUnsafeBufferPointer { ptr in
                for i in 0..<micFrameCount {
                    let start = i * micFrameSize
                    var sumSquares: Float = 0
                    vDSP_dotpr(ptr.baseAddress! + start, 1,
                               ptr.baseAddress! + start, 1,
                               &sumSquares,
                               vDSP_Length(micFrameSize))
                    micEnergyPerFrame[i] = sqrt(sumSquares / Float(micFrameSize))
                }
            }
            let micActiveThreshold: Float = 0.02  // matches isSilent threshold

            /// Returns the fraction of a time range where the local mic was active (0.0-1.0).
            func micActiveFraction(startTime: Double, endTime: Double) -> Double {
                let startFrame = max(0, Int(startTime / micEnergyFrameDuration))
                let endFrame = min(micFrameCount, Int(endTime / micEnergyFrameDuration))
                guard endFrame > startFrame else { return 0 }
                let activeCount = (startFrame..<endFrame).filter { micEnergyPerFrame[$0] >= micActiveThreshold }.count
                return Double(activeCount) / Double(endFrame - startFrame)
            }

            onProgress?(0.10)

            // Step 2: Run offline diarization on system audio -> speaker segments
            await MainActor.run {
                self.processingStatus = "Analyzing speakers..."
            }

            AppLogger.transcription.info("Running offline diarization on system audio")
            let rawSegments = try await diarization.diarizeOffline(samples: systemSamples, sampleRate: 16000)

            // Post-process diarization segments:
            // PyAnnote's VBx already handles speaker merging, so skip pairwise merge.
            // DB-informed split still valuable — VBx has no knowledge of stored profiles.
            let existingProfiles = speakerDB.allSpeakers()
            let speakerSegments = EmbeddingClusterer.postProcess(
                segments: rawSegments,
                existingProfiles: existingProfiles,
                skipPairwiseMerge: true
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

                    if micFraction > 0.8 {
                        // >80% overlap with local mic: skip entirely
                        micContaminatedCount += 1
                        continue
                    }

                    let weight: Float = micFraction > 0.3 ? 0.3 : 1.0
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
                    .filter { $0.speakerId == ghostId && $0.embedding != nil && !$0.embedding!.isEmpty }
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

            for (speakerId, embeddings) in embeddingsPerSpeaker {
                let weights = embeddingWeights[speakerId] ?? Array(repeating: Float(1.0), count: embeddings.count)
                let meanEmbedding = Self.computeWeightedMeanEmbedding(embeddings, weights: weights)

                let isGhost = ghostSpeakerIdSet.contains(speakerId)

                // Ghost speakers have unreliable embeddings (laughter, coughs, codec artifacts).
                // Don't create new DB profiles for them — force-merge into the closest real speaker.
                if isGhost {
                    var bestNonGhostId: Int?
                    var bestSimilarity: Double = -1
                    for (otherId, otherEmbeddings) in embeddingsPerSpeaker where !ghostSpeakerIdSet.contains(otherId) {
                        let otherMean = Self.computeMeanEmbedding(otherEmbeddings)
                        let sim = Self.cosineSimilarityStatic(meanEmbedding, otherMean)
                        if sim > bestSimilarity {
                            bestSimilarity = sim
                            bestNonGhostId = otherId
                        }
                    }
                    if let targetId = bestNonGhostId {
                        speakerIdRemap[speakerId] = targetId
                        AppLogger.transcription.info("Ghost speaker force-merged", [
                            "ghostSpk": "\(speakerId)",
                            "into": "\(targetId)",
                            "similarity": String(format: "%.3f", bestSimilarity)
                        ])
                    }
                    continue  // Skip DB matching/creation entirely
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
                    AppLogger.transcription.info("Speaker matched DB profile", [
                        "speakerId": "\(speakerId)",
                        "similarity": String(format: "%.3f", matchResult.similarity),
                        "threshold": String(format: "%.2f", adaptiveThreshold),
                        "segmentsAveraged": "\(embeddings.count)"
                    ])
                } else {
                    let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding)
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
            let profileToSpeakers = Dictionary(grouping: speakerMatchResults.keys) { speakerMatchResults[$0]!.persistentId }
            for (_, matchedSpeakerIds) in profileToSpeakers where matchedSpeakerIds.count >= 2 {
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

            // Step 4: Transcribe mic audio per-segment using energy-based silence detection
            await MainActor.run {
                self.processingStatus = "Transcribing mic audio..."
            }

            // Split mic audio into segments at silence boundaries for accurate timestamps
            let micSegments = Self.detectSpeechSegments(samples: micSamples, sampleRate: 16000)
            AppLogger.transcription.info("Mic audio segmented by silence", ["segments": "\(micSegments.count)"])

            var micUtterances: [TranscriptionUtterance] = []

            for (index, segment) in micSegments.enumerated() {
                try Task.checkCancellation()

                let segmentSamples = AudioResampler.extractSlice(
                    from: micSamples,
                    sampleRate: 16000,
                    startTime: segment.start,
                    endTime: segment.end
                )

                // Skip segments shorter than 1s — Parakeet requires at least 16,000 samples
                guard segmentSamples.count >= 16000 else { droppedSegments += 1; continue }

                let text = try await parakeet.transcribeSegment(samples: segmentSamples, source: .microphone)
                guard !text.isEmpty else { continue }

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

            onProgress?(0.95)

            let processingTime = Date().timeIntervalSince(processingStartTime)

            await MainActor.run {
                self.processingStatus = "Transcription complete!"
                self.isProcessing = false
            }

            onProgress?(1.0)

            // Merge consecutive utterances from the same speaker when the gap is small.
            // Diarizer segments often break mid-sentence, producing fragments like:
            //   [00:03] "Opus four point six and"
            //   [00:10] "Sonnet four point six just went live"
            // Merging produces cleaner, more readable transcripts.
            let mergedSystemUtterances = Self.mergeConsecutiveUtterances(systemUtterances, maxGap: 1.5)
            let mergedMicUtterances = Self.mergeConsecutiveUtterances(micUtterances, maxGap: 1.5)

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
        guard !samples.isEmpty else { return [] }

        let frameSamples = Int(sampleRate * 0.025)  // 25ms frames (400 samples at 16kHz)
        let hopSamples = Int(sampleRate * 0.010)    // 10ms hop
        let silenceThreshold: Float = 0.01          // RMS below this = silence
        let minSilenceDuration: Double = 0.4        // 400ms gap to split
        let minSegmentDuration: Double = 0.5        // Don't create segments shorter than this

        // Compute RMS energy per frame
        let totalFrames = max(1, (samples.count - frameSamples) / hopSamples + 1)
        var isVoiced = [Bool](repeating: false, count: totalFrames)

        samples.withUnsafeBufferPointer { ptr in
            for i in 0..<totalFrames {
                let start = i * hopSamples
                let end = min(start + frameSamples, samples.count)
                let count = end - start
                guard count > 0 else { continue }

                var sumSquares: Float = 0
                vDSP_dotpr(ptr.baseAddress! + start, 1,
                           ptr.baseAddress! + start, 1,
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
