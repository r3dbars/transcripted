import Foundation
import AVFoundation

// MARK: - Response Types (mirrors Deepgram schema for drop-in compatibility)

struct LocalWord: Codable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double
    let channel: String   // "mic" | "sys"
    let speakerId: String

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence, channel
        case speakerId = "speaker_id"
    }
}

struct LocalUtterance: Codable {
    let speakerId: String
    let channel: String
    let start: Double
    let end: Double
    let transcript: String
    let words: [LocalWord]

    enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case channel, start, end, transcript, words
    }

    /// Resolved display name (from VoiceProfileDatabase) or fallback label
    func displayName(using db: VoiceProfileDatabase) -> String {
        db.name(for: speakerId) ?? (channel == "mic" ? "You" : "Speaker")
    }
}

struct LocalTranscriptionResponse: Codable {
    let duration: Double
    let processingTime: Double
    let utterances: [LocalUtterance]
    let speakerCount: Int
    let wordCount: Int

    enum CodingKeys: String, CodingKey {
        case duration
        case processingTime = "processing_time"
        case utterances
        case speakerCount = "speaker_count"
        case wordCount = "word_count"
    }
}

// MARK: - Server lifecycle errors

enum LocalServerError: LocalizedError {
    case serverNotRunning
    case serverStartFailed(String)
    case modelLoading
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "Local inference server not running. Please run inference_server/setup.sh first."
        case .serverStartFailed(let msg):
            return "Failed to start inference server: \(msg)"
        case .modelLoading:
            return "AI models still loading — try again in a moment."
        case .transcriptionFailed(let msg):
            return "Local transcription failed: \(msg)"
        }
    }
}

// MARK: - LocalTranscriptionService

/// Communicates with the local Python inference server (127.0.0.1:8765).
/// Drop-in alternative to DeepgramService — same input/output shape.
@available(macOS 14.2, *)
final class LocalTranscriptionService {

    static let serverURL = URL(string: "http://127.0.0.1:8765")!
    private static var serverProcess: Process?

    // MARK: - Server management

    /// Check if the local server is reachable and models are ready.
    static func serverStatus() async -> (reachable: Bool, modelsReady: Bool) {
        let url = serverURL.appending(path: "health")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return (true, false) // reachable but models not ready (503)
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = json?["status"] as? String
            return (true, status == "ready")
        } catch {
            return (false, false)
        }
    }

    /// Launch the Python inference server as a background process.
    /// Looks for the venv at inference_server/.venv relative to the app bundle.
    static func startServer() throws {
        guard serverProcess == nil else { return }

        let bundleDir = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let serverDir = bundleDir.appending(path: "inference_server")
        let venvPython = serverDir.appending(path: ".venv/bin/python")
        let serverScript = serverDir.appending(path: "server.py")

        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            throw LocalServerError.serverStartFailed(
                "Virtual environment not found at \(venvPython.path). Run inference_server/setup.sh first."
            )
        }

        let process = Process()
        process.executableURL = venvPython
        process.arguments = [serverScript.path]
        process.currentDirectoryURL = serverDir

        // Suppress stdout/stderr in production; redirect to log in debug
        #if DEBUG
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        #else
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        #endif

        try process.run()
        serverProcess = process

        print("🧠 Local inference server started (PID \(process.processIdentifier))")
    }

    static func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    // MARK: - Transcription

    /// Transcribe a stereo WAV file (mic = L, system = R).
    /// Matches the calling convention of DeepgramService.transcribeMultichannel.
    static func transcribeStereo(
        stereoURL: URL,
        onStatusUpdate: ((String) -> Void)? = nil
    ) async throws -> LocalTranscriptionResponse {

        // Ensure server is up
        let (reachable, modelsReady) = await serverStatus()
        if !reachable {
            throw LocalServerError.serverNotRunning
        }
        if !modelsReady {
            throw LocalServerError.modelLoading
        }

        onStatusUpdate?("Sending to local AI...")

        let endpoint = serverURL.appending(path: "transcribe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600 // 10 min for long recordings

        // Build multipart/form-data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let audioData = try Data(contentsOf: stereoURL)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"channel_mode\"\r\n\r\n".data(using: .utf8)!)
        body.append("stereo\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        onStatusUpdate?("Transcribing with Parakeet...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LocalServerError.transcriptionFailed("No HTTP response")
        }

        if http.statusCode == 503 {
            throw LocalServerError.modelLoading
        }

        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LocalServerError.transcriptionFailed("HTTP \(http.statusCode): \(msg)")
        }

        onStatusUpdate?("Processing speakers...")
        let decoder = JSONDecoder()
        let result = try decoder.decode(LocalTranscriptionResponse.self, from: data)

        onStatusUpdate?("Done")
        return result
    }

    // MARK: - Speaker labeling

    /// Assign a human name to a detected speaker ID (persists to server profiles).
    static func labelSpeaker(speakerId: String, name: String) async throws {
        let endpoint = serverURL
            .appending(path: "speakers")
            .appending(path: speakerId)
            .appending(path: "label")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalServerError.transcriptionFailed("Failed to label speaker")
        }
    }
}
