import Foundation

/// Why an eligible opportunity ended the way it did: one terminal reason per
/// opportunity, from a fixed vocabulary, so the outcome ledger can explain
/// silence as precisely as it explains a shown ghost.
///
/// Raw values match the Lab's `LabDecisionReason` where the two overlap, so
/// a live line bridges without translation. Reasons the app decides travel
/// back to the keyboard on the response receipt; reasons the keyboard
/// decides never leave it.
public enum SuggestionDecisionReason: String, Codable, CaseIterable, Sendable {
    case shown

    // Decided by the app before inference.
    /// The helper or model is not ready; the keyboard may summon the app.
    case runtimeUnavailable = "runtime-unavailable"
    /// Suggestions are switched off or paused in the app.
    case suggestionsPaused = "suggestions-paused"
    /// The focused field or window changed between request and answer.
    case fieldTargetLost = "field-target-lost"
    case sensitiveScene = "sensitive-scene"
    case promptInjectionScene = "prompt-injection-scene"
    case noIncomingTurn = "no-incoming-turn"
    case resolvedConversation = "resolved-conversation"
    case ambiguousChoice = "ambiguous-choice"
    case nonActionableScene = "non-actionable-scene"
    case completeSentenceScene = "complete-sentence-scene"
    case multipleQuestionsScene = "multiple-questions-scene"
    case ambiguousReferenceScene = "ambiguous-reference-scene"
    case emptyPrompt = "empty-prompt"

    // Decided by the app after inference.
    case emptyOutput = "empty-output"
    case noSuggestion = "no-suggestion"
    case unsafeCharacter = "unsafe-character"
    case promptLeak = "prompt-leak"
    case prefixReplay = "prefix-replay"
    case contextReplay = "context-replay"
    case selfRepetition = "self-repetition"
    case sceneEcho = "scene-echo"
    case unsupportedFact = "unsupported-fact"
    case timeout
    case protocolError = "protocol-error"

    // Decided by the keyboard.
    /// The writer typed on before the answer could be shown.
    case supersededByTyping = "superseded-by-typing"
    /// Text follows the caret, so a ghost could not be rendered safely.
    case notAtGrowingEdge = "not-at-growing-edge"
    /// The model answered, but its text did not extend the dictionary ghost
    /// already on screen, so nothing changed for the writer.
    case behindVisibleGhost = "behind-visible-ghost"

    public init(scene reason: SceneSuggestionPolicy.SuppressionReason) {
        switch reason {
        case .promptInjection: self = .promptInjectionScene
        case .noIncomingTurn: self = .noIncomingTurn
        case .resolvedConversation: self = .resolvedConversation
        case .ambiguousChoice: self = .ambiguousChoice
        case .nonActionableScene: self = .nonActionableScene
        case .completeSentence: self = .completeSentenceScene
        case .multipleQuestions: self = .multipleQuestionsScene
        case .ambiguousReference: self = .ambiguousReferenceScene
        }
    }

    public init(cleaner reason: CompletionCleanRejectionReason) {
        switch reason {
        case .unsafeHiddenOrControlCharacter: self = .unsafeCharacter
        case .emptyOutput: self = .emptyOutput
        case .noSuggestionSentinel: self = .noSuggestion
        case .promptInstructionEcho: self = .promptLeak
        case .emptyAfterPrefixTrimming: self = .prefixReplay
        case .replaysContext: self = .contextReplay
        case .repeatsItself: self = .selfRepetition
        }
    }

    /// The path could not answer at all, as opposed to choosing silence.
    public var isUnavailable: Bool {
        switch self {
        case .runtimeUnavailable, .timeout, .protocolError: true
        default: false
        }
    }

    /// A display policy, gate, or cleaner chose silence. False for the
    /// unavailable reasons and for the keyboard's own host-state reasons,
    /// which are neither a policy nor a model verdict.
    public var isPolicyHidden: Bool {
        switch self {
        case .shown, .supersededByTyping, .notAtGrowingEdge, .behindVisibleGhost: false
        default: !isUnavailable
        }
    }

    /// The v3 outcome word for an opportunity that ended this way unshown.
    public var silentOutcome: String {
        isUnavailable ? "unavailable" : "hidden"
    }
}
