import Foundation
@preconcurrency import AVFoundation

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

            print("Loading and resampling audio to 16kHz...")
            let systemSamples = try AudioResampler.loadAndResample(url: systemURL, targetRate: 16000)
            let micSamples = try AudioResampler.loadAndResample(url: micURL, targetRate: 16000)

            print("  System: \(systemSamples.count) samples (\(String(format: "%.1f", Double(systemSamples.count) / 16000))s)")
            print("  Mic: \(micSamples.count) samples (\(String(format: "%.1f", Double(micSamples.count) / 16000))s)")

            onProgress?(0.10)

            // Step 2: Run Sortformer on system audio → speaker segments
            await MainActor.run {
                self.processingStatus = "Identifying speakers..."
            }

            print("Running Sortformer diarization on system audio...")
            let speakerSegments = try await sortformer.diarize(samples: systemSamples, sampleRate: 16000)

            onProgress?(0.30)

            // Step 3: Transcribe each speaker segment with Parakeet
            await MainActor.run {
                self.processingStatus = "Transcribing system audio..."
            }

            var systemUtterances: [TranscriptionUtterance] = []
            let totalSegments = speakerSegments.count

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

                // Match speaker embedding against persistent database
                var persistentId: UUID?
                if let embedding = segment.embedding {
                    if let match = speakerDB.matchSpeaker(embedding: embedding) {
                        persistentId = match.id
                        _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: match.id)
                    } else {
                        let newProfile = speakerDB.addOrUpdateSpeaker(embedding: embedding)
                        persistentId = newProfile.id
                    }
                }

                systemUtterances.append(TranscriptionUtterance(
                    start: segment.startTime,
                    end: segment.endTime,
                    channel: 1,
                    speakerId: segment.speakerId,
                    persistentSpeakerId: persistentId,
                    transcript: text
                ))

                // Update progress (30% to 65% during system transcription)
                let segmentProgress = 0.30 + (Double(index + 1) / Double(max(1, totalSegments))) * 0.35
                onProgress?(segmentProgress)
            }

            print("System audio: \(systemUtterances.count) utterances from \(Set(systemUtterances.map { $0.speakerId }).count) speakers")

            // Step 4: Transcribe mic audio with Parakeet
            await MainActor.run {
                self.processingStatus = "Transcribing mic audio..."
            }

            print("Transcribing mic audio with Parakeet...")
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
                        transcript: trimmed
                    ))
                }
            }

            print("Mic audio: \(micUtterances.count) utterances")

            onProgress?(0.90)

            let processingTime = Date().timeIntervalSince(processingStartTime)

            await MainActor.run {
                self.processingStatus = "Transcription complete!"
                self.isProcessing = false
            }

            onProgress?(1.0)

            print("Local transcription complete:")
            print("   Mic utterances: \(micUtterances.count)")
            print("   System utterances: \(systemUtterances.count)")
            print("   System speakers: \(Set(systemUtterances.map { $0.speakerId }).count)")
            print("   Processing time: \(String(format: "%.1f", processingTime))s")

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
