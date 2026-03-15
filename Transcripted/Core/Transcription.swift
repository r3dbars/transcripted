import Foundation
@preconcurrency import AVFoundation
import Accelerate

/// Maps speaker labels to identified names from voice fingerprint matching
struct SpeakerMapping {
    let speakerId: String           // "0", "1", "2" for speaker IDs
    var identifiedName: String?     // "John Smith" or nil if unidentified
    var confidence: SpeakerConfidence?

    /// Display name: uses identified name if available, otherwise "Speaker X"
    var displayName: String {
        if let name = identifiedName {
            return confidence == .medium ? "\(name)?" : name
        }
        return "Speaker \(speakerId)"
    }

    init(speakerId: String, identifiedName: String? = nil, confidence: SpeakerConfidence? = nil) {
        self.speakerId = speakerId
        self.identifiedName = identifiedName
        self.confidence = confidence
    }
}

// MARK: - Transcription Service (Local Pipeline)

@available(macOS 26.0, *)
@MainActor
class Transcription: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var processingStatus: String = ""
    @Published var lastSavedFileURL: URL?

    let parakeet: ParakeetService
    let sortformer: SortformerService
    let speakerDB: SpeakerDatabase

    init() {
        self.parakeet = ParakeetService()
        self.sortformer = SortformerService()
        self.speakerDB = SpeakerDatabase.shared
    }

    /// Initialize local models. Call once at app startup.
    func initializeModels() async {
        await parakeet.initialize()
        await sortformer.initialize()
    }

    // MARK: - Local Multichannel Transcription

    /// Transcribe mic + system audio using local Parakeet STT + Sortformer diarization.
    ///
    /// Pipeline:
    /// 1. Load & resample both audio files to 16kHz mono
    /// 2. Run Sortformer on system audio → speaker segments with timestamps + embeddings
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

            onProgress?(0.10)

            // Step 2: Run Sortformer on system audio → speaker segments
            await MainActor.run {
                self.processingStatus = "Identifying speakers..."
            }

            AppLogger.transcription.info("Running Sortformer diarization on system audio")
            let rawSegments = try await sortformer.diarize(samples: systemSamples, sampleRate: 16000)

            // Post-process Sortformer segments:
            // 1. Pairwise merge fixes fragmentation (same speaker split across IDs)
            // 2. DB-informed split fixes merging (different speakers collapsed into one ID)
            let existingProfiles = speakerDB.allSpeakers()
            let speakerSegments = EmbeddingClusterer.postProcess(
                segments: rawSegments,
                existingProfiles: existingProfiles
            )

            let sortformerSpeakerCount = Set(rawSegments.map { $0.speakerId }).count
            let postProcessedSpeakerCount = Set(speakerSegments.map { $0.speakerId }).count
            AppLogger.transcription.info("Post-processed speaker segments", [
                "sortformer": "\(sortformerSpeakerCount)",
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
            var filteredSegmentCount = 0
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
                    embeddingsPerSpeaker[segment.speakerId, default: []].append(embedding)
                }
            }
            if filteredSegmentCount > 0 {
                AppLogger.transcription.info("Filtered low-quality segments from embedding aggregation", ["filtered": "\(filteredSegmentCount)", "total": "\(speakerSegments.count)"])
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

            for (speakerId, embeddings) in embeddingsPerSpeaker {
                let meanEmbedding = Self.computeMeanEmbedding(embeddings)

                // Adaptive threshold: require higher similarity when we have fewer segments.
                // A single 2s segment can false-match at 0.79; 4+ segments give a reliable mean.
                // Ghost speakers (all segments filtered as low quality) use a stricter threshold
                // since their embeddings are unreliable and prone to false DB matches.
                let isGhost = ghostSpeakerIdSet.contains(speakerId)
                let adaptiveThreshold: Double = if isGhost {
                    0.92  // ghost speaker — embedding is low quality, require very high similarity
                } else {
                    switch embeddings.count {
                        case 1: 0.85       // single segment — need near-certainty
                        case 2...3: 0.78   // few segments — still cautious
                        default: 0.70      // 4+ segments — reliable mean embedding
                    }
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
            var speakerIdRemap: [Int: Int] = [:]
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
            // Sortformer segments often break mid-sentence, producing fragments like:
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
    /// fragments that Sortformer split mid-sentence.
    nonisolated static func mergeConsecutiveUtterances(
        _ utterances: [TranscriptionUtterance],
        maxGap: Double
    ) -> [TranscriptionUtterance] {
        guard utterances.count > 1 else { return utterances }

        var merged: [TranscriptionUtterance] = []
        var current = utterances[0]

        for next in utterances.dropFirst() {
            let sameSpeaker = current.speakerId == next.speakerId
                && current.channel == next.channel
            let smallGap = (next.start - current.end) < maxGap

            if sameSpeaker && smallGap {
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

    // MARK: - Embedding Utilities

    /// Compute the L2-normalized mean of multiple embeddings.
    /// Averaging reduces per-segment noise, producing a more stable speaker fingerprint.
    nonisolated static func computeMeanEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        guard dim > 0 else { return [] }

        if embeddings.count == 1 { return first }

        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            for i in 0..<min(dim, emb.count) {
                sum[i] += emb[i]
            }
        }

        let scale = Float(embeddings.count)
        var mean = sum.map { $0 / scale }

        // L2 normalize
        var norm: Float = 0
        vDSP_dotpr(mean, 1, mean, 1, &norm, vDSP_Length(mean.count))
        norm = sqrt(norm)
        if norm > 0 {
            vDSP_vsdiv(mean, 1, &norm, &mean, 1, vDSP_Length(mean.count))
        }
        return mean
    }

    // MARK: - In-Memory Speaker Matching

    /// Result of matching against an in-memory snapshot of profiles
    private struct SnapshotMatchResult {
        let profileId: UUID
        let similarity: Double
    }

    /// Match an embedding against a frozen snapshot of speaker profiles.
    /// Same logic as SpeakerDatabase.matchSpeaker but operates on an in-memory array,
    /// preventing the matching loop from seeing profiles created during the same recording.
    private nonisolated static func matchAgainstProfiles(
        _ embedding: [Float],
        profiles: [SpeakerProfile],
        threshold: Double
    ) -> SnapshotMatchResult? {
        guard !profiles.isEmpty, !embedding.isEmpty else { return nil }

        var bestId: UUID?
        var bestSimilarity: Double = -1

        for profile in profiles {
            guard profile.embedding.count == embedding.count else { continue }
            let similarity = cosineSimilarityStatic(embedding, profile.embedding)
            if similarity > bestSimilarity && similarity >= threshold {
                bestSimilarity = similarity
                bestId = profile.id
            }
        }

        if let id = bestId {
            return SnapshotMatchResult(profileId: id, similarity: bestSimilarity)
        }
        return nil
    }

    /// Static cosine similarity (no instance needed — used in nonisolated static context)
    nonisolated static func cosineSimilarityStatic(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }

        return Double(dotProduct / denom)
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
