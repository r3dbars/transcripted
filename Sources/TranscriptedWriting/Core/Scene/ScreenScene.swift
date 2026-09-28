import Foundation

/// Turns raw on-device OCR blocks (Screen Memory's capture output, Phase 1)
/// into a bounded, classified `Scene` the completion engine can fold into a
/// prompt (Phase 2b). Pure and deterministic — no LLM, no I/O, no knowledge
/// of ScreenCaptureKit, Vision, or persistence. The App target owns turning
/// pixels into `OCRBlock`s; this type only reasons about the blocks it is
/// handed.
///
/// Screen Memory plan, Phase 2 PR 2a (`docs/plans/screen-memory.md`).
public enum ScreenScene {
    /// A unit-square rectangle in the display's coordinate space
    /// (x/y/width/height all in `0...1`), origin at the **top-left** — y
    /// grows downward, so bottom-of-screen is the largest y. This is
    /// Core's own convention, chosen because "bottom-most = most recent
    /// message" (see `conversationTurns`) is more naturally expressed that
    /// way. It does NOT match `VNRecognizedTextObservation.boundingBox`,
    /// which is lower-left origin with y growing upward — the caller
    /// wiring Phase 1 capture (App target, ScreenCaptureKit + Vision) must
    /// flip y (`y' = 1 - y - height`) when constructing `OCRBlock`s from
    /// real Vision output, or every ordering/geometry heuristic in this
    /// file silently inverts. No AppKit/CoreGraphics dependency — Core
    /// stays framework-free.
    public struct NormalizedRect: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// Horizontal midpoint — the input to left/right speaker bucketing.
        var centerX: Double { x + width / 2 }
    }

    /// One block of OCR'd text from a full-display capture, as Phase 1's
    /// `ScreenCaptureService` would emit it: text plus where on screen it
    /// sat and, where SCWindow metadata resolved it, which window it came
    /// from. `windowOwnerBundleID` is `nil` when attribution wasn't
    /// possible — callers should treat that as "unknown", not "frontmost".
    public struct OCRBlock: Equatable, Sendable {
        public let text: String
        public let boundingBox: NormalizedRect
        public let windowOwnerBundleID: String?
        public let windowIdentifier: UInt32?
        public let windowTitle: String?
        /// The owning window's own bounding box, in the same display-
        /// normalized coordinate space as `boundingBox` — sourced from the
        /// same SCWindow metadata that resolves `windowOwnerBundleID`, so
        /// it's `nil` exactly when attribution is `nil`. Left/right speaker
        /// bucketing needs this: a chat window that isn't fullscreen puts
        /// every block's *display*-relative centerX on one side regardless
        /// of which side of the *window* it's actually on.
        public let windowFrame: NormalizedRect?
        public let confidence: Double?

        public init(
            text: String,
            boundingBox: NormalizedRect,
            windowOwnerBundleID: String? = nil,
            windowIdentifier: UInt32? = nil,
            windowTitle: String? = nil,
            windowFrame: NormalizedRect? = nil,
            confidence: Double? = nil
        ) {
            self.text = text
            self.boundingBox = boundingBox
            self.windowOwnerBundleID = windowOwnerBundleID
            self.windowIdentifier = windowIdentifier
            self.windowTitle = windowTitle
            self.windowFrame = windowFrame
            self.confidence = confidence
        }
    }

    /// What the screen appears to be doing right now.
    public enum Mode: String, Equatable, Sendable {
        /// Frontmost app is a chat register and its own window shows a
        /// vertical message list: the user is replying to a conversation.
        case replying
        /// A non-frontmost window shows text that shares vocabulary with
        /// what's being typed: the user is composing while referencing it.
        case referencing
        /// Neither signal fired. Exactly today's (no-context) behavior.
        case composing
    }

    /// Who plausibly said a conversation turn. Attribution is a left/right
    /// alignment guess, not identity. Ambiguous geometry stays explicitly
    /// unknown; falsely assigning a turn is worse than neutral attribution.
    public enum Speaker: String, Equatable, Sendable {
        case selfSpeaker = "self"
        case other
        case unknown
    }

    public struct ConversationTurn: Equatable, Sendable {
        public let speaker: Speaker
        public let text: String

        public init(speaker: Speaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public struct Scene: Equatable, Sendable {
        public let mode: Mode
        public let conversationTurns: [ConversationTurn]
        public let referenceSnippets: [String]
        /// The title of the window a reply conversation was read from, when
        /// the capture attributed one: it is how the model learns whether it
        /// is looking at a Slack channel, a direct message, or a document.
        /// On-device, memory-only, and scrubbed before it reaches a prompt;
        /// never logged.
        public let windowTitle: String?

        public init(
            mode: Mode,
            conversationTurns: [ConversationTurn],
            referenceSnippets: [String],
            windowTitle: String? = nil
        ) {
            self.mode = mode
            self.conversationTurns = conversationTurns
            self.referenceSnippets = referenceSnippets
            self.windowTitle = windowTitle
        }

        static let empty = Scene(mode: .composing, conversationTurns: [], referenceSnippets: [])
    }

    // MARK: - Caps (plan: "Everything capped")

    /// At most this many conversation turns survive into the scene.
    /// Paragraph-style chats (Claude/ChatGPT-like) carry turns several
    /// sentences long, so the caps allow one more turn and a bigger shared
    /// budget than the bubble-era 3/600 — still under
    /// `RawContinuationPrompt.maxSceneContextCharacters` (1,000).
    public static let maxTurns = 8
    /// Combined character budget across every surviving turn's text.
    public static let maxTurnsCharacterBudget = 2_000
    /// Character cap on the single reference snippet.
    public static let maxReferenceCharacters = 1_000

    // MARK: - Classification

    /// - Parameters:
    ///   - blocks: every OCR block from the latest snapshot, full-display.
    ///   - frontmostBundleID: the app the user is typing into right now.
    ///   - fieldText: the text already in the field (IMKit already has
    ///     this; used only to dedupe and to find "the current sentence").
    public static func classify(
        blocks: [OCRBlock],
        frontmostBundleID: String?,
        targetWindowIdentifier: UInt32? = nil,
        fieldText: String
    ) -> Scene {
        // Geometry-first, host-agnostic (fix for the "demo page rendered in
        // Chrome never gets a Conversation block" bug): a vertical stack of
        // message-like blocks in the frontmost app's OWN window reads as
        // "replying" no matter what that app is. A browser or email client
        // showing a chat-shaped page is exactly as valid a signal as a
        // native chat client — `ContinuationRegister`'s chat-bundle list is
        // NOT consulted here at all anymore; it only still matters as the
        // fallback register (composing/absent scene) that
        // `LlamaCompletionEngine` picks once mode is known (see
        // `RawContinuationPrompt`/`LlamaCompletionEngine` — register follows
        // scene, host app is the fallback).
        if let frontmostBundleID {
            // Only positively-attributed frontmost-window blocks may enter a
            // reply thread. `nil` attribution means "unknown," and treating
            // unknown as "frontmost" is a fail-open path: an unattributed
            // block from some other visible app (full-display capture sees
            // all of them) could get folded into the conversation as if the
            // user's own chat partner said it. Drop-on-doubt beats guessing.
            let ownWindowBlocks = blocks.filter {
                guard $0.windowOwnerBundleID == frontmostBundleID else { return false }
                guard let targetWindowIdentifier else { return true }
                return $0.windowIdentifier == targetWindowIdentifier
            }
            if looksLikeMessageList(ownWindowBlocks) {
                let turns = conversationTurns(from: ownWindowBlocks, fieldText: fieldText)
                if !turns.isEmpty {
                    return Scene(
                        mode: .replying,
                        conversationTurns: turns,
                        referenceSnippets: [],
                        windowTitle: dominantWindowTitle(of: ownWindowBlocks)
                    )
                }
            }
        }

        let snippets = referenceSnippets(from: blocks, frontmostBundleID: frontmostBundleID, fieldText: fieldText)
        if !snippets.isEmpty {
            return Scene(mode: .referencing, conversationTurns: [], referenceSnippets: snippets)
        }

        return .empty
    }

    // MARK: - Replying: message-list geometry + speaker attribution

    /// A message list is at least two bubble-shaped (not full-bleed, not
    /// sliver-narrow) blocks spread across at least two distinct vertical
    /// bands. Full-width blocks (toolbars, banners, a single huge paste)
    /// don't count as bubbles, and neither do slivers: plain chat chrome —
    /// a Slack sidebar's channel names, a DM list, a header — is exactly
    /// two-or-more short OCR lines stacked in different vertical bands, so
    /// the band/count check alone is satisfied by chrome as readily as by
    /// an actual message column. Real message text (even a short reply)
    /// still measures wider than a sidebar label at typical UI font sizes;
    /// `bubbleMinWidth` is the evidence-of-an-actual-message-column signal
    /// the plan calls for, not just "narrow enough to not be a banner."
    private static let bubbleMinWidth = 0.12
    private static let bubbleMaxWidth = 0.85
    private static let verticalBandCount = 10

    /// Width is measured against the block's own window when the frame is
    /// known, for the same reason speaker bucketing is window-relative: a
    /// 340pt bubble in a normal-sized Messages window is 11% of a 3024px
    /// display and would fail `bubbleMinWidth` while being a perfectly
    /// ordinary message. Without a window frame the display is the only
    /// reference there is.
    private static func isBubbleCandidate(_ block: OCRBlock) -> Bool {
        var width = block.boundingBox.width
        if let windowFrame = block.windowFrame, windowFrame.width > 0 {
            width = block.boundingBox.width / windowFrame.width
        }
        return width >= bubbleMinWidth && width <= bubbleMaxWidth && !block.text.isEmpty
    }

    private static func looksLikeMessageList(_ blocks: [OCRBlock]) -> Bool {
        let bubbleBlocks = blocks.filter(isBubbleCandidate)
        guard bubbleBlocks.count >= 2 else { return false }
        let bands = Set(bubbleBlocks.map { verticalBand(of: $0.boundingBox) })
        return bands.count >= 2
    }

    private static func verticalBand(of rect: NormalizedRect) -> Int {
        Int((rect.y * Double(verticalBandCount)).rounded(.down))
    }

    /// Left-aligned bubbles are read as the other party, right-aligned as
    /// the user, matching the near-universal iMessage/Slack/WhatsApp DM
    /// convention. A block straddling the middle (or left of it) is
    /// ambiguous and remains unknown.
    private static let rightBucketMin = 0.58
    private static let leftBucketMax = 0.42

    /// Bucketing needs the block's horizontal position *within its window*,
    /// not within the display: a chat window docked to, say, the right
    /// half of the screen puts every one of its blocks' display-normalized
    /// centerX past the midpoint, which would read every incoming message
    /// as `self`. When the window's frame isn't known, there's no honest
    /// way to recover window-relative position from a display-relative
    /// coordinate — guessing risks exactly that mislabeling, so this stays
    /// unknown rather than assuming the window is fullscreen.
    private static func speaker(for block: OCRBlock) -> Speaker {
        guard let windowFrame = block.windowFrame, windowFrame.width > 0 else { return .unknown }
        let relativeCenter = (block.boundingBox.centerX - windowFrame.x) / windowFrame.width
        if relativeCenter >= rightBucketMin { return .selfSpeaker }
        if relativeCenter <= leftBucketMax { return .other }
        return .unknown
    }

    /// Bottom-most blocks are the most recent messages (the compose field
    /// sits below them). Selects up to `maxTurns`, orders them oldest→newest
    /// for a naturally-readable transcript, and spends the shared character
    /// budget from the newest turn backward so the freshest message never
    /// gets truncated ahead of older ones.
    private static func conversationTurns(from blocks: [OCRBlock], fieldText: String) -> [ConversationTurn] {
        // The compose field is the floor of the conversation: the line
        // where the user's own typed text appears, and everything under
        // it (a placeholder, "Delivered", a hint label), is not a message.
        // Live 2026-08-23: the bottom-4 rule read the typed text back as
        // "Them" and a label under the field as the last message.
        let composeFloor = composeFieldTop(in: blocks, fieldText: fieldText)
        let usable = blocks
            .filter { isBubbleCandidate($0) && !isDuplicate($0.text, of: fieldText) }
            .filter { block in composeFloor.map { block.boundingBox.y < $0 } ?? true }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.boundingBox.y < $1.boundingBox.y }

        let mostRecent = Array(mergeWrappedLines(usable).suffix(maxTurns))

        var remainingBudget = maxTurnsCharacterBudget
        var truncated: [(block: OCRBlock, text: String)] = []
        for (index, block) in mostRecent.reversed().enumerated() {
            guard remainingBudget > 0 else { break }
            // The newest turn keeps its TAIL when over budget — its freshest
            // sentences sit at the end, and they are what the reply is
            // answering. Older turns keep their head with whatever budget is
            // left (they are context, not the thing being answered).
            let text = index == 0
                ? String(block.text.suffix(remainingBudget))
                : String(block.text.prefix(remainingBudget))
            guard !text.isEmpty else { break }
            truncated.append((block, text))
            remainingBudget -= text.count
        }

        return truncated.reversed().map { ConversationTurn(speaker: speaker(for: $0.block), text: $0.text) }
    }

    /// Vision's `VNRecognizeTextRequest` recognizes text LINE by line, not
    /// paragraph by paragraph -- a single multi-line chat bubble surfaces as
    /// several adjacent `OCRBlock`s, one per wrapped line, all from the same
    /// speaker (see `ScreenTextRecognizer`). Left as separate turns, a long
    /// three-line reply would look exactly like three short back-to-back
    /// messages to `RawContinuationPrompt`'s terse-room detector and wrongly
    /// clamp generation to a single short burst (verified: nothing between
    /// Vision and here re-groups wrapped lines back into one block).
    /// Distinguishing a wrapped continuation line from a genuinely separate
    /// next message needs geometry, not just text: lines within one bubble
    /// sit almost flush against each other (ordinary line-height spacing),
    /// while separate bubbles/messages -- even rapid-fire ones from the same
    /// person, like the "up?" / "lol" / "u there" dogfood case -- carry
    /// visible bubble padding and inter-message margin between them. Blocks
    /// from the same speaker whose vertical gap is small relative to their
    /// own height are folded into one logical turn before anything
    /// downstream (including the terse-room median) ever sees them;
    /// everything else, including consecutive short messages from one
    /// speaker with normal spacing, stays as distinct turns.
    private static let wrappedLineMaxGapRatio = 0.6

    private static func mergeWrappedLines(_ sortedBlocks: [OCRBlock]) -> [OCRBlock] {
        var merged: [OCRBlock] = []
        // The height of the LAST LINE folded into each merged entry — the
        // merged block's own height must never be the gap reference:
        // comparing against a growing multi-line block inflates the allowed
        // gap with every merge, so after two wrapped lines join, ordinary
        // paragraph spacing passes the check and an entire paragraph-style
        // conversation (Claude/ChatGPT-like, no bubbles) collapses into one
        // mega-turn (live bug 2026-08-18: 20 visible messages -> 1 turn).
        var lastLineHeights: [Double] = []
        for block in sortedBlocks {
            if let last = merged.last,
               last.windowOwnerBundleID == block.windowOwnerBundleID,
               speaker(for: last) == speaker(for: block) {
                let gap = block.boundingBox.y - (last.boundingBox.y + last.boundingBox.height)
                let referenceHeight = max(lastLineHeights.last ?? 0, block.boundingBox.height)
                if referenceHeight > 0, gap <= referenceHeight * wrappedLineMaxGapRatio {
                    let bottom = max(
                        last.boundingBox.y + last.boundingBox.height,
                        block.boundingBox.y + block.boundingBox.height
                    )
                    merged[merged.count - 1] = OCRBlock(
                        text: last.text + " " + block.text,
                        boundingBox: NormalizedRect(
                            x: min(last.boundingBox.x, block.boundingBox.x),
                            y: last.boundingBox.y,
                            width: max(last.boundingBox.width, block.boundingBox.width),
                            height: bottom - last.boundingBox.y
                        ),
                        windowOwnerBundleID: last.windowOwnerBundleID,
                        windowIdentifier: last.windowIdentifier,
                        windowTitle: last.windowTitle,
                        windowFrame: last.windowFrame,
                        confidence: mergedConfidence(last.confidence, block.confidence)
                    )
                    lastLineHeights[lastLineHeights.count - 1] = block.boundingBox.height
                    continue
                }
            }
            merged.append(block)
            lastLineHeights.append(block.boundingBox.height)
        }
        return merged
    }

    private static func mergedConfidence(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return min(lhs, rhs)
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }

    // MARK: - Referencing: cross-window shared-rare-word snippet

    /// Finds the largest OCR block that (a) confidently comes from a window
    /// other than the frontmost app, (b) isn't already visible in the field
    /// text, and (c) shares at least one rare word with the sentence
    /// currently being typed. Returns at most one snippet — the plan
    /// specifies picking "the largest" qualifying block, not merging many.
    private static func referenceSnippets(
        from blocks: [OCRBlock],
        frontmostBundleID: String?,
        fieldText: String
    ) -> [String] {
        guard let frontmostBundleID else { return [] }
        let sentenceWords = rareWords(in: currentSentence(of: fieldText))
        guard !sentenceWords.isEmpty else { return [] }

        let candidates = blocks.filter { block in
            guard let owner = block.windowOwnerBundleID, owner != frontmostBundleID else { return false }
            guard !isDuplicate(block.text, of: fieldText) else { return false }
            return !rareWords(in: block.text).isDisjoint(with: sentenceWords)
        }

        guard let best = candidates.max(by: { lhs, rhs in
            lhs.text.count == rhs.text.count
                ? lhs.text > rhs.text // deterministic tiebreak, no reliance on input order
                : lhs.text.count < rhs.text.count
        }) else {
            return []
        }

        return [String(best.text.prefix(maxReferenceCharacters))]
    }

    /// The sentence-in-progress: everything after the last sentence
    /// terminator (or the whole field if there isn't one yet).
    /// The title most of the blocks were read under. Blocks in one window
    /// normally share it; the vote guards against a stray attribution.
    /// Ties break on the title text so the answer is deterministic.
    static func dominantWindowTitle(of blocks: [OCRBlock]) -> String? {
        var counts: [String: Int] = [:]
        for block in blocks {
            guard let title = block.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            counts[title, default: 0] += 1
        }
        return counts.max { a, b in
            a.value < b.value || (a.value == b.value && a.key > b.key)
        }?.key
    }

    private static func currentSentence(of fieldText: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        if let index = fieldText.lastIndex(where: terminators.contains) {
            let after = fieldText.index(after: index)
            return String(fieldText[after...]).trimmingCharacters(in: .whitespaces)
        }
        return fieldText.trimmingCharacters(in: .whitespaces)
    }

    /// Words that carry topical signal: lowercase, letters/digits only,
    /// long enough to be distinctive, and not on the stopword list. This is
    /// a deliberately simple stand-in for tf-idf (no corpus to compute
    /// document frequency against) — length + stopwords gets most of the
    /// same signal for short chat/prose snippets.
    private static let minimumRareWordLength = 4
    private static func rareWords(in text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= minimumRareWordLength && !stopwords.contains($0) }
        )
    }

    private static let stopwords: Set<String> = [
        "this", "that", "these", "those", "with", "from", "your", "have",
        "will", "would", "could", "should", "about", "there", "their",
        "which", "when", "where", "what", "just", "like", "know", "think",
        "want", "need", "going", "gonna", "really", "also", "then", "than",
        "them", "they", "were", "been", "being", "into", "over", "some",
        "more", "most", "much", "very", "here", "okay", "right", "good",
        "well", "sure", "yeah", "yes", "no", "not", "the", "and", "for",
        "are", "was", "you", "our", "his", "her", "its", "can",
    ]

    // MARK: - Dedupe

    /// Skips OCR text that's already visible in the field — no double-
    /// feeding what IMKit already sees. Checked both directions (the field
    /// may be a growing prefix of a longer bubble, or the bubble may be a
    /// wrapped/truncated fragment of the full field text), case-
    /// insensitively, and with whitespace/line-wrap differences normalized
    /// away — OCR and the live field text rarely wrap identically. Short
    /// strings are exempted from the containment check on whichever side
    /// is doing the containing (e.g. "ok", "yes") since they'd trivially
    /// "match" almost any text without actually being the same message.
    private static let dedupeMinimumLength = 6
    /// Top edge of the highest block that reads back the user's own typed
    /// text, or `nil` when none does (empty field, or the field is
    /// scrolled out of view). A wrapped compose field yields several
    /// fragments; any fragment of two or more words found in the field
    /// text counts, so the floor sits at the first such line.
    private static func composeFieldTop(in blocks: [OCRBlock], fieldText: String) -> Double? {
        let field = normalizedForDedupe(fieldText)
        guard field.count >= dedupeMinimumLength else { return nil }
        let matches = blocks.filter { block in
            let candidate = normalizedForDedupe(block.text)
            guard candidate.count >= dedupeMinimumLength,
                  candidate.split(separator: " ").count >= 2 else { return false }
            return field.contains(candidate) || candidate.contains(field)
        }
        // A compose field sits in the lower half of its window. A match
        // higher up is a quoted or echoed message, not the field; dedupe
        // still drops it, but it must not cut the thread beneath it.
        guard let lowest = matches.max(by: { $0.boundingBox.y < $1.boundingBox.y }),
              windowRelativeY(of: lowest) >= 0.5 else { return nil }
        return matches.map(\.boundingBox.y).min()
    }

    private static func windowRelativeY(of block: OCRBlock) -> Double {
        guard let frame = block.windowFrame, frame.height > 0 else { return block.boundingBox.y }
        return (block.boundingBox.y - frame.y) / frame.height
    }

    private static func isDuplicate(_ candidateText: String, of fieldText: String) -> Bool {
        let candidate = normalizedForDedupe(candidateText)
        let field = normalizedForDedupe(fieldText)
        guard !candidate.isEmpty, !field.isEmpty else { return false }
        if candidate.count >= dedupeMinimumLength, field.contains(candidate) { return true }
        if field.count >= dedupeMinimumLength, candidate.contains(field) { return true }
        return false
    }

    /// Lowercased with all runs of whitespace (including newlines, so a
    /// wrapped OCR block compares equal to an unwrapped field line)
    /// collapsed to a single space.
    private static func normalizedForDedupe(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
