import CryptoKit
import Foundation

/// The four things "which Tilde is this" used to mean at once, pulled apart.
///
/// `TildeProductProfile` answers only *which build*: bundle identifiers,
/// ports, directories. The three policies below answer *how it behaves*,
/// each owned by one process, and `TildeEffectiveConfiguration` is the
/// whole of it with one digest. The app assembles the configuration from
/// its build and its model choice, stamps the digest and the interaction
/// policy on every response line, and the keyboard adopts what it is told
/// instead of reading interaction behaviour off its own bundle — so "Qwen
/// in the production app" is one reproducible configuration in both
/// processes, and every outcome event names the one that produced it.

/// Model and sampling: what the helper runs and how it is asked.
public struct GeneratorProfile: Codable, Equatable, Sendable {
    public let modelIdentifier: String
    public let temperature: Double
    public let generatedTokenBudget: Int

    public init(modelIdentifier: String, temperature: Double, generatedTokenBudget: Int) {
        self.modelIdentifier = modelIdentifier
        self.temperature = temperature
        self.generatedTokenBudget = generatedTokenBudget
    }
}

/// Gates, cleaning, and prompt shape: what may be shown from what came back.
public struct DecisionPolicy: Codable, Equatable, Sendable {
    public let maximumVisibleWords: Int
    public let sceneEchoMinimumWords: Int
    public let sceneEchoMinimumCharacters: Int
    public let factualGrounding: FactualGroundingPolicy.Mode
    public let replyCueAnchoredToCurrentSentence: Bool
    public let extendedOrdinarySilenceGate: Bool
    public let includesWindowTitleInScene: Bool

    public init(
        maximumVisibleWords: Int,
        sceneEchoMinimumWords: Int,
        sceneEchoMinimumCharacters: Int,
        factualGrounding: FactualGroundingPolicy.Mode,
        replyCueAnchoredToCurrentSentence: Bool,
        extendedOrdinarySilenceGate: Bool,
        includesWindowTitleInScene: Bool
    ) {
        self.maximumVisibleWords = maximumVisibleWords
        self.sceneEchoMinimumWords = sceneEchoMinimumWords
        self.sceneEchoMinimumCharacters = sceneEchoMinimumCharacters
        self.factualGrounding = factualGrounding
        self.replyCueAnchoredToCurrentSentence = replyCueAnchoredToCurrentSentence
        self.extendedOrdinarySilenceGate = extendedOrdinarySilenceGate
        self.includesWindowTitleInScene = includesWindowTitleInScene
    }

    /// The measured production stack: Gemma's gates, byte for byte.
    public static let conservative = DecisionPolicy(
        maximumVisibleWords: CompletionSuggestion.defaultMaxVisibleWords,
        sceneEchoMinimumWords: SceneEchoPolicy.defaultMinimumWords,
        sceneEchoMinimumCharacters: SceneEchoPolicy.defaultMinimumCharacters,
        factualGrounding: .off,
        replyCueAnchoredToCurrentSentence: false,
        extendedOrdinarySilenceGate: false,
        includesWindowTitleInScene: false
    )

    /// Q12/Q13's nominated display filters plus the owner-directed scene
    /// changes of 2026-09-01. Served for the official Qwen choice and the
    /// isolated 9B preview.
    public static let tuned9B = DecisionPolicy(
        maximumVisibleWords: 3,
        sceneEchoMinimumWords: SceneEchoPolicy.defaultMinimumWords,
        sceneEchoMinimumCharacters: 24,
        factualGrounding: .numbersAndNames,
        replyCueAnchoredToCurrentSentence: true,
        extendedOrdinarySilenceGate: false,
        includesWindowTitleInScene: true
    )

    public var sceneSuggestionOptions: SceneSuggestionPolicy.Options {
        SceneSuggestionPolicy.Options(
            extendedOrdinarySilenceGate: extendedOrdinarySilenceGate,
            replyCueAnchoredToCurrentSentence: replyCueAnchoredToCurrentSentence
        )
    }
}

/// Timing and accept behaviour in the keyboard: when a ghost is revealed,
/// whether an accept chains, where a request may start.
public struct InteractionPolicy: Codable, Equatable, Sendable {
    public let chainsCompletionAfterAccept: Bool
    public let calmRevealPostSpaceMilliseconds: Int
    public let calmRevealMidWordMilliseconds: Int
    public let requestsAfterPunctuation: Bool
    /// Whether the model may be asked to finish a word the writer is still
    /// typing. Off, the only thing between spaces is the system dictionary's
    /// completion of a 3+ letter partial (`GhostInputController`'s spell
    /// checker) and the model is asked only at word or punctuation
    /// boundaries. On, the same 3+ letter partial also issues a throttled
    /// model request, the app accepts a mid-word context on the wire, and a
    /// model answer may only *grow* a visible dictionary ghost — never
    /// shrink or rewrite it. Personal serving stays word-boundary only
    /// either way (`GhostBrainServerHost.personalTailWords`).
    public let requestsMidWordContinuation: Bool
    /// How long a mid-word request waits before leaving the keyboard, so a
    /// burst of letters costs one request instead of one per letter. Served
    /// with the rest of the policy and part of the digest, because a trial of
    /// mid-word continuation is a trial of this number too.
    public let midWordRequestThrottleMilliseconds: Int

    public init(
        chainsCompletionAfterAccept: Bool,
        calmRevealPostSpaceMilliseconds: Int,
        calmRevealMidWordMilliseconds: Int,
        requestsAfterPunctuation: Bool,
        requestsMidWordContinuation: Bool,
        midWordRequestThrottleMilliseconds: Int = 0
    ) {
        self.chainsCompletionAfterAccept = chainsCompletionAfterAccept
        self.calmRevealPostSpaceMilliseconds = calmRevealPostSpaceMilliseconds
        self.calmRevealMidWordMilliseconds = calmRevealMidWordMilliseconds
        self.requestsAfterPunctuation = requestsAfterPunctuation
        self.requestsMidWordContinuation = requestsMidWordContinuation
        self.midWordRequestThrottleMilliseconds = midWordRequestThrottleMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case chainsCompletionAfterAccept, calmRevealPostSpaceMilliseconds, calmRevealMidWordMilliseconds
        case requestsAfterPunctuation, requestsMidWordContinuation, midWordRequestThrottleMilliseconds
    }

    /// Fields added after the first served policy decode with their
    /// conservative defaults, so a newer keyboard reading an older app's
    /// interaction object keeps every response rather than failing it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chainsCompletionAfterAccept = try c.decode(Bool.self, forKey: .chainsCompletionAfterAccept)
        calmRevealPostSpaceMilliseconds = try c.decode(Int.self, forKey: .calmRevealPostSpaceMilliseconds)
        calmRevealMidWordMilliseconds = try c.decode(Int.self, forKey: .calmRevealMidWordMilliseconds)
        requestsAfterPunctuation = try c.decode(Bool.self, forKey: .requestsAfterPunctuation)
        requestsMidWordContinuation = try c.decodeIfPresent(Bool.self, forKey: .requestsMidWordContinuation) ?? false
        midWordRequestThrottleMilliseconds = try c.decodeIfPresent(Int.self, forKey: .midWordRequestThrottleMilliseconds) ?? 0
    }

    /// The measured production interaction.
    public static let conservative = InteractionPolicy(
        chainsCompletionAfterAccept: false,
        calmRevealPostSpaceMilliseconds: 200,
        calmRevealMidWordMilliseconds: 120,
        requestsAfterPunctuation: false,
        requestsMidWordContinuation: false
    )

    /// The owner's 9B preview trial of 2026-09-01/02: chained accept, the
    /// shorter Electron reveal floor, punctuation as a request boundary, and
    /// (2026-09-02) mid-word model continuation. Production stays on the
    /// conservative interaction until a live result promotes any of them.
    public static let tuned9B = InteractionPolicy(
        chainsCompletionAfterAccept: true,
        calmRevealPostSpaceMilliseconds: 120,
        calmRevealMidWordMilliseconds: 80,
        requestsAfterPunctuation: true,
        requestsMidWordContinuation: true,
        midWordRequestThrottleMilliseconds: 120
    )

    public var calmRevealDelays: SuggestionRevealDelayPolicy.CalmDelays {
        SuggestionRevealDelayPolicy.CalmDelays(
            postSpaceNanoseconds: UInt64(max(0, calmRevealPostSpaceMilliseconds)) * 1_000_000,
            midWordNanoseconds: UInt64(max(0, calmRevealMidWordMilliseconds)) * 1_000_000
        )
    }
}

/// Everything that decides behaviour, with one digest.
public struct TildeEffectiveConfiguration: Codable, Equatable, Sendable {
    public let generator: GeneratorProfile
    public let decision: DecisionPolicy
    public let interaction: InteractionPolicy

    public init(generator: GeneratorProfile, decision: DecisionPolicy, interaction: InteractionPolicy) {
        self.generator = generator
        self.decision = decision
        self.interaction = interaction
    }

    /// SHA-256 of the canonical (sorted-key) JSON. Two builds that behave
    /// identically share a digest; any changed number changes it.
    public var digestSHA256: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(self) else { return "" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The configuration a build serves for a model identity.
    /// `completionProfile` is the behaviour profile the app resolved for the
    /// model choice (the official Qwen choice maps to the 9B behaviour);
    /// `build` decides the interaction policy, which is why production with
    /// Qwen keeps the conservative interaction until it is promoted.
    public static func resolve(
        build: TildeProductProfile,
        completionProfile: TildeProductProfile,
        modelIdentifier: String
    ) -> TildeEffectiveConfiguration {
        TildeEffectiveConfiguration(
            generator: GeneratorProfile(
                modelIdentifier: modelIdentifier,
                temperature: completionProfile.completionTemperature,
                generatedTokenBudget: completionProfile.generatedTokenBudget
            ),
            decision: completionProfile.decisionPolicy,
            interaction: build.interactionPolicy
        )
    }
}

/// The keyboard's view of the app's interaction policy: its own build's
/// default until the first response line teaches it better, then whatever
/// the app most recently served. Adopting is idempotent and text-free.
public struct ServedInteractionPolicy: Equatable, Sendable {
    public private(set) var policy: InteractionPolicy
    public private(set) var configurationDigest: String?

    public init(default policy: InteractionPolicy) {
        self.policy = policy
        configurationDigest = nil
    }

    /// Returns true when the policy changed.
    @discardableResult
    public mutating func adopt(_ response: GhostBrainResponse) -> Bool {
        if let digest = response.configurationDigest, !digest.isEmpty {
            configurationDigest = digest
        }
        guard let served = response.interaction, served != policy else { return false }
        policy = served
        return true
    }
}
