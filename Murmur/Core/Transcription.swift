import Foundation
@preconcurrency import AVFoundation

/// Maps speaker labels to identified names from Gemini
struct SpeakerMapping {
    let speakerId: String           // "A", "B", "C", "D", etc. or "0", "1", "2" for Deepgram
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

// MARK: - Unified Multichannel Result (Provider-agnostic)

/// Unified multichannel transcription result that wraps either AssemblyAI or Deepgram
/// This allows TranscriptionTaskManager to work with either provider seamlessly
enum UnifiedMultichannelResult {
    case assemblyAI(MultichannelTranscriptionResult)
    case deepgram(DeepgramMultichannelTranscriptionResult)

    var duration: TimeInterval {
        switch self {
        case .assemblyAI(let result): return result.duration
        case .deepgram(let result): return result.duration
        }
    }

    var processingTime: TimeInterval {
        switch self {
        case .assemblyAI(let result): return result.processingTime
        case .deepgram(let result): return result.processingTime
        }
    }

    var micUtteranceCount: Int {
        switch self {
        case .assemblyAI(let result): return result.result.micUtterances.count
        case .deepgram(let result): return result.result.micUtterances.count
        }
    }

    var systemUtteranceCount: Int {
        switch self {
        case .assemblyAI(let result): return result.result.systemUtterances.count
        case .deepgram(let result): return result.result.systemUtterances.count
        }
    }

    /// All unique speaker IDs in the system audio channel (for Gemini speaker identification)
    var systemSpeakerIds: Set<String> {
        switch self {
        case .assemblyAI(let result):
            // AssemblyAI multichannel doesn't have speaker diarization within channels
            return Set(["Remote"])
        case .deepgram(let result):
            // Deepgram has speaker diarization within each channel!
            return Set(result.result.systemUtterances.map { String($0.speaker) })
        }
    }
}

/// Wrapper for Deepgram multichannel result (matches MultichannelTranscriptionResult pattern)
struct DeepgramMultichannelTranscriptionResult {
    let result: DeepgramMultichannelResult
    let duration: TimeInterval
    let processingTime: TimeInterval
}

// MARK: - Transcription Provider

enum TranscriptionProvider: String {
    case deepgram = "deepgram"
    case assemblyai = "assemblyai"

    static var current: TranscriptionProvider {
        let setting = UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "deepgram"
        return TranscriptionProvider(rawValue: setting) ?? .deepgram
    }
}

@available(macOS 26.0, *)
@MainActor
class Transcription: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var processingStatus: String = ""
    @Published var lastSavedFileURL: URL?

    init() {}

    /// Transcribe audio files and return intermediate result WITHOUT saving to disk
    /// This allows speaker identification with Gemini before saving the final transcript
    /// - Parameters:
    ///   - micURL: Mic audio file URL
    ///   - systemURL: System audio file URL (optional)
    ///   - onProgress: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: CombinedAssemblyAIResult with all rich data for further processing
    /// Note: nonisolated to keep heavy async work (file I/O, API calls) off main thread
    nonisolated func transcribeToIntermediateResult(
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
    /// Uses the configured transcription provider (Deepgram or AssemblyAI)
    /// Deepgram advantage: multichannel + diarization work together!
    ///
    /// - Parameters:
    ///   - micURL: Microphone audio file URL
    ///   - systemURL: System audio file URL (required for multichannel)
    ///   - onProgress: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: UnifiedMultichannelResult with channel-separated utterances
    /// Note: nonisolated to keep heavy async work (audio merging, API calls) off main thread
    nonisolated func transcribeMultichannel(
        micURL: URL,
        systemURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> UnifiedMultichannelResult {
        let provider = TranscriptionProvider.current

        switch provider {
        case .deepgram:
            return try await transcribeMultichannelWithDeepgram(
                micURL: micURL,
                systemURL: systemURL,
                onProgress: onProgress
            )
        case .assemblyai:
            let result = try await transcribeMultichannelWithAssemblyAI(
                micURL: micURL,
                systemURL: systemURL,
                onProgress: onProgress
            )
            return .assemblyAI(result)
        }
    }

    // MARK: - Deepgram Multichannel Implementation

    /// Transcribe with Deepgram - supports multichannel + diarization together
    private nonisolated func transcribeMultichannelWithDeepgram(
        micURL: URL,
        systemURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> UnifiedMultichannelResult {
        let apiKey = UserDefaults.standard.string(forKey: "deepgramAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Transcription", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Deepgram API key not configured. Please add your API key in Settings."
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

            print("🔀 Deepgram Multichannel: Merging mic + system into stereo...")
            stereoTempURL = try await AudioPreprocessor.prepareMergedStereoForCloud(
                micURL: micURL,
                systemURL: systemURL
            )

            onProgress?(0.20)

            // Step 2: Transcribe with Deepgram multichannel + diarization
            await MainActor.run {
                self.processingStatus = "Uploading to Deepgram..."
            }

            guard let stereoURL = stereoTempURL else {
                throw NSError(domain: "Transcription", code: 101, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create merged stereo file"
                ])
            }

            let result = try await DeepgramService.transcribeMultichannel(
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

            print("✅ Deepgram Multichannel transcription complete:")
            print("   • Mic utterances: \(result.micUtterances.count)")
            print("   • System utterances: \(result.systemUtterances.count)")
            print("   • System speakers: \(result.metadata.systemSpeakerCount) (diarization!)")
            print("   • Processing time: \(String(format: "%.1f", processingTime))s")

            let wrappedResult = DeepgramMultichannelTranscriptionResult(
                result: result,
                duration: duration,
                processingTime: processingTime
            )

            return .deepgram(wrappedResult)

        } catch {
            // Cleanup temp file on failure
            if let tempURL = stereoTempURL {
                AudioPreprocessor.cleanup(tempURL: tempURL)
            }

            await MainActor.run {
                self.error = "Deepgram transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }

    // MARK: - AssemblyAI Multichannel Implementation (Legacy)

    /// Transcribe with AssemblyAI multichannel mode
    /// Note: AssemblyAI does NOT support diarization with multichannel
    private nonisolated func transcribeMultichannelWithAssemblyAI(
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

            print("🔀 AssemblyAI Multichannel: Merging mic + system into stereo...")
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

            print("✅ AssemblyAI Multichannel transcription complete:")
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
                self.error = "AssemblyAI transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }
}
