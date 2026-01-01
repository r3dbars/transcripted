import Foundation
@preconcurrency import AVFoundation

/// Maps AssemblyAI speaker labels (A, B, C) to identified names from Gemini
struct SpeakerMapping {
    let speakerId: String           // "A", "B", "C", "D", etc.
    var identifiedName: String?     // "John Smith" or nil if unidentified
    var confidence: String?         // "high" or "medium"

    /// Display name: uses identified name if available, otherwise "Speaker A/B/C"
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

/// Combined result from AssemblyAI transcription of both mic and system audio
/// Preserves all rich data (summary, sentiment, entities, chapters) for comprehensive markdown output
struct CombinedAssemblyAIResult {
    let micResult: AssemblyAITranscriptionResult?
    let systemResult: AssemblyAITranscriptionResult?
    let duration: TimeInterval
    let processingTime: TimeInterval

    /// All unique speaker IDs detected across both audio sources
    var allSpeakerIds: Set<String> {
        var ids = Set<String>()
        if let mic = micResult {
            for utterance in mic.utterances {
                ids.insert(utterance.speaker)
            }
        }
        if let sys = systemResult {
            for utterance in sys.utterances {
                ids.insert(utterance.speaker)
            }
        }
        return ids
    }
}

/// Result from multichannel AssemblyAI transcription (stereo: mic=left, system=right)
/// This is the preferred approach - single API call with channel-based speaker attribution
struct MultichannelTranscriptionResult {
    let result: AssemblyAIMultichannelResult
    let duration: TimeInterval
    let processingTime: TimeInterval
}

@available(macOS 26.0, *)
class Transcription: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var processingStatus: String = ""
    @Published var lastSavedFileURL: URL?

    init() {}

    /// Main entry point: Transcribe both audio files and save to markdown using AssemblyAI
    /// - Parameters:
    ///   - micURL: Mic audio file URL
    ///   - systemURL: System audio file URL (optional)
    ///   - outputFolder: Folder to save markdown transcript
    ///   - onProgress: Optional callback for progress updates (0.0 to 1.0) - Goal-Gradient Effect
    /// - Returns: URL of saved markdown file
    func transcribeMeetingFiles(
        micURL: URL,
        systemURL: URL?,
        outputFolder: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        return try await transcribeWithAssemblyAI(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            onProgress: onProgress
        )
    }

    /// Transcribe audio files and return intermediate result WITHOUT saving to disk
    /// This allows speaker identification with Gemini before saving the final transcript
    /// - Parameters:
    ///   - micURL: Mic audio file URL
    ///   - systemURL: System audio file URL (optional)
    ///   - onProgress: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: CombinedAssemblyAIResult with all rich data for further processing
    func transcribeToIntermediateResult(
        micURL: URL,
        systemURL: URL?,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> CombinedAssemblyAIResult {
        let apiKey = UserDefaults.standard.string(forKey: "assemblyaiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Transcription", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "AssemblyAI API key not configured. Please add your API key in Settings."
            ])
        }

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        let processingStartTime = Date()
        let hasSystemAudio = systemURL != nil
        var tempFilesToCleanup: [URL] = []

        do {
            // Get recording duration from original file
            let micFile = try AVAudioFile(forReading: micURL)
            let duration = Double(micFile.length) / micFile.processingFormat.sampleRate

            onProgress?(0.0)

            // Preprocess mic and system audio IN PARALLEL for ~2x faster processing
            await MainActor.run {
                self.processingStatus = "Optimizing audio for upload..."
            }

            // Start both preprocessing tasks concurrently
            let micTask = Task {
                try await AudioPreprocessor.prepareForCloudTranscription(audioURL: micURL)
            }

            let systemTask: Task<URL?, Error> = Task {
                guard let systemURL = systemURL else { return nil }
                return try await AudioPreprocessor.prepareForCloudTranscription(audioURL: systemURL)
            }

            // Wait for both to complete (they run in parallel)
            let optimizedMicURL = try await micTask.value
            if optimizedMicURL != micURL {
                tempFilesToCleanup.append(optimizedMicURL)
            }

            let optimizedSystemURL = try await systemTask.value
            if let url = optimizedSystemURL, url != systemURL {
                tempFilesToCleanup.append(url)
            }

            onProgress?(0.15)

            // Transcribe mic audio - PRESERVE FULL RESULT
            let micResult = try await AssemblyAIService.transcribe(
                audioURL: optimizedMicURL,
                apiKey: apiKey,
                onStatusUpdate: { status in
                    Task { @MainActor in
                        self.processingStatus = "Mic: \(status.rawValue)"
                    }
                }
            )

            onProgress?(hasSystemAudio ? 0.50 : 0.85)

            // Transcribe system audio (if present) - PRESERVE FULL RESULT
            var systemResult: AssemblyAITranscriptionResult? = nil
            if let optimizedSystemURL = optimizedSystemURL {
                systemResult = try await AssemblyAIService.transcribe(
                    audioURL: optimizedSystemURL,
                    apiKey: apiKey,
                    onStatusUpdate: { status in
                        Task { @MainActor in
                            self.processingStatus = "System: \(status.rawValue)"
                        }
                    }
                )
                onProgress?(0.85)
            }

            // Cleanup temp preprocessed files
            for tempURL in tempFilesToCleanup {
                AudioPreprocessor.cleanup(tempURL: tempURL)
            }

            let processingTime = Date().timeIntervalSince(processingStartTime)

            await MainActor.run {
                self.processingStatus = "Transcription complete, preparing for speaker identification..."
            }

            onProgress?(0.90)

            // Return intermediate result for further processing (speaker ID, then save)
            return CombinedAssemblyAIResult(
                micResult: micResult,
                systemResult: systemResult,
                duration: duration,
                processingTime: processingTime
            )

        } catch {
            // Cleanup temp files on failure
            for tempURL in tempFilesToCleanup {
                AudioPreprocessor.cleanup(tempURL: tempURL)
            }

            await MainActor.run {
                self.error = "AssemblyAI transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }

    // MARK: - Multichannel Transcription (Preferred)

    /// Transcribe using multichannel mode - merges mic + system into stereo, single API call
    /// This is the preferred approach when both audio sources are available because:
    /// - 50% fewer API calls (1 instead of 2)
    /// - Perfectly synchronized timestamps between mic and system audio
    /// - Channel-based speaker attribution (no guessing who spoke)
    /// - Lower memory usage (single file processing)
    ///
    /// - Parameters:
    ///   - micURL: Microphone audio file URL
    ///   - systemURL: System audio file URL (required for multichannel)
    ///   - onProgress: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: MultichannelTranscriptionResult with channel-separated utterances
    func transcribeMultichannel(
        micURL: URL,
        systemURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> MultichannelTranscriptionResult {
        let apiKey = UserDefaults.standard.string(forKey: "assemblyaiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Transcription", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "AssemblyAI API key not configured. Please add your API key in Settings."
            ])
        }

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        let processingStartTime = Date()
        var stereoTempURL: URL?

        do {
            // Get recording duration from original mic file
            let micFile = try AVAudioFile(forReading: micURL)
            let duration = Double(micFile.length) / micFile.processingFormat.sampleRate

            onProgress?(0.0)

            // Step 1: Merge mic + system audio into stereo file
            await MainActor.run {
                self.processingStatus = "Merging audio channels..."
            }

            print("🔀 Multichannel: Merging mic + system into stereo...")
            stereoTempURL = try await AudioPreprocessor.prepareMergedStereoForCloud(
                micURL: micURL,
                systemURL: systemURL
            )

            onProgress?(0.20)

            // Step 2: Transcribe the stereo file with multichannel mode
            await MainActor.run {
                self.processingStatus = "Uploading for transcription..."
            }

            guard let stereoURL = stereoTempURL else {
                throw NSError(domain: "Transcription", code: 101, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create merged stereo file"
                ])
            }

            let result = try await AssemblyAIService.transcribeMultichannel(
                stereoAudioURL: stereoURL,
                apiKey: apiKey,
                onStatusUpdate: { status in
                    Task { @MainActor in
                        self.processingStatus = status.rawValue
                    }
                }
            )

            onProgress?(0.90)

            // Step 3: Cleanup temp stereo file
            AudioPreprocessor.cleanup(tempURL: stereoURL)

            let processingTime = Date().timeIntervalSince(processingStartTime)

            await MainActor.run {
                self.processingStatus = "Transcription complete!"
                self.isProcessing = false
            }

            onProgress?(1.0)

            print("✅ Multichannel transcription complete:")
            print("   • Mic utterances: \(result.micUtterances.count)")
            print("   • System utterances: \(result.systemUtterances.count)")
            print("   • Processing time: \(String(format: "%.1f", processingTime))s")

            return MultichannelTranscriptionResult(
                result: result,
                duration: duration,
                processingTime: processingTime
            )

        } catch {
            // Cleanup temp file on failure
            if let tempURL = stereoTempURL {
                AudioPreprocessor.cleanup(tempURL: tempURL)
            }

            await MainActor.run {
                self.error = "Multichannel transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }

    /// Transcribe using AssemblyAI's cloud API with speaker diarization
    private func transcribeWithAssemblyAI(micURL: URL, systemURL: URL?, outputFolder: URL, onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        let apiKey = UserDefaults.standard.string(forKey: "assemblyaiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Transcription", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "AssemblyAI API key not configured. Please add your API key in Settings."
            ])
        }

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        let processingStartTime = Date()
        let hasSystemAudio = systemURL != nil

        // Track temp files for cleanup
        var tempFilesToCleanup: [URL] = []

        do {
            // Get recording duration from original file
            let micFile = try AVAudioFile(forReading: micURL)
            let duration = Double(micFile.length) / micFile.processingFormat.sampleRate

            // Progress: 0%
            onProgress?(0.0)

            // Preprocess mic and system audio IN PARALLEL for ~2x faster processing
            await MainActor.run {
                self.processingStatus = "Optimizing audio for upload..."
            }

            // Start both preprocessing tasks concurrently
            let micTask = Task {
                try await AudioPreprocessor.prepareForCloudTranscription(audioURL: micURL)
            }

            let systemTask: Task<URL?, Error> = Task {
                guard let systemURL = systemURL else { return nil }
                return try await AudioPreprocessor.prepareForCloudTranscription(audioURL: systemURL)
            }

            // Wait for both to complete (they run in parallel)
            let optimizedMicURL = try await micTask.value
            if optimizedMicURL != micURL {
                tempFilesToCleanup.append(optimizedMicURL)
            }

            let optimizedSystemURL = try await systemTask.value
            if let url = optimizedSystemURL, url != systemURL {
                tempFilesToCleanup.append(url)
            }

            // Progress: 15%
            onProgress?(0.15)

            // Transcribe mic audio with status updates - PRESERVE FULL RESULT
            let micResult = try await AssemblyAIService.transcribe(
                audioURL: optimizedMicURL,
                apiKey: apiKey,
                onStatusUpdate: { status in
                    Task { @MainActor in
                        self.processingStatus = "Mic: \(status.rawValue)"
                    }
                }
            )

            // Progress: 50% if system audio, 85% if no system audio
            onProgress?(hasSystemAudio ? 0.50 : 0.85)

            // Transcribe system audio (if present) - PRESERVE FULL RESULT
            var systemResult: AssemblyAITranscriptionResult? = nil
            if let optimizedSystemURL = optimizedSystemURL {
                systemResult = try await AssemblyAIService.transcribe(
                    audioURL: optimizedSystemURL,
                    apiKey: apiKey,
                    onStatusUpdate: { status in
                        Task { @MainActor in
                            self.processingStatus = "System: \(status.rawValue)"
                        }
                    }
                )

                // Progress: 85%
                onProgress?(0.85)
            }

            // Cleanup temp preprocessed files
            for tempURL in tempFilesToCleanup {
                AudioPreprocessor.cleanup(tempURL: tempURL)
            }

            await MainActor.run {
                self.processingStatus = "Merging transcripts..."
            }

            // Progress: 90%
            onProgress?(0.90)

            // Calculate processing time
            let processingTime = Date().timeIntervalSince(processingStartTime)

            // Create combined result with ALL rich data (summary, sentiment, entities, chapters)
            let combinedResult = CombinedAssemblyAIResult(
                micResult: micResult,
                systemResult: systemResult,
                duration: duration,
                processingTime: processingTime
            )

            await MainActor.run {
                self.processingStatus = "Saving rich transcript..."
            }

            // Progress: 95%
            onProgress?(0.95)

            // Save to markdown with full AssemblyAI features (summary, sentiment, entities, chapters, inline annotations)
            guard let fileURL = TranscriptSaver.saveRichAssemblyAITranscript(
                combinedResult,
                directory: outputFolder
            ) else {
                throw NSError(domain: "Transcription", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to save transcript"
                ])
            }

            // Progress: 100%
            onProgress?(1.0)

            await MainActor.run {
                self.lastSavedFileURL = fileURL
                self.isProcessing = false
                self.processingStatus = "Complete!"
            }

            print("✅ Transcript saved (AssemblyAI): \(fileURL.lastPathComponent)")

            // Cleanup audio files after successful transcription
            cleanupAudioFiles(micURL: micURL, systemURL: systemURL)

            return fileURL

        } catch {
            // Cleanup temp preprocessed files on failure
            for tempURL in tempFilesToCleanup {
                AudioPreprocessor.cleanup(tempURL: tempURL)
            }

            await MainActor.run {
                self.error = "AssemblyAI transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }

    /// Cleanup audio files after successful transcription
    private func cleanupAudioFiles(micURL: URL, systemURL: URL?) {
        // Delete mic audio file
        do {
            try FileManager.default.removeItem(at: micURL)
            print("🗑️ Deleted mic audio file: \(micURL.lastPathComponent)")
        } catch {
            print("⚠️ Failed to delete mic audio file: \(error.localizedDescription)")
        }

        // Delete system audio file if it exists
        if let systemURL = systemURL {
            do {
                try FileManager.default.removeItem(at: systemURL)
                print("🗑️ Deleted system audio file: \(systemURL.lastPathComponent)")
            } catch {
                print("⚠️ Failed to delete system audio file: \(error.localizedDescription)")
            }
        }
    }
}
