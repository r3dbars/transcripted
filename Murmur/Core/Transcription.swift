import Foundation
@preconcurrency import AVFoundation

/// Maps speaker labels to identified names from Gemini
struct SpeakerMapping {
    let speakerId: String           // "0", "1", "2" for Deepgram speaker IDs
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

// MARK: - Multichannel Result

/// Wrapper for Deepgram multichannel result with duration and processing time
struct DeepgramMultichannelTranscriptionResult {
    let result: DeepgramMultichannelResult
    let duration: TimeInterval
    let processingTime: TimeInterval
}

/// Multichannel transcription result from Deepgram
/// Provides convenient accessors for common properties
struct MultichannelTranscriptionResult {
    let deepgramResult: DeepgramMultichannelTranscriptionResult

    var duration: TimeInterval { deepgramResult.duration }
    var processingTime: TimeInterval { deepgramResult.processingTime }
    var micUtteranceCount: Int { deepgramResult.result.micUtterances.count }
    var systemUtteranceCount: Int { deepgramResult.result.systemUtterances.count }

    /// All unique speaker IDs in the system audio channel (for Gemini speaker identification)
    /// Deepgram provides speaker diarization within each channel
    var systemSpeakerIds: Set<String> {
        Set(deepgramResult.result.systemUtterances.map { String($0.speaker) })
    }
}

// MARK: - Transcription Service

@available(macOS 26.0, *)
@MainActor
class Transcription: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var processingStatus: String = ""
    @Published var lastSavedFileURL: URL?

    init() {}

    // MARK: - Multichannel Transcription

    /// Transcribe using multichannel mode - merges mic + system into stereo, single API call
    /// This approach provides:
    /// - 50% fewer API calls (1 instead of 2)
    /// - Perfectly synchronized timestamps between mic and system audio
    /// - Channel-based speaker attribution (no guessing who spoke)
    /// - Speaker diarization within each channel (identifies multiple speakers in system audio)
    /// - Lower memory usage (single file processing)
    ///
    /// - Parameters:
    ///   - micURL: Microphone audio file URL
    ///   - systemURL: System audio file URL (required for multichannel)
    ///   - onProgress: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: MultichannelTranscriptionResult with channel-separated utterances
    /// Note: nonisolated to keep heavy async work (audio merging, API calls) off main thread
    nonisolated func transcribeMultichannel(
        micURL: URL,
        systemURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> MultichannelTranscriptionResult {
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

            let deepgramResult = DeepgramMultichannelTranscriptionResult(
                result: result,
                duration: duration,
                processingTime: processingTime
            )

            return MultichannelTranscriptionResult(deepgramResult: deepgramResult)

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
}
