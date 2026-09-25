import Foundation

/// The word tokenizer every context-derived rule shares: the cleaner's
/// typed-prefix trim, its context-replay check, and the prepared context
/// built ahead of them. One definition of "a word" so the prepared form and
/// the per-call form cannot drift apart.
enum CompletionContextWords {
    static func normalizedWords(in text: String) -> [String] {
        wordRanges(in: text).map { normalized(String(text[$0])) }.filter { !$0.isEmpty }
    }

    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let start { ranges.append(start..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }

    static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}

/// The typed context, reduced once to exactly what `CompletionOutputCleaner`
/// asks of it: whether there was a context at all, what kind of character it
/// ends on, and its normalized words.
///
/// The cleaner never needs the context string itself — only these four
/// facts — and deriving them means walking up to
/// `GhostBrainRequest`'s bounded context (thousands of characters) and
/// normalizing every word in it. Streaming used to pay that on every
/// complete-word partial and once more on the final, for a context that
/// cannot change during a request.
public struct PreparedTypedContext: Sendable {
    /// `false` only for a request that carried no context at all. The
    /// cleaner branches on this exactly where it used to branch on
    /// `textBeforeCursor != nil`: an empty-but-present context still runs
    /// the prefix and replay rules (both no-ops on empty words), while an
    /// absent one skips them.
    let isPresent: Bool
    let endsWithWhitespace: Bool
    let endsWithLetter: Bool
    let words: [String]

    /// The no-context request shape.
    static let absent = PreparedTypedContext(textBeforeCursor: nil)

    public init(textBeforeCursor: String?) {
        self.init(textBeforeCursor: textBeforeCursor, tokenizer: CompletionContextWords.normalizedWords(in:))
    }

    /// Test seam: `PreparedCompletionContextTests` counts tokenizer calls to
    /// prove the context is tokenized once per request, not once per partial.
    init(textBeforeCursor: String?, tokenizer: (String) -> [String]) {
        isPresent = textBeforeCursor != nil
        let last = textBeforeCursor?.last
        endsWithWhitespace = last?.isWhitespace == true
        endsWithLetter = last?.isLetter == true
        words = textBeforeCursor.map(tokenizer) ?? []
    }
}

/// Everything one completion request's context implies for the three checks
/// that judge model output: the cleaner, `SceneEchoPolicy`, and
/// `FactualGroundingPolicy`.
///
/// A streaming request runs those checks once per complete-word partial and
/// once more on the final, and each of them used to re-derive its structures
/// from the same unchanged inputs every time — re-tokenizing the typed
/// context, re-normalizing every scene turn and reference snippet,
/// re-extracting the scene's factual anchors. None of that depends on the
/// model output, so it belongs here: built once when the request starts,
/// then handed to every partial and to the final.
///
/// This is a pure restructuring. Each prepared form holds the same values
/// the per-call path computed, and the entry points that take a scene or a
/// context string still exist and now build one of these on the way in — so
/// Lab callers and the visible output are unchanged.
public struct PreparedCompletionContext: Sendable {
    public let typed: PreparedTypedContext
    public let sceneEcho: SceneEchoPolicy.PreparedScene
    public let grounding: FactualGroundingPolicy.PreparedAnchors

    public init(
        textBeforeCursor: String,
        scene: ScreenScene.Scene?,
        profile: TildeProductProfile
    ) {
        typed = PreparedTypedContext(textBeforeCursor: textBeforeCursor)
        sceneEcho = SceneEchoPolicy.prepared(scene: scene, profile: profile)
        grounding = FactualGroundingPolicy.prepared(
            typedContext: textBeforeCursor,
            scene: scene,
            mode: profile.factualGrounding
        )
    }
}
