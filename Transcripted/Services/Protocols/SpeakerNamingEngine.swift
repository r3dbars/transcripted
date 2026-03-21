import Foundation

// MARK: - Speaker Naming Engine Protocol (LLM-based)
// Conformer: QwenService

@available(macOS 14.0, *)
@MainActor
protocol SpeakerNamingEngine: ObservableObject {
    /// Whether the user has enabled this inference in Settings
    static var isEnabled: Bool { get }

    /// Whether the model is already cached locally
    static var isModelCached: Bool { get }

    /// Load the LLM model (may download on first use)
    func loadModel() async

    /// Unload the model to free memory
    func unload()

    /// Infer speaker names from transcript text
    /// - Parameter transcript: Formatted transcript text with speaker labels
    /// - Returns: Speaker name suggestions and optional meeting title
    func inferSpeakerNames(transcript: String) async throws -> QwenInferenceOutput
}
