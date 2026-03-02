import Foundation
@preconcurrency import AVFoundation
import Accelerate

/// Maps speaker labels to identified names from Gemini
struct SpeakerMapping {
    let speakerId: String           // "0", "1", "2" for speaker IDs
    var identifiedName: String?     // "John Smith" or nil if unidentified
    var confidence: String?         // "high" or "medium"

    /// Display name: uses identified name if available, otherwise "Speaker X"
    var displayName: String {
        if let name = identifiedName {
            return confidence == "medium" ? "\(name)?" : name
        }
        return "Speaker \(speakerId)"
    }

    init(speakerId: String, identifiedName: String? = nil, confidence: String? = nil) {
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

            // Resample both files in parallel — they're independent I/O + compute
            async let systemSamplesTask = Task { try AudioResampler.loadAndResample(url: systemURL, targetRate: 16000) }
            async let micSamplesTask = Task { try AudioResampler.loadAndResample(url: micURL, targetRate: 16000) }
            let systemSamples = try await systemSamplesTask.value
            let micSamples = try await micSamplesTask.value

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

            // Re-cluster speaker assignments using AHC on WeSpeaker embeddings.
            // Sortformer's streaming clustering is mediocre at grouping similar voices;
            // AHC with cosine similarity produces more accurate speaker counts.
            let sortformerSpeakerCount = Set(rawSegments.map { $0.speakerId }).count
            let speakerSegments = EmbeddingClusterer.recluster(segments: rawSegments)
            let ahcSpeakerCount = Set(speakerSegments.map { $0.speakerId }).count
            AppLogger.transcription.info("Re-clustered speakers", [
                "before": "\(sortformerSpeakerCount)",
                "after": "\(ahcSpeakerCount)",
                "segments": "\(speakerSegments.count)"
            ])

            onProgress?(0.30)

            // Step 3: Transcribe each speaker segment with Parakeet
            await MainActor.run {
                self.processingStatus = "Transcribing system audio..."
            }

            var systemUtterances: [TranscriptionUtterance] = []
            let totalSegments = speakerSegments.count

            // Aggregate embeddings per Sortformer speaker ID for stable matching.
            // Instead of matching each segment independently (noisy), we compute
            // a mean embedding per speaker and match that once against the DB.
            var embeddingsPerSpeaker: [Int: [[Float]]] = [:]
            for segment in speakerSegments {
                if let embedding = segment.embedding, !embedding.isEmpty {
                    embeddingsPerSpeaker[segment.speakerId, default: []].append(embedding)
                }
            }

            // Match each speaker's mean embedding against the DB once
            var speakerMatchResults: [Int: (persistentId: UUID, similarity: Double)] = [:]
            var speakerNewProfiles: [Int: UUID] = [:]

            for (speakerId, embeddings) in embeddingsPerSpeaker {
                let meanEmbedding = Self.computeMeanEmbedding(embeddings)
                if let matchResult = speakerDB.matchSpeaker(embedding: meanEmbedding) {
                    speakerMatchResults[speakerId] = (matchResult.profile.id, matchResult.similarity)
                    _ = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: matchResult.profile.id)
                    AppLogger.transcription.info("Speaker matched DB profile", ["speakerId": "\(speakerId)", "similarity": String(format: "%.3f", matchResult.similarity), "segmentsAveraged": "\(embeddings.count)"])
                } else {
                    let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding)
                    speakerNewProfiles[speakerId] = newProfile.id
                    AppLogger.transcription.info("Speaker new profile created", ["speakerId": "\(speakerId)", "segmentsAveraged": "\(embeddings.count)"])
                }
            }

            for (index, segment) in speakerSegments.enumerated() {
                // Extract audio slice for this segment
                let segmentSamples = AudioResampler.extractSlice(
                    from: systemSamples,
                    sampleRate: 16000,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )

                // Skip very short segments (< 0.5s of audio)
                guard segmentSamples.count >= 8000 else { continue }

                let text = try await parakeet.transcribeSegment(samples: segmentSamples, source: .system)

                // Skip empty transcriptions
                guard !text.isEmpty else { continue }

                // Use the pre-computed per-speaker match result
                let persistentId: UUID?
                let similarity: Double?
                if let match = speakerMatchResults[segment.speakerId] {
                    persistentId = match.persistentId
                    similarity = match.similarity
                } else {
                    persistentId = speakerNewProfiles[segment.speakerId]
                    similarity = nil
                }

                systemUtterances.append(TranscriptionUtterance(
                    start: segment.startTime,
                    end: segment.endTime,
                    channel: 1,
                    speakerId: segment.speakerId,
                    persistentSpeakerId: persistentId,
                    matchSimilarity: similarity,
                    transcript: text
                ))

                // Update progress (30% to 65% during system transcription)
                let segmentProgress = 0.30 + (Double(index + 1) / Double(max(1, totalSegments))) * 0.35
                onProgress?(segmentProgress)
            }

            AppLogger.transcription.info("System audio transcribed", ["utterances": "\(systemUtterances.count)", "speakers": "\(Set(systemUtterances.map { $0.speakerId }).count)"])

            // Step 4: Transcribe mic audio with Parakeet
            await MainActor.run {
                self.processingStatus = "Transcribing mic audio..."
            }

            AppLogger.transcription.info("Transcribing mic audio with Parakeet")
            let micText = try await parakeet.transcribeSegment(samples: micSamples, source: .microphone)

            onProgress?(0.80)

            // Create mic utterances — split by sentence/silence boundaries
            var micUtterances: [TranscriptionUtterance] = []
            if !micText.isEmpty {
                // Split into chunks by sentence boundaries for better timestamps
                let micDuration = Double(micSamples.count) / 16000.0
                let sentences = splitIntoSentences(micText)
                let timePerSentence = micDuration / Double(max(1, sentences.count))

                for (i, sentence) in sentences.enumerated() {
                    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    micUtterances.append(TranscriptionUtterance(
                        start: Double(i) * timePerSentence,
                        end: Double(i + 1) * timePerSentence,
                        channel: 0,
                        speakerId: 0,
                        persistentSpeakerId: nil,
                        matchSimilarity: nil,
                        transcript: trimmed
                    ))
                }
            }

            AppLogger.transcription.info("Mic audio transcribed", ["utterances": "\(micUtterances.count)"])

            onProgress?(0.90)

            let processingTime = Date().timeIntervalSince(processingStartTime)

            await MainActor.run {
                self.processingStatus = "Transcription complete!"
                self.isProcessing = false
            }

            onProgress?(1.0)

            AppLogger.transcription.info("Local transcription complete", [
                "micUtterances": "\(micUtterances.count)",
                "systemUtterances": "\(systemUtterances.count)",
                "systemSpeakers": "\(Set(systemUtterances.map { $0.speakerId }).count)",
                "processingTime": "\(String(format: "%.1f", processingTime))s"
            ])

            return TranscriptionResult(
                micUtterances: micUtterances,
                systemUtterances: systemUtterances,
                duration: duration,
                processingTime: processingTime
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

    // MARK: - Embedding Utilities

    /// Compute the L2-normalized mean of multiple embeddings.
    /// Averaging reduces per-segment noise, producing a more stable speaker fingerprint.
    private nonisolated static func computeMeanEmbedding(_ embeddings: [[Float]]) -> [Float] {
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

    // MARK: - Text Splitting

    /// Split text into sentences for approximate timestamp assignment
    private nonisolated func splitIntoSentences(_ text: String) -> [String] {
        // Split on sentence-ending punctuation
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }

        // Don't lose trailing text without punctuation
        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        // If no sentence boundaries found, return the whole text
        if sentences.isEmpty && !text.isEmpty {
            sentences.append(text)
        }

        return sentences
    }
}
