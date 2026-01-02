import Foundation

// MARK: - Deepgram Response Types

/// Top-level response from Deepgram /v1/listen endpoint
struct DeepgramResponse: Codable {
    let metadata: DeepgramMetadata
    let results: DeepgramResults
}

struct DeepgramMetadata: Codable {
    let requestId: String
    let duration: Double?
    let channels: Int
    let modelInfo: DeepgramModelInfo?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case duration
        case channels
        case modelInfo = "model_info"
    }
}

struct DeepgramModelInfo: Codable {
    let name: String?
    let version: String?
    let arch: String?
}

struct DeepgramResults: Codable {
    let channels: [DeepgramChannel]
    let utterances: [DeepgramUtterance]?
}

struct DeepgramChannel: Codable {
    let alternatives: [DeepgramAlternative]
}

struct DeepgramAlternative: Codable {
    let transcript: String
    let confidence: Double
    let words: [DeepgramWord]
}

struct DeepgramWord: Codable {
    let word: String
    let start: Double          // seconds (NOT milliseconds like AssemblyAI)
    let end: Double            // seconds
    let confidence: Double
    let speaker: Int?          // Speaker ID when diarize=true
    let speakerConfidence: Double?
    let punctuatedWord: String?

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence, speaker
        case speakerConfidence = "speaker_confidence"
        case punctuatedWord = "punctuated_word"
    }

    /// Convert start time to milliseconds (for compatibility with existing code)
    var startMilliseconds: Int {
        return Int(start * 1000)
    }

    /// Convert end time to milliseconds
    var endMilliseconds: Int {
        return Int(end * 1000)
    }
}

struct DeepgramUtterance: Codable {
    let start: Double          // seconds
    let end: Double            // seconds
    let confidence: Double
    let channel: Int
    let transcript: String
    let speaker: Int
    let id: String?
    let words: [DeepgramWord]?

    /// Convert start time to milliseconds
    var startMilliseconds: Int {
        return Int(start * 1000)
    }

    /// Convert end time to milliseconds
    var endMilliseconds: Int {
        return Int(end * 1000)
    }
}

// MARK: - Transcription Result Types (matching AssemblyAI patterns)

/// Result from single-source Deepgram transcription
struct DeepgramTranscriptionResult {
    let utterances: [DeepgramUtterance]
    let words: [DeepgramWord]
    let metadata: DeepgramTranscriptionMetadata
}

struct DeepgramTranscriptionMetadata {
    let requestId: String
    let duration: Double?
    let confidence: Double?
    let speakerCount: Int
    let wordCount: Int
    let utteranceCount: Int
}

/// Result from multichannel Deepgram transcription (stereo: mic=left, system=right)
/// Mirrors AssemblyAIMultichannelResult structure for easy integration
struct DeepgramMultichannelResult {
    let micUtterances: [DeepgramUtterance]       // Channel 0 (left = microphone)
    let systemUtterances: [DeepgramUtterance]    // Channel 1 (right = system audio)
    let allUtterances: [DeepgramUtterance]       // Combined, sorted by timestamp
    let micWords: [DeepgramWord]                 // Words from channel 0
    let systemWords: [DeepgramWord]              // Words from channel 1
    let metadata: DeepgramMultichannelMetadata
}

struct DeepgramMultichannelMetadata {
    let requestId: String
    let duration: Double?
    let micWordCount: Int
    let systemWordCount: Int
    let micUtteranceCount: Int
    let systemUtteranceCount: Int
    let micSpeakerCount: Int                     // Speakers detected in mic channel
    let systemSpeakerCount: Int                  // Speakers detected in system channel
}

// MARK: - Processing Status

enum DeepgramProcessingStatus: String {
    case uploading = "Uploading audio..."
    case processing = "Transcribing..."
    case completed = "Complete!"
    case error = "Error"
}

// MARK: - Error Types

enum DeepgramError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case transcriptionFailed(String)
    case networkError(Error)
    case rateLimited
    case paymentRequired
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Deepgram API key not configured"
        case .invalidResponse:
            return "Invalid response from Deepgram"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .rateLimited:
            return "Rate limited - please try again later"
        case .paymentRequired:
            return "Insufficient Deepgram credits"
        case .fileTooLarge:
            return "Audio file exceeds 2GB limit"
        }
    }
}

// MARK: - Service

@available(macOS 14.0, *)
class DeepgramService {

    // MARK: - Configuration

    private static let baseURL = "https://api.deepgram.com/v1/listen"
    private static let maxRetries = 4
    private static let maxFileSizeBytes: Int64 = 2 * 1024 * 1024 * 1024  // 2GB

    // MARK: - Status Callback Type

    typealias StatusCallback = (DeepgramProcessingStatus) -> Void

    // MARK: - API Key Validation

    /// Validate API key by making a lightweight request
    static func validateAPIKey(_ key: String) async -> Bool {
        guard !key.isEmpty else { return false }

        // Create a minimal audio request to test auth
        // Deepgram doesn't have a dedicated auth check endpoint,
        // so we'll use a HEAD-like request or minimal validation
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        // Send minimal data - Deepgram will return 400 for empty audio but 401 for bad auth
        request.httpBody = Data()

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 400 = valid key but bad audio (expected)
            // 401 = invalid key
            // 200 = somehow worked
            return statusCode != 401 && statusCode != 403
        } catch {
            return false
        }
    }

    // MARK: - Single Source Transcription

    /// Transcribe a single audio file with speaker diarization
    static func transcribe(
        audioURL: URL,
        apiKey: String,
        onStatusUpdate: StatusCallback? = nil
    ) async throws -> DeepgramTranscriptionResult {
        guard !apiKey.isEmpty else {
            throw DeepgramError.noAPIKey
        }

        onStatusUpdate?(.uploading)
        print("📤 Deepgram: Uploading audio file...")

        let response = try await sendTranscriptionRequest(
            audioURL: audioURL,
            apiKey: apiKey,
            multichannel: false,
            onStatusUpdate: onStatusUpdate
        )

        onStatusUpdate?(.completed)
        return buildSingleSourceResult(from: response)
    }

    // MARK: - Multichannel Transcription

    /// Transcribe stereo audio with multichannel + diarization
    /// - Channel 0 (left): Microphone audio (you)
    /// - Channel 1 (right): System audio (meeting participants with speaker diarization)
    ///
    /// This is the key advantage over AssemblyAI - multichannel AND diarization work together!
    ///
    /// - Parameters:
    ///   - stereoAudioURL: Stereo WAV file (left=mic, right=system)
    ///   - apiKey: Deepgram API key
    ///   - onStatusUpdate: Callback for UI status updates
    /// - Returns: Multichannel result with channel-separated AND speaker-separated utterances
    static func transcribeMultichannel(
        stereoAudioURL: URL,
        apiKey: String,
        onStatusUpdate: StatusCallback? = nil
    ) async throws -> DeepgramMultichannelResult {
        guard !apiKey.isEmpty else {
            throw DeepgramError.noAPIKey
        }

        onStatusUpdate?(.uploading)
        print("📤 Deepgram Multichannel: Uploading stereo audio...")

        let response = try await sendTranscriptionRequest(
            audioURL: stereoAudioURL,
            apiKey: apiKey,
            multichannel: true,
            onStatusUpdate: onStatusUpdate
        )

        onStatusUpdate?(.completed)
        return buildMultichannelResult(from: response)
    }

    // MARK: - Core Request Logic

    private static func sendTranscriptionRequest(
        audioURL: URL,
        apiKey: String,
        multichannel: Bool,
        onStatusUpdate: StatusCallback?
    ) async throws -> DeepgramResponse {

        // Check file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0
        let fileSizeMB = Double(fileSize) / (1024 * 1024)

        guard fileSize < maxFileSizeBytes else {
            throw DeepgramError.fileTooLarge
        }

        print("📦 Deepgram: File size: \(String(format: "%.2f", fileSizeMB)) MB")

        // Build URL with query parameters
        var urlComponents = URLComponents(string: baseURL)!
        var queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "language", value: "en")
        ]

        if multichannel {
            queryItems.append(URLQueryItem(name: "multichannel", value: "true"))
        }

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            throw DeepgramError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600  // 10 minutes for large files

        // Retry with exponential backoff
        var lastError: Error?

        for attempt in 0..<maxRetries {
            if attempt > 0 {
                let delay = pow(2.0, Double(attempt)) + Double.random(in: 0..<1)
                print("⏳ Deepgram: Retrying in \(String(format: "%.1f", delay))s (attempt \(attempt + 1)/\(maxRetries))...")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                onStatusUpdate?(.processing)

                // Stream file directly from disk (memory efficient)
                let (data, response) = try await URLSession.shared.upload(for: request, fromFile: audioURL)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw DeepgramError.invalidResponse
                }

                // Handle specific error codes
                switch httpResponse.statusCode {
                case 200...299:
                    // Success - parse response
                    let decoder = JSONDecoder()
                    let deepgramResponse = try decoder.decode(DeepgramResponse.self, from: data)
                    print("✓ Deepgram: Transcription complete")
                    return deepgramResponse

                case 401, 403:
                    throw DeepgramError.noAPIKey

                case 402:
                    throw DeepgramError.paymentRequired

                case 413:
                    throw DeepgramError.fileTooLarge

                case 429:
                    // Rate limited - will retry
                    print("⚠️ Deepgram: Rate limited, will retry...")
                    lastError = DeepgramError.rateLimited
                    continue

                case 408, 500, 502, 503, 504:
                    // Retryable errors
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    print("⚠️ Deepgram: HTTP \(httpResponse.statusCode) - \(errorBody)")
                    lastError = DeepgramError.transcriptionFailed("HTTP \(httpResponse.statusCode)")
                    continue

                default:
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw DeepgramError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(errorBody)")
                }

            } catch let error as DeepgramError {
                // Non-retryable Deepgram errors
                if case .noAPIKey = error { throw error }
                if case .paymentRequired = error { throw error }
                if case .fileTooLarge = error { throw error }
                lastError = error
            } catch {
                lastError = DeepgramError.networkError(error)
            }
        }

        throw lastError ?? DeepgramError.transcriptionFailed("Max retries exceeded")
    }

    // MARK: - Build Results

    private static func buildSingleSourceResult(from response: DeepgramResponse) -> DeepgramTranscriptionResult {
        // Collect all words and utterances
        var allWords: [DeepgramWord] = []

        for channel in response.results.channels {
            for alternative in channel.alternatives {
                allWords.append(contentsOf: alternative.words)
            }
        }

        let utterances = response.results.utterances ?? []

        // Count unique speakers
        let speakerSet = Set(allWords.compactMap { $0.speaker })

        // Calculate overall confidence
        let avgConfidence: Double
        if !allWords.isEmpty {
            avgConfidence = allWords.reduce(0) { $0 + $1.confidence } / Double(allWords.count)
        } else {
            avgConfidence = 0
        }

        let metadata = DeepgramTranscriptionMetadata(
            requestId: response.metadata.requestId,
            duration: response.metadata.duration,
            confidence: avgConfidence,
            speakerCount: speakerSet.count,
            wordCount: allWords.count,
            utteranceCount: utterances.count
        )

        print("✓ Deepgram transcribed: \(utterances.count) utterances, \(allWords.count) words, \(speakerSet.count) speakers")

        return DeepgramTranscriptionResult(
            utterances: utterances,
            words: allWords,
            metadata: metadata
        )
    }

    private static func buildMultichannelResult(from response: DeepgramResponse) -> DeepgramMultichannelResult {
        let utterances = response.results.utterances ?? []

        // Separate utterances by channel
        // Channel 0 = Left = Microphone
        // Channel 1 = Right = System audio
        let micUtterances = utterances.filter { $0.channel == 0 }
        let systemUtterances = utterances.filter { $0.channel == 1 }

        // Collect words by channel
        var micWords: [DeepgramWord] = []
        var systemWords: [DeepgramWord] = []

        if response.results.channels.count >= 1 {
            for alternative in response.results.channels[0].alternatives {
                micWords.append(contentsOf: alternative.words)
            }
        }

        if response.results.channels.count >= 2 {
            for alternative in response.results.channels[1].alternatives {
                systemWords.append(contentsOf: alternative.words)
            }
        }

        // Sort all utterances by timestamp
        let sortedAll = utterances.sorted { $0.start < $1.start }

        // Count unique speakers per channel
        let micSpeakers = Set(micUtterances.map { $0.speaker })
        let systemSpeakers = Set(systemUtterances.map { $0.speaker })

        let metadata = DeepgramMultichannelMetadata(
            requestId: response.metadata.requestId,
            duration: response.metadata.duration,
            micWordCount: micWords.count,
            systemWordCount: systemWords.count,
            micUtteranceCount: micUtterances.count,
            systemUtteranceCount: systemUtterances.count,
            micSpeakerCount: micSpeakers.count,
            systemSpeakerCount: systemSpeakers.count
        )

        print("✓ Deepgram Multichannel transcribed:")
        print("  • Channel 0 (Mic): \(micUtterances.count) utterances, ~\(micWords.count) words, \(micSpeakers.count) speaker(s)")
        print("  • Channel 1 (System): \(systemUtterances.count) utterances, ~\(systemWords.count) words, \(systemSpeakers.count) speaker(s)")

        return DeepgramMultichannelResult(
            micUtterances: micUtterances,
            systemUtterances: systemUtterances,
            allUtterances: sortedAll,
            micWords: micWords,
            systemWords: systemWords,
            metadata: metadata
        )
    }
}
