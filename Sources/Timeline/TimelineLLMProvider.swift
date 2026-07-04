import Foundation

protocol TimelineLLMProvider: Sendable {
    var providerType: TimelineProviderType { get }
    var modelName: String { get }
    func generateObservations(
        from segments: [TimelineObservationSegment]
    ) async throws -> [TimelineObservationSegment]
    func generateCards(
        observations: [TimelineObservationSegment],
        context: TimelineCardGenerationContext
    ) async throws -> [ActivityCardData]
}

extension TimelineLLMProvider {
    func generateObservations(
        from segments: [TimelineObservationSegment]
    ) async throws -> [TimelineObservationSegment] {
        segments
    }
}

struct LocalFoundationProvider: TimelineLLMProvider {
    let providerType: TimelineProviderType = .localFoundation
    let modelName = "local-foundation-stub"

    func generateCards(
        observations: [TimelineObservationSegment],
        context: TimelineCardGenerationContext
    ) async throws -> [ActivityCardData] {
        throw TimelineAnalysisFailure(kind: .unavailable, reason: "Local timeline card generation is not wired yet.")
    }
}

struct OllamaProvider: TimelineLLMProvider {
    let providerType: TimelineProviderType = .ollama
    let modelName: String
    let endpoint: URL
    let isEnabled: Bool

    init(
        endpoint: URL = URL(string: TimelinePreferences.ollamaEndpoint())!,
        modelName: String = "local-vlm",
        isEnabled: Bool = TimelinePreferences.isEnabled()
    ) {
        self.endpoint = endpoint
        self.modelName = modelName
        self.isEnabled = isEnabled
    }

    func generateCards(
        observations: [TimelineObservationSegment],
        context: TimelineCardGenerationContext
    ) async throws -> [ActivityCardData] {
        guard isEnabled else {
            throw TimelineAnalysisFailure(kind: .unavailable, reason: "Ollama timeline provider is disabled.")
        }
        throw TimelineAnalysisFailure(kind: .unavailable, reason: "Ollama timeline provider network calls are not implemented in this stub.")
    }
}

struct GeminiProvider: TimelineLLMProvider {
    let providerType: TimelineProviderType = .gemini
    let modelName: String
    let hasUserConsent: Bool

    init(modelName: String = "gemini-stub", hasUserConsent: Bool = TimelinePreferences.hasCloudProviderConsent()) {
        self.modelName = modelName
        self.hasUserConsent = hasUserConsent
    }

    func generateCards(
        observations: [TimelineObservationSegment],
        context: TimelineCardGenerationContext
    ) async throws -> [ActivityCardData] {
        guard hasUserConsent else {
            throw TimelineAnalysisFailure(kind: .unavailable, reason: "Gemini timeline provider requires explicit user consent.")
        }
        throw TimelineAnalysisFailure(kind: .unavailable, reason: "Gemini timeline provider network calls are not implemented in this stub.")
    }
}

struct MockTimelineLLMProvider: TimelineLLMProvider {
    let providerType: TimelineProviderType = .mock
    let modelName = "mock"
    var cards: [ActivityCardData]
    var error: Error?

    func generateCards(
        observations: [TimelineObservationSegment],
        context: TimelineCardGenerationContext
    ) async throws -> [ActivityCardData] {
        if let error {
            throw error
        }
        return cards
    }
}

struct TimelineProviderFailureClassifier {
    static func classify(_ error: Error) -> TimelineAnalysisFailureKind {
        if let failure = error as? TimelineAnalysisFailure {
            return failure.kind
        }

        let text = String(describing: error).lowercased()
        if text.contains("429") ||
            text.contains("403") ||
            text.contains("quota") ||
            text.contains("rate limit") ||
            text.contains("too many requests") {
            return .rateLimited
        }

        return .unknown
    }
}
