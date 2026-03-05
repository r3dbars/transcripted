// QwenService.swift
// On-device speaker name inference using Qwen3.5-4B via mlx-swift-lm.
// Reads transcript text and extracts speaker names from conversational context
// ("Hey Jack", "I'm Sarah from..."), pre-filling the naming tray.
//
// Load strategy: on-demand only (NOT at app startup). Loads when unidentified
// speakers exist after DB matching, infers names, then immediately unloads.
// This keeps the ~2.5GB memory spike temporary.

import Foundation
import MLXLLM
import MLXLMCommon

enum QwenModelState: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}

@available(macOS 14.0, *)
@MainActor
class QwenService: ObservableObject {
    @Published var modelState: QwenModelState = .notLoaded

    private var modelContainer: ModelContainer?

    static let modelId = "mlx-community/Qwen3.5-4B-4bit"

    /// Whether the user has enabled Qwen inference in Settings
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "enableQwenSpeakerInference") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "enableQwenSpeakerInference")
    }

    /// Check if the model is already cached locally (downloaded previously)
    nonisolated static var isModelCached: Bool {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/huggingface")
        let modelDir = cacheDir.appendingPathComponent("models--mlx-community--Qwen3.5-4B-4bit")
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    // MARK: - Model Lifecycle

    /// Load model on demand. Downloads from HuggingFace on first use (~2.5GB).
    func loadModel() async {
        guard modelContainer == nil else {
            modelState = .ready
            return
        }

        modelState = .loading
        AppLogger.transcription.info("Qwen loading model", ["modelId": Self.modelId])

        do {
            let container = try await loadModelContainer(
                id: Self.modelId,
                progressHandler: { progress in
                    Task { @MainActor in
                        self.modelState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )

            self.modelContainer = container
            modelState = .ready
            AppLogger.transcription.info("Qwen model loaded and ready")
        } catch {
            modelState = .failed(error.localizedDescription)
            AppLogger.transcription.error("Qwen model load failed", ["error": error.localizedDescription])
        }
    }

    /// Extract speaker names from the first 5 minutes of transcript text.
    /// Returns a mapping of sortformer speaker IDs to inferred names.
    /// Example: ["0": "Jack", "1": "Sarah", "2": "Unknown"]
    nonisolated func inferSpeakerNames(transcript: String) async throws -> [String: String] {
        guard let container = await MainActor.run(body: { self.modelContainer }) else {
            throw NSError(domain: "QwenService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Qwen model not loaded"
            ])
        }

        let prompt = Self.buildPrompt(transcript: transcript)
        AppLogger.transcription.info("Qwen inferring speaker names", ["promptLength": "\(prompt.count)"])

        let userInput = UserInput(prompt: prompt)
        let lmInput = try await container.prepare(input: userInput)

        let parameters = GenerateParameters(
            maxTokens: 200,
            temperature: 0.1
        )

        var responseText = ""
        let stream = try await container.generate(input: lmInput, parameters: parameters)
        for try await generation in stream {
            if case .chunk(let text) = generation {
                responseText += text
            }
        }

        responseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.transcription.info("Qwen inference complete", ["response": "\(responseText.prefix(200))"])

        return Self.parseResponse(responseText)
    }

    /// Free model memory immediately after inference.
    func unload() {
        modelContainer = nil
        modelState = .notLoaded
        AppLogger.transcription.info("Qwen model unloaded")
    }

    // MARK: - Prompt Construction

    nonisolated private static func buildPrompt(transcript: String) -> String {
        """
        You are analyzing a meeting transcript to identify speaker names.
        The transcript uses labels like "Speaker 0", "Speaker 1", etc.

        Identify the real name of each speaker based on:
        - Direct greetings ("Hey Jack", "Hi Sarah")
        - Self-introductions ("I'm Nate from...")
        - Third-person references ("Jack was saying...")
        - Sign-offs ("Thanks everyone, this is Don signing off")

        Return ONLY a JSON object mapping speaker IDs to names.
        Use "Unknown" for speakers whose names cannot be determined.
        Do not include any other text, explanation, or markdown formatting.

        Example output: {"0": "Justin", "1": "Nate", "2": "Unknown"}

        TRANSCRIPT (first 5 minutes):
        ---
        \(transcript)
        """
    }

    // MARK: - Response Parsing

    /// Parse Qwen's response into a speaker ID -> name mapping.
    /// Handles common LLM output quirks: markdown fences, trailing text, etc.
    nonisolated static func parseResponse(_ response: String) -> [String: String] {
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present
        if jsonString.hasPrefix("```json") {
            jsonString = String(jsonString.dropFirst(7))
        } else if jsonString.hasPrefix("```") {
            jsonString = String(jsonString.dropFirst(3))
        }
        if jsonString.hasSuffix("```") {
            jsonString = String(jsonString.dropLast(3))
        }
        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the JSON object boundaries
        guard let openBrace = jsonString.firstIndex(of: "{"),
              let closeBrace = jsonString.lastIndex(of: "}") else {
            AppLogger.transcription.warning("Qwen response has no JSON object", ["response": "\(response.prefix(100))"])
            return [:]
        }

        let jsonSubstring = String(jsonString[openBrace...closeBrace])

        guard let data = jsonSubstring.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            AppLogger.transcription.warning("Qwen response JSON parse failed", ["json": jsonSubstring])
            return [:]
        }

        return parsed
    }
}
