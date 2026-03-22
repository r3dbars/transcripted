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

/// Combined output from Qwen inference: speaker names + optional meeting title
struct QwenInferenceOutput {
    let speakers: [String: String]
    let meetingTitle: String?
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
    /// mlx-swift-lm caches at ~/Library/Caches/models/ (not HuggingFace's path)
    nonisolated static var isModelCached: Bool {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/models/mlx-community")
        let modelDir = cacheDir.appendingPathComponent("Qwen3.5-4B-4bit")
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    // MARK: - Model Lifecycle

    /// Load model on demand. Downloads from HuggingFace on first use (~2.5GB).
    /// Guards against double-load: if already loading or ready, returns immediately.
    func loadModel() async {
        guard modelContainer == nil else {
            modelState = .ready
            return
        }

        // Prevent double-load race: if another caller started loading during an await suspension,
        // this guard catches the second entry. Without this, two 2.5GB model instances could be
        // allocated simultaneously — potential OOM on 8GB Macs.
        guard modelState != .loading else {
            AppLogger.transcription.debug("Qwen loadModel already in progress, skipping")
            return
        }
        if case .downloading = modelState { return }

        modelState = .loading
        AppLogger.transcription.info("Qwen loading model", ["modelId": Self.modelId])

        do {
            // Pre-populate cache from HuggingFace with mirror fallback before
            // mlx-swift-lm tries its own download. If files already exist, this is a no-op.
            if !Self.isModelCached {
                modelState = .downloading(progress: 0)
                do {
                    try await ModelDownloadService.prePopulateQwenCache(
                        modelId: Self.modelId,
                        progressHandler: { [weak self] progress in
                            Task { @MainActor in
                                self?.modelState = .downloading(progress: progress)
                            }
                        }
                    )
                } catch {
                    // Pre-population failed — fall through to mlx-swift-lm's built-in download
                    // which may still succeed (e.g. if only the mirror API was unreachable)
                    AppLogger.transcription.warning("Qwen pre-population failed, falling back to mlx-swift-lm download", [
                        "error": error.localizedDescription
                    ])
                }
            }

            let container = try await loadModelContainer(
                id: Self.modelId,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.modelState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )

            self.modelContainer = container
            modelState = .ready
            AppLogger.transcription.info("Qwen model loaded and ready")
        } catch {
            let kind = ModelDownloadService.classifyError(error)
            modelState = .failed(kind.detail)
            AppLogger.transcription.error("Qwen model load failed", ["error": error.localizedDescription, "kind": kind.title])
        }
    }

    /// Extract speaker names and meeting title from transcript text.
    /// Returns a QwenInferenceOutput with speaker ID → name mapping and optional title.
    nonisolated func inferSpeakerNames(transcript: String) async throws -> QwenInferenceOutput {
        guard let container = await MainActor.run(body: { self.modelContainer }) else {
            throw PipelineError.modelNotLoaded(model: "Qwen")
        }

        let chatMessages = Self.buildChatMessages(transcript: transcript)
        AppLogger.transcription.info("Qwen inferring speaker names + title", ["promptLength": "\(transcript.count)"])

        var userInput = UserInput(chat: chatMessages)
        userInput.additionalContext = ["enable_thinking": false]
        let lmInput = try await container.prepare(input: userInput)

        let parameters = GenerateParameters(
            maxTokens: 250,
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
        AppLogger.transcription.info("Qwen inference complete", ["response": "\(responseText.prefix(300))"])

        return Self.parseResponse(responseText)
    }

    /// Free model memory immediately after inference.
    func unload() {
        modelContainer = nil
        modelState = .notLoaded
        AppLogger.transcription.info("Qwen model unloaded")
    }

    // MARK: - Prompt Construction

    nonisolated private static func buildChatMessages(transcript: String) -> [Chat.Message] {
        let systemPrompt = """
        You extract speaker names from meeting transcripts.

        RULES:
        - Lines with [Speaker 0], [Speaker 1] etc. are UNKNOWN speakers. Find their names.
        - Lines with a real name like [Jenny] or [Jenny?] are ALREADY IDENTIFIED. Ignore them.
        - Return a JSON object mapping speaker numbers to names.
        - Use "Unknown" if you cannot find a name.
        - Names often appear as: "[Name], did you...", "[Name], can you...", "Thanks [Name]", "pass it to [Name]", "over to [Name]"
        - The speaker who talks NEXT after being addressed by name IS that person.
        - Scan the ENTIRE transcript, not just the beginning. Names often appear late in meetings.

        CRITICAL RULE — "Hey Jack" DOES NOT MEAN THE SPEAKER IS JACK:
        When someone SAYS a name, they are talking TO that person, not introducing themselves.
        The name belongs to the LISTENER, not the speaker.

        EXAMPLE 1 — Greeting identifies the listener:
        [00:00] [Speaker 0] Hey Jack, how are you?
        [00:05] [Speaker 1] I'm doing great, thanks!

        Speaker 0 said "Hey Jack" → Speaker 0 is talking TO Jack → Speaker 1 is Jack.
        Answer: {"0": "Unknown", "1": "Jack"}

        EXAMPLE 2 — Self-introduction:
        [00:00] [Speaker 0] Welcome everyone. I'm Sarah from marketing.
        [00:10] [Speaker 1] Thanks Sarah. This is Mike.
        [00:20] [Speaker 0] Great, Mike. Let's get started.

        Speaker 0 said "I'm Sarah" → Speaker 0 is Sarah.
        Speaker 1 said "This is Mike" → Speaker 1 is Mike.
        Answer: {"0": "Sarah", "1": "Mike"}

        EXAMPLE 3 — Handoff and back-reference:
        [00:00] [Speaker 0] Let me hand it over to David.
        [00:05] [Speaker 1] Thanks! So as I was saying...
        [00:15] [Speaker 0] Good point. Alex, what do you think?
        [00:20] [Speaker 2] I agree with what David said earlier.

        Speaker 0 said "hand it over to David" → Speaker 1 is David.
        Speaker 0 said "Alex, what do you think?" → Speaker 2 is Alex.
        Speaker 2 said "what David said" confirms Speaker 1 is David.
        Answer: {"0": "Unknown", "1": "David", "2": "Alex"}

        EXAMPLE 4 — Mid-conversation direct address:
        [10:00] [Speaker 0] So I think we should move forward with that. Speaker 1, what do you think?
        [10:05] [Speaker 0] Keen, did you have anything you wanted to talk about?
        [10:10] [Speaker 2] Yeah, I just think some things we've noticed...

        Speaker 0 said "Keen, did you have anything?" → Speaker 2 is Keen.
        Answer: {"0": "Unknown", "1": "Unknown", "2": "Keen"}

        EXAMPLE 5 — Handoff / passing to someone:
        [15:00] [Speaker 0] Let me pass it to Sarah for the update.
        [15:05] [Speaker 1] Thanks. So the latest on the project is...
        [20:00] [Speaker 0] Jack, can you walk us through the demo?
        [20:05] [Speaker 2] Sure, so what I built is...

        Speaker 0 said "pass it to Sarah" → Speaker 1 is Sarah.
        Speaker 0 said "Jack, can you walk us through" → Speaker 2 is Jack.
        Answer: {"0": "Unknown", "1": "Sarah", "2": "Jack"}

        EXAMPLE 6 — Back-references that confirm identity:
        [05:00] [Speaker 0] Great work on the dashboard, James.
        [05:05] [Speaker 1] Thanks, I spent most of the week on it.
        [30:00] [Speaker 2] I agree with what James said earlier.

        Speaker 0 said "Great work... James" to Speaker 1 → Speaker 1 is James.
        Speaker 2 said "what James said" referring to Speaker 1 → confirms Speaker 1 is James.
        Answer: {"0": "Unknown", "1": "James", "2": "Unknown"}

        OUTPUT FORMAT:
        Return ONLY a JSON object with two keys:
        1. "speakers": mapping of speaker numbers to names, e.g. {"0": "Sarah", "1": "Unknown"}
        2. "title": a short meeting title (3-6 words) describing the main topic discussed

        Keys in "speakers" are speaker numbers only: "0", "1", "2" — not "Speaker 0".
        The title should be specific and descriptive, like "Sprint Planning Review" or "Q1 Budget Discussion".
        If you cannot determine a topic, use "Meeting" as the title.

        Example output: {"speakers": {"0": "Sarah", "1": "Mike"}, "title": "Product Launch Planning"}
        No explanation. No markdown. Just the JSON object.
        """

        let userMessage = """
        TRANSCRIPT:
        ---
        \(transcript)
        """

        return [
            .system(systemPrompt),
            .user(userMessage)
        ]
    }

    // MARK: - Response Parsing

    /// Parse Qwen's response into speaker names + optional meeting title.
    /// Handles both new format {"speakers": {...}, "title": "..."} and
    /// legacy flat format {"0": "Sarah", "1": "Mike"} for robustness.
    nonisolated static func parseResponse(_ response: String) -> QwenInferenceOutput {
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
            return QwenInferenceOutput(speakers: [:], meetingTitle: nil)
        }

        let jsonSubstring = String(jsonString[openBrace...closeBrace])

        guard let data = jsonSubstring.data(using: .utf8) else {
            AppLogger.transcription.warning("Qwen response not valid UTF-8", ["json": jsonSubstring])
            return QwenInferenceOutput(speakers: [:], meetingTitle: nil)
        }

        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLogger.transcription.warning("Qwen response JSON is not a dictionary", ["json": jsonSubstring])
                return QwenInferenceOutput(speakers: [:], meetingTitle: nil)
            }

            // New format: {"speakers": {"0": "Sarah"}, "title": "Sprint Planning"}
            if let speakersDict = parsed["speakers"] as? [String: String] {
                let title = parsed["title"] as? String
                let cleanTitle = (title == nil || title == "Meeting") ? nil : title
                return QwenInferenceOutput(speakers: speakersDict, meetingTitle: cleanTitle)
            }

            // Legacy flat format: {"0": "Sarah", "1": "Mike"}
            if let flatDict = parsed as? [String: String] {
                return QwenInferenceOutput(speakers: flatDict, meetingTitle: nil)
            }

            AppLogger.transcription.warning("Qwen response JSON has unexpected structure", ["json": jsonSubstring])
            return QwenInferenceOutput(speakers: [:], meetingTitle: nil)
        } catch {
            AppLogger.transcription.warning("Qwen response JSON parse failed", ["json": jsonSubstring, "error": error.localizedDescription])
            return QwenInferenceOutput(speakers: [:], meetingTitle: nil)
        }
    }
}
