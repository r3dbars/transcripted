#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif

/// What the outcome ledger is told about a ghost's origin: the register the
/// generator actually composed with and which expert produced the text.
/// Both come from the app's response receipt for model ghosts and are fixed
/// for the dictionary path; the keyboard never re-derives a register from
/// the host bundle for a ghost the app served.
struct GhostProvenance: Equatable, Sendable {
    let register: ContinuationRegister
    let source: TextFreeCandidateSource
    /// The app's receipt behind this ghost; `nil` on the dictionary path.
    let receipt: GhostDecisionReceipt?

    init(register: ContinuationRegister, source: TextFreeCandidateSource) {
        self.register = register
        self.source = source
        receipt = nil
    }

    /// An app older than the receipt sends neither field: the register
    /// falls back to the host's own and the source is labelled legacy,
    /// never guessed as the base model.
    init(receipt: GhostBrainResponse, hostBundleIdentifier: String) {
        register = receipt.register.flatMap(ContinuationRegister.init(rawValue:))
            ?? ContinuationRegister.from(bundleIdentifier: hostBundleIdentifier)
        source = receipt.source.flatMap(TextFreeCandidateSource.init(rawValue:))
            ?? .unknownLegacy
        self.receipt = GhostDecisionReceipt(receipt)
    }
}

/// The app's decision receipt for one opportunity, read off a terminal
/// response line. Missing fields mean an app older than the receipt; the
/// keyboard then records only what it knows itself.
struct GhostDecisionReceipt: Equatable, Sendable {
    let register: ContinuationRegister?
    let reason: SuggestionDecisionReason?
    let generated: Bool?
    let generatorMilliseconds: Int?
    let firstStableWordMilliseconds: Int?
    let configurationDigest: String?

    init(_ response: GhostBrainResponse) {
        register = response.register.flatMap(ContinuationRegister.init(rawValue:))
        reason = response.reason.flatMap(SuggestionDecisionReason.init(rawValue:))
        // A line that carried text was generated whatever an older app
        // omitted; an empty line from an older app stays unknown.
        generated = response.generated ?? (response.suggestion?.isEmpty == false ? true : nil)
        generatorMilliseconds = response.generatorMilliseconds
        firstStableWordMilliseconds = response.firstStableWordMilliseconds
        configurationDigest = response.configurationDigest
    }

    /// The keyboard's own verdicts carry no app fields.
    static let none = GhostDecisionReceipt(
        register: nil, reason: nil, generated: nil,
        generatorMilliseconds: nil, firstStableWordMilliseconds: nil, configurationDigest: nil
    )

    private init(
        register: ContinuationRegister?,
        reason: SuggestionDecisionReason?,
        generated: Bool?,
        generatorMilliseconds: Int?,
        firstStableWordMilliseconds: Int?,
        configurationDigest: String?
    ) {
        self.register = register
        self.reason = reason
        self.generated = generated
        self.generatorMilliseconds = generatorMilliseconds
        self.firstStableWordMilliseconds = firstStableWordMilliseconds
        self.configurationDigest = configurationDigest
    }
}

/// The keyboard's copy of the app's interaction policy and configuration
/// digest, adopted from every response line. Until the first line of a
/// process the build's own default applies. Main thread only.
enum ServedConfiguration {
    private static var served = ServedInteractionPolicy(default: TildeProductProfile.current.interactionPolicy)

    static var interaction: InteractionPolicy { served.policy }
    static var digest: String? { served.configurationDigest }

    static func adopt(_ response: GhostBrainResponse) {
        served.adopt(response)
    }
}
