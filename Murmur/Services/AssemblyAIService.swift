import Foundation

// MARK: - Word-level data

struct AssemblyAIWord: Codable {
    let text: String
    let start: Int          // milliseconds
    let end: Int            // milliseconds
    let confidence: Double
    let speaker: String?    // "A", "B", "C", etc. (nil if speaker_labels not enabled)
}

// MARK: - Utterance data (speaker-segmented)

struct AssemblyAIUtterance: Codable {
    let start: Int          // milliseconds
    let end: Int            // milliseconds
    let confidence: Double
    let text: String
    let speaker: String     // "A", "B", "C", etc.
    let words: [AssemblyAIWord]?
}

// MARK: - Sentiment analysis

struct AssemblyAISentimentResult: Codable {
    let text: String
    let start: Int
    let end: Int
    let sentiment: String   // "POSITIVE", "NEUTRAL", "NEGATIVE"
    let confidence: Double
    let speaker: String?

    enum CodingKeys: String, CodingKey {
        case text, start, end, sentiment, confidence, speaker
    }
}

// MARK: - Entity detection

struct AssemblyAIEntity: Codable {
    let entityType: String  // "person_name", "location", "phone_number", etc.
    let text: String
    let start: Int
    let end: Int

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case text, start, end
    }
}

// MARK: - Chapter data (auto_chapters feature)

struct AssemblyAIChapter: Codable {
    let summary: String
    let headline: String
    let start: Int
    let end: Int
    let gist: String
}

// MARK: - Upload response

struct AssemblyAIUploadResponse: Codable {
    let uploadUrl: String

    enum CodingKeys: String, CodingKey {
        case uploadUrl = "upload_url"
    }
}

// MARK: - Transcript submit request

struct AssemblyAITranscriptRequest: Codable {
    let audioUrl: String
    let speakerLabels: Bool
    let sentimentAnalysis: Bool
    let entityDetection: Bool
    let summarization: Bool
    let summaryModel: String
    let summaryType: String
    let languageCode: String

    enum CodingKeys: String, CodingKey {
        case audioUrl = "audio_url"
        case speakerLabels = "speaker_labels"
        case sentimentAnalysis = "sentiment_analysis"
        case entityDetection = "entity_detection"
        case summarization
        case summaryModel = "summary_model"
        case summaryType = "summary_type"
        case languageCode = "language_code"
    }
}

// MARK: - Transcript response (polling)

struct AssemblyAITranscriptResponse: Codable {
    let id: String
    let status: String      // "queued", "processing", "completed", "error"
    let text: String?
    let words: [AssemblyAIWord]?
    let utterances: [AssemblyAIUtterance]?
    let sentimentAnalysisResults: [AssemblyAISentimentResult]?
    let entities: [AssemblyAIEntity]?
    let summary: String?
    let chapters: [AssemblyAIChapter]?
    let audioDuration: Double?
    let error: String?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case id, status, text, words, utterances, summary, chapters, error, confidence
        case sentimentAnalysisResults = "sentiment_analysis_results"
        case entities
        case audioDuration = "audio_duration"
    }
}

// MARK: - Rich transcription result (what we return to callers)

struct AssemblyAITranscriptionResult {
    let utterances: [AssemblyAIUtterance]
    let words: [AssemblyAIWord]
    let entities: [AssemblyAIEntity]
    let sentimentResults: [AssemblyAISentimentResult]
    let summary: String?
    let chapters: [AssemblyAIChapter]
    let metadata: AssemblyAITranscriptionMetadata
}

struct AssemblyAITranscriptionMetadata {
    let transcriptId: String
    let duration: Double?
    let confidence: Double?
    let speakerCount: Int
    let wordCount: Int
    let utteranceCount: Int
}

// MARK: - Processing status (for UI updates)

enum AssemblyAIProcessingStatus: String {
    case uploading = "Uploading audio..."
    case queued = "Queued for processing..."
    case processing = "Transcribing..."
    case analyzing = "Analyzing content..."
    case completed = "Complete!"
    case error = "Error"
}

// MARK: - Error types

enum AssemblyAIError: LocalizedError {
    case noAPIKey
    case uploadFailed(String)
    case invalidResponse
    case transcriptionFailed(String)
    case timeout
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "AssemblyAI API key not configured"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .invalidResponse:
            return "Invalid response from AssemblyAI"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .timeout:
            return "Transcription timed out after 30 minutes"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Service

@available(macOS 14.0, *)
class AssemblyAIService {

    // MARK: - Configuration

    private static let baseURL = "https://api.assemblyai.com/v2"
    private static let maxPollingDurationSeconds: Double = 1800  // 30 minutes
    private static let pollingIntervalSeconds: Double = 3.0      // Poll every 3 seconds

    // MARK: - Status callback type

    typealias StatusCallback = (AssemblyAIProcessingStatus) -> Void

    // MARK: - API Key Validation

    /// Validate API key by making a lightweight request
    static func validateAPIKey(_ key: String) async -> Bool {
        guard !key.isEmpty else { return false }

        // Use the transcript list endpoint to validate the key
        // This is a lightweight GET request that will fail with 401 if key is invalid
        var request = URLRequest(url: URL(string: "\(baseURL)/transcript?limit=1")!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 200 = valid key, 401 = invalid key
            return statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Main Transcription Method

    /// Transcribe audio file with all features enabled
    /// - Parameters:
    ///   - audioURL: Local file URL
    ///   - apiKey: AssemblyAI API key
    ///   - onStatusUpdate: Callback for UI status updates
    /// - Returns: Full transcription result with metadata
    static func transcribe(
        audioURL: URL,
        apiKey: String,
        onStatusUpdate: StatusCallback? = nil
    ) async throws -> AssemblyAITranscriptionResult {
        guard !apiKey.isEmpty else {
            throw AssemblyAIError.noAPIKey
        }

        // Step 1: Upload audio file
        onStatusUpdate?(.uploading)
        print("📤 AssemblyAI: Uploading audio file...")
        let uploadedURL = try await uploadAudio(fileURL: audioURL, apiKey: apiKey)

        // Step 2: Submit transcription request
        onStatusUpdate?(.queued)
        print("📋 AssemblyAI: Submitting transcription job...")
        let transcriptId = try await submitTranscription(audioUrl: uploadedURL, apiKey: apiKey)

        // Step 3: Poll for completion
        print("⏳ AssemblyAI: Polling for completion...")
        let result = try await pollForCompletion(
            transcriptId: transcriptId,
            apiKey: apiKey,
            onStatusUpdate: onStatusUpdate
        )

        onStatusUpdate?(.completed)
        return result
    }

    // MARK: - Upload Audio

    private static func uploadAudio(fileURL: URL, apiKey: String) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        let fileSizeMB = Double(audioData.count) / (1024 * 1024)
        print("📦 AssemblyAI: File size: \(String(format: "%.2f", fileSizeMB)) MB")

        var request = URLRequest(url: URL(string: "\(baseURL)/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData
        request.timeoutInterval = 300  // 5 minutes for large files

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssemblyAIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ AssemblyAI upload failed: HTTP \(httpResponse.statusCode) - \(errorBody)")
            throw AssemblyAIError.uploadFailed("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        let uploadResponse = try JSONDecoder().decode(AssemblyAIUploadResponse.self, from: data)
        print("✓ AssemblyAI: Audio uploaded successfully")

        return uploadResponse.uploadUrl
    }

    // MARK: - Submit Transcription

    private static func submitTranscription(audioUrl: String, apiKey: String) async throws -> String {
        let requestBody = AssemblyAITranscriptRequest(
            audioUrl: audioUrl,
            speakerLabels: true,
            sentimentAnalysis: true,
            entityDetection: true,
            summarization: true,
            summaryModel: "informative",
            summaryType: "paragraph",
            languageCode: "en"
        )

        var request = URLRequest(url: URL(string: "\(baseURL)/transcript")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ AssemblyAI submit failed: \(errorBody)")
            throw AssemblyAIError.transcriptionFailed(errorBody)
        }

        let transcriptResponse = try JSONDecoder().decode(AssemblyAITranscriptResponse.self, from: data)
        print("✓ AssemblyAI: Transcription job submitted: \(transcriptResponse.id)")

        return transcriptResponse.id
    }

    // MARK: - Poll for Completion

    private static func pollForCompletion(
        transcriptId: String,
        apiKey: String,
        onStatusUpdate: StatusCallback?
    ) async throws -> AssemblyAITranscriptionResult {
        let startTime = Date()
        var lastStatus = ""
        var pollCount = 0

        while Date().timeIntervalSince(startTime) < maxPollingDurationSeconds {
            // Wait between polls
            try await Task.sleep(nanoseconds: UInt64(pollingIntervalSeconds * 1_000_000_000))
            pollCount += 1

            // Fetch current status
            var request = URLRequest(url: URL(string: "\(baseURL)/transcript/\(transcriptId)")!)
            request.setValue(apiKey, forHTTPHeaderField: "authorization")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                // Retry on network issues
                print("⚠️ AssemblyAI: Poll request failed, retrying...")
                continue
            }

            let transcriptResponse = try JSONDecoder().decode(AssemblyAITranscriptResponse.self, from: data)

            // Update UI if status changed
            if transcriptResponse.status != lastStatus {
                lastStatus = transcriptResponse.status
                switch transcriptResponse.status {
                case "queued":
                    onStatusUpdate?(.queued)
                case "processing":
                    onStatusUpdate?(.processing)
                default:
                    break
                }
                print("📊 AssemblyAI status: \(transcriptResponse.status) (poll #\(pollCount))")
            }

            // Check for completion
            switch transcriptResponse.status {
            case "completed":
                onStatusUpdate?(.analyzing)
                print("✓ AssemblyAI: Transcription completed after \(pollCount) polls")
                return buildResult(from: transcriptResponse)

            case "error":
                let errorMessage = transcriptResponse.error ?? "Unknown error"
                print("❌ AssemblyAI: Transcription failed - \(errorMessage)")
                throw AssemblyAIError.transcriptionFailed(errorMessage)

            default:
                continue  // Keep polling
            }
        }

        print("❌ AssemblyAI: Timed out after \(Int(maxPollingDurationSeconds / 60)) minutes")
        throw AssemblyAIError.timeout
    }

    // MARK: - Build Result

    private static func buildResult(from response: AssemblyAITranscriptResponse) -> AssemblyAITranscriptionResult {
        let utterances = response.utterances ?? []
        let words = response.words ?? []
        let entities = response.entities ?? []
        let sentimentResults = response.sentimentAnalysisResults ?? []
        let chapters = response.chapters ?? []

        // Count unique speakers
        let speakerSet = Set(utterances.map { $0.speaker })

        let metadata = AssemblyAITranscriptionMetadata(
            transcriptId: response.id,
            duration: response.audioDuration,
            confidence: response.confidence,
            speakerCount: speakerSet.count,
            wordCount: words.count,
            utteranceCount: utterances.count
        )

        print("✓ AssemblyAI transcribed: \(utterances.count) utterances, \(words.count) words, \(speakerSet.count) speakers")
        print("  • Entities: \(entities.count), Sentiment: \(sentimentResults.count) segments")
        print("  • Summary: \(response.summary != nil ? "Yes" : "No"), Chapters: \(chapters.count)")

        return AssemblyAITranscriptionResult(
            utterances: utterances,
            words: words,
            entities: entities,
            sentimentResults: sentimentResults,
            summary: response.summary,
            chapters: chapters,
            metadata: metadata
        )
    }

    // MARK: - Helper: Convert speaker labels to numeric

    /// Convert AssemblyAI speaker labels ("A", "B", "C") to numeric (0, 1, 2)
    static func speakerToInt(_ speaker: String) -> Int {
        guard let char = speaker.first else { return 0 }
        return Int(char.asciiValue ?? 65) - 65  // A=0, B=1, C=2, etc.
    }
}
