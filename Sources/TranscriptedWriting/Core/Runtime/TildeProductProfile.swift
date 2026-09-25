import Foundation

/// Separates the daily driver from experimental, locally installed builds.
/// The profile is declared in each packaged bundle's Info.plist. Tests and
/// unbundled command-line tools intentionally fall back to production.
public enum TildeProductProfile: String, Equatable, Sendable {
    case production
    case preview9B = "preview-9b"

    public static let infoDictionaryKey = "TildeProductProfile"

    public static var current: Self {
        resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            declaredProfile: Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        )
    }

    public static func resolve(bundleIdentifier: String?, declaredProfile: String?) -> Self {
        if let declaredProfile, let profile = Self(rawValue: declaredProfile) {
            return profile
        }
        switch bundleIdentifier {
        case "com.justinbetker.draft.preview9b", "com.justinbetker.draft.inputmethod.TranscriptedPreview9B":
            return .preview9B
        default:
            return .production
        }
    }

    public var appBundleIdentifier: String {
        switch self {
        case .production: "com.justinbetker.draft"
        case .preview9B: "com.justinbetker.draft.preview9b"
        }
    }

    public var inputMethodBundleIdentifier: String {
        switch self {
        case .production: "com.justinbetker.draft.inputmethod.Transcripted"
        case .preview9B: "com.justinbetker.draft.inputmethod.TranscriptedPreview9B"
        }
    }

    public var inputMethodConnectionName: String {
        switch self {
        case .production: "TranscriptedKeyboard_1_Connection"
        case .preview9B: "TranscriptedKeyboard_9B_Preview_Connection"
        }
    }

    public var supportDirectoryName: String {
        switch self {
        case .production: "Transcripted/writing"
        case .preview9B: "Tilde 9B Preview"
        }
    }

    public var inputMethodInstalledBundleName: String {
        switch self {
        case .production: "Transcripted Keyboard.app"
        case .preview9B: "TranscriptedKeyboard 9B Preview.app"
        }
    }

    public var displayName: String {
        switch self {
        case .production: "Transcripted"
        case .preview9B: "Tilde 9B Preview"
        }
    }

    public var llamaServerPort: Int {
        switch self {
        case .production: 17_891
        case .preview9B: 17_875
        }
    }

    public var generatedTokenBudget: Int {
        switch self {
        case .production: 20
        case .preview9B: 12
        }
    }

    /// Qwen's validated completion controls are shared by its official model
    /// choice and the isolated 9B preview identity.
    public var completionTemperature: Double {
        switch self {
        case .preview9B: 0.10
        case .production: 0
        }
    }

    // MARK: - Behaviour, owned by the policy objects in TildeConfiguration.swift

    /// Gates, cleaning, and prompt shape this behaviour profile serves.
    /// Production, the 26B preview, and the Model Preview keep the measured
    /// stack; the 9B behaviour (also the official Qwen choice) runs the
    /// Q12/Q13-nominated filters and the owner-directed scene changes.
    public var decisionPolicy: DecisionPolicy {
        self == .preview9B ? .tuned9B : .conservative
    }

    /// Keyboard timing and accept behaviour for this *build*. Only the
    /// isolated 9B preview trials the tuned interaction; production keeps
    /// the measured one for every model choice until a live result
    /// promotes it. The app serves this on every response line and the
    /// keyboard adopts it, so the two processes never disagree.
    public var interactionPolicy: InteractionPolicy {
        self == .preview9B ? .tuned9B : .conservative
    }

    public var maximumVisibleWords: Int { decisionPolicy.maximumVisibleWords }
    public var sceneEchoMinimumWords: Int { decisionPolicy.sceneEchoMinimumWords }
    public var sceneEchoMinimumCharacters: Int { decisionPolicy.sceneEchoMinimumCharacters }
    public var factualGrounding: FactualGroundingPolicy.Mode { decisionPolicy.factualGrounding }
    public var sceneSuggestionOptions: SceneSuggestionPolicy.Options { decisionPolicy.sceneSuggestionOptions }
    public var includesWindowTitleInScene: Bool { decisionPolicy.includesWindowTitleInScene }
    public var chainsCompletionAfterAccept: Bool { interactionPolicy.chainsCompletionAfterAccept }
    public var calmRevealDelays: SuggestionRevealDelayPolicy.CalmDelays { interactionPolicy.calmRevealDelays }
    public var requestsAfterPunctuation: Bool { interactionPolicy.requestsAfterPunctuation }
    public var requestsMidWordContinuation: Bool { interactionPolicy.requestsMidWordContinuation }

    public var personalHistoryKeychainService: String {
        "\(appBundleIdentifier).writing.personal-history"
    }

    public var personalHistoryAuthenticatedData: Data {
        Data("\(appBundleIdentifier).personal-history.v1".utf8)
    }
}
