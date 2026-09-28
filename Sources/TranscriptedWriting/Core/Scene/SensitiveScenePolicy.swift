import Foundation

/// 2026-08-16 trust-critical fix (build 2705 dogfood): a demo conversation
/// carried "my dad passed away this morning" / "funeral is going to be next
/// week" in the other party's messages. Two live failures followed —
/// Case A: the user typed "I am so sorry, I will be at the funeral" and the
/// ghost offered "of my friend, I will be there" (garbled relationship: it
/// was Alex's dad, not the user's friend, plus a redundant echo). Case B,
/// worse: the user typed "I'm so" and the ghost offered "sorry I'm late, I"
/// — a lateness cliché completing over visible grief context. Owner verdict:
/// "this doesn't work well."
///
/// Small on-device models cannot reliably do relationship reasoning or match
/// register in a grief/crisis conversation, so the correct product behavior
/// is suppression, not a better guess. This is consistent with the repo's
/// top rule ("silence and noise are both failures" — here noise is a
/// catastrophic failure and silence is the respectful one).
///
/// `SensitiveScenePolicy` is pure, deterministic, and Core-only (no AppKit,
/// no I/O): it looks at every piece of screen text a classified
/// `ScreenScene.Scene` carries — conversation turns (`.replying`) and
/// reference snippets (`.referencing`) alike — for phrases that mark an
/// emotionally sensitive context and, if any match, tells the caller to
/// withhold the suggestion entirely rather than try to produce one.
///
/// Both scene modes are scanned because the failure the policy exists to
/// prevent is about what is VISIBLE to the writer, not about which window
/// it sits in. A `.referencing` scene is "composing while another visible
/// window shares vocabulary with what's being typed" — an obituary draft, a
/// condolence thread, or a diagnosis in a document beside the composer
/// feeds that vocabulary straight into the prompt through
/// `RawContinuationPrompt`'s Reference block, so a model completing over it
/// can produce exactly the tone-deaf suggestion Case B was. Scanning only
/// `conversationTurns` left that half of the surface open.
///
/// Deliberately blunt v1: word-boundary, case-insensitive substring matching
/// against a single flat phrase table, no NLP, no LLM call. It will both
/// miss sensitive scenes phrased unusually and occasionally fire on
/// look-alike phrasing (see `SensitiveScenePolicyTests` for the accepted
/// "surgical strike" false-positive tradeoff). Given the asymmetry — a wrong
/// suggestion in a grief conversation is a product-killing event, an
/// unnecessary silence is invisible — erring toward suppression is the
/// correct v1 shape. Keep the phrase table data-driven and easy to extend
/// rather than growing per-category special-casing.
public enum SensitiveScenePolicy {
    /// One sensitivity class and the phrases that mark it. Data-driven by
    /// design: adding a new sensitive-context class is "add a case and a
    /// phrase list," never new matching logic.
    public enum Category: String, CaseIterable, Equatable, Sendable {
        case bereavement
        case medicalCrisis
        case emergency
        case relationshipEnding
        case jobLoss
    }

    /// Phrases are matched case-insensitively with word/phrase boundaries
    /// (see `compiledPhrases`), so entries should be written lowercase and as
    /// their natural reading form — no need to hand-author regex.
    static let phrasesByCategory: [Category: [String]] = [
        .bereavement: [
            "passed away", "passed on", "passing away",
            "funeral", "funeral home", "memorial service",
            "condolences", "my condolences",
            "loss of my", "loss of her", "loss of his", "loss of our",
            "rip", "rest in peace",
            "he died", "she died", "they died", "he's dead", "she's dead",
            "in loving memory",
        ],
        .medicalCrisis: [
            "in the hospital", "in the er", "in the emergency room",
            "rushed to the hospital",
            "diagnosis", "diagnosed with",
            "surgery went", "went into surgery", "emergency surgery",
            "in the icu", "intensive care",
            "terminal", "stage 4", "stage four",
            "biopsy",
        ],
        .emergency: [
            "car accident", "car crash", "was in an accident",
            "911", "ambulance",
            "house fire", "in a fire",
            "missing person", "went missing",
        ],
        .relationshipEnding: [
            "we broke up", "breaking up with", "broke up with me",
            "filing for divorce", "getting a divorce", "we're divorcing",
            "separated from", "left me",
        ],
        .jobLoss: [
            "got laid off", "laid off from", "was laid off",
            "lost my job", "got fired", "was fired",
            "let go from work",
        ],
    ]

    /// Whether the classified scene should suppress this completion entirely.
    ///
    /// `scene == nil` (no Screen Memory context available for this request,
    /// e.g. plain typing with no screen capture) never fires — the policy
    /// only reasons about text it was actually handed via Screen Memory, so
    /// ordinary context-free typing is completely unaffected.
    ///
    /// Every conversation turn is checked regardless of speaker, but the
    /// policy is deliberately conservative toward suppression on the OTHER
    /// speaker's turns in particular: it's the other party's disclosure
    /// (grief, a diagnosis, a breakup) that small models are least equipped
    /// to reason about correctly, and that's exactly what happened in both
    /// live failure cases above. Reference snippets have no speaker at all,
    /// so they are simply scanned as visible text.
    public static func isSensitive(scene: ScreenScene.Scene?) -> Bool {
        matchedCategory(scene: scene) != nil
    }

    /// Same decision as `isSensitive`, but also returns which category
    /// fired first (deterministic `Category.allCases` order) — useful for
    /// diagnostics or future tuning, though today's caller only logs a
    /// count, never the category or the matched text.
    ///
    /// Conversation turns are scanned before reference snippets, in scene
    /// order, so a `.replying` scene reports exactly the category it always
    /// did; the snippet pass only ever adds a decision where there was none.
    static func matchedCategory(scene: ScreenScene.Scene?) -> Category? {
        guard let scene else { return nil }
        for turn in scene.conversationTurns {
            if let category = matchedCategory(in: turn.text) {
                return category
            }
        }
        for snippet in scene.referenceSnippets {
            if let category = matchedCategory(in: snippet) {
                return category
            }
        }
        return nil
    }

    private static func matchedCategory(in text: String) -> Category? {
        let range = NSRange(text.startIndex..., in: text)
        for category in Category.allCases {
            guard let patterns = compiledPhrases[category] else { continue }
            if patterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
                return category
            }
        }
        return nil
    }

    /// One pattern per phrase, compiled once at type load.
    ///
    /// `isSensitive` runs the whole table against every conversation turn and
    /// every reference snippet on the completion path, and each check used to
    /// escape its phrase and build a fresh `NSRegularExpression`. A
    /// non-sensitive scene — the common case,
    /// and the one that never early-exits — therefore paid for hundreds of
    /// regex compiles per keystroke. Compiling once removes that cost outright.
    ///
    /// A cheap substring pre-filter was tried here first and deliberately
    /// reverted: Swift's `range(of:options:.caseInsensitive)` folds case by a
    /// different rule than ICU's regex engine (full case folding, canonical
    /// equivalence), so it could reject a phrase the pattern would have
    /// matched. That is a silent miss in the one policy whose entire job is to
    /// keep Tilde out of grief and crisis conversations — the wrong place to
    /// trade a guarantee for speed when compiling once costs nothing.
    private static let compiledPhrases: [Category: [NSRegularExpression]] = {
        var table: [Category: [NSRegularExpression]] = [:]
        for (category, phrases) in phrasesByCategory {
            table[category] = phrases.compactMap { phrase in
                let escaped = NSRegularExpression.escapedPattern(for: phrase)
                return try? NSRegularExpression(
                    pattern: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
                    options: [.caseInsensitive]
                )
            }
        }
        return table
    }()
}
