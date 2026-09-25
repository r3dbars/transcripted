import Testing
@testable import TranscriptedWritingCore

/// Synthetic OCR-block fixtures standing in for real Vision output. Coordinates
/// are normalized (0...1, top-left origin) to match `ScreenScene.NormalizedRect`.
///
/// `windowFrame` defaults to the full display (0,0,1,1) whenever `window` is
/// non-nil — i.e. "a fullscreen window," matching every existing fixture's
/// implicit assumption that display-relative and window-relative coordinates
/// are the same thing. Pass an explicit `windowFrame` to test window-relative
/// bucketing against a non-fullscreen window; `window` alone with no frame
/// (or `window: nil`) models attribution that resolved a bundle ID but not a
/// frame, or didn't resolve at all.
private let fullDisplay = ScreenScene.NormalizedRect(x: 0, y: 0, width: 1, height: 1)

private func block(
    _ text: String,
    x: Double,
    y: Double,
    width: Double = 0.35,
    window: String? = nil,
    title: String? = nil,
    windowFrame: ScreenScene.NormalizedRect? = nil
) -> ScreenScene.OCRBlock {
    ScreenScene.OCRBlock(
        text: text,
        boundingBox: ScreenScene.NormalizedRect(x: x, y: y, width: width, height: 0.05),
        windowOwnerBundleID: window,
        windowTitle: title,
        windowFrame: windowFrame ?? (window != nil ? fullDisplay : nil)
    )
}

private let slack = "com.tinyspeck.slackmacgap"
private let textEdit = "com.apple.TextEdit"
private let notes = "com.apple.Notes"

@Suite("Screen scene classification")
struct ScreenSceneTests {
    // MARK: - Composing (no signal / edge inputs)

    @Test("No OCR blocks at all classifies as composing")
    func emptyBlocksIsComposing() {
        let scene = ScreenScene.classify(blocks: [], frontmostBundleID: textEdit, fieldText: "hello")
        #expect(scene == .init(mode: .composing, conversationTurns: [], referenceSnippets: []))
    }

    @Test("Chat frontmost with no vertical message-list geometry falls back to composing")
    func chatWithoutMessageListIsComposing() {
        // Only one bubble-shaped block -- a list needs at least two.
        let blocks = [block("hey are you around", x: 0.05, y: 0.3, window: slack)]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .composing)
        #expect(scene.conversationTurns.isEmpty)
    }

    @Test("Two blocks in the same vertical band do not form a message list")
    func sameBandDoesNotFormList() {
        let blocks = [
            block("hey are you around", x: 0.05, y: 0.30, window: slack),
            block("for a call today?", x: 0.50, y: 0.31, window: slack), // same decile band as above
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .composing)
    }

    @Test("A full-width block never counts as a bubble, even paired with a real one")
    func fullWidthBlockIsNotABubble() {
        let blocks = [
            block("hey are you around", x: 0.05, y: 0.3, width: 0.35, window: slack),
            block("Slack — #general — 40 members online", x: 0.0, y: 0.0, width: 0.98, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .composing)
    }

    @Test("Narrow sidebar-style labels in different bands don't look like a message list")
    func narrowSidebarLabelsAreNotAMessageList() {
        // Two ordinary short OCR lines (e.g. Slack channel names in the
        // sidebar) in different vertical bands satisfy the old "<=85% width,
        // >=2 bands" check trivially. They must not flip mode to .replying --
        // real message text measures wider than a sidebar label.
        let blocks = [
            block("general", x: 0.01, y: 0.20, width: 0.06, window: slack),
            block("random", x: 0.01, y: 0.45, width: 0.05, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .composing)
        #expect(scene.conversationTurns.isEmpty)
    }

    @Test("Message-list geometry triggers replying in ANY frontmost app, not just a chat-register one")
    func geometryTriggersReplyingRegardlessOfHostApp() {
        // Fix for the live dogfood bug: a chat-shaped conversation rendered
        // in a browser (or any other non-chat-register app) must still
        // classify as replying -- the chat-bundle list is a confidence
        // signal for the completion register downstream, never a gate on
        // whether the scene itself is "replying." `textEdit` here stands in
        // for any host app, including a browser rendering a demo chat page.
        let blocks = [
            block("hey are you around today", x: 0.05, y: 0.30, window: textEdit), // left -> other, oldest
            block("yeah free after 3pm works", x: 0.55, y: 0.60, window: textEdit), // right -> self, newest
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
        #expect(scene.conversationTurns[0].speaker == .other)
        #expect(scene.conversationTurns[1].speaker == .selfSpeaker)
    }

    @Test("Geometry triggers replying for a chat page rendered in a browser bundle ID")
    func browserRenderedChatPageIsReplying() {
        // The exact live-bug shape: a chat conversation rendered inside
        // Chrome, which is neither in `ContinuationRegister`'s chat list nor
        // any other special-cased bundle -- geometry alone must be enough.
        let chrome = "com.google.Chrome"
        let blocks = [
            block("Sure, I can bring a second car", x: 0.05, y: 0.35, window: chrome),
            block("thanks that helps a lot", x: 0.55, y: 0.65, window: chrome),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: chrome, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
    }

    @Test("Geometry triggers replying for a message stack rendered in an email client's own thread view")
    func emailThreadMessageStackIsReplying() {
        // An email thread with short, bubble-width, back-and-forth replies
        // (not a full paragraph of prose) is message-list-shaped even
        // though the app is an email client, not a chat app -- geometry
        // decides, not the host app's register.
        let mail = "com.apple.mail"
        let blocks = [
            block("sounds good, see you then", x: 0.08, y: 0.25, window: mail),
            block("great, I'll bring the slides", x: 0.50, y: 0.55, window: mail),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: mail, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
    }

    @Test("A document pane next to a compose split does not read as a message list")
    func documentWithComposeSplitIsNotAMessageList() {
        // A document/reading-pane layout: one or two full-bleed paragraph
        // blocks (not bubble-width) above a compose field. This must not
        // false-positive into `.replying` just because there happen to be
        // two blocks in two different vertical bands -- the plan's
        // full-width exclusion (`isBubbleCandidate`) is exactly what keeps
        // a document pane from looking like a chat.
        let notesApp = "com.apple.Notes"
        let blocks = [
            block(
                "Q3 planning notes: the launch timeline moved to the 14th per the latest doc revision",
                x: 0.02, y: 0.10, width: 0.95, window: notesApp
            ),
            block(
                "Action items: confirm budget, follow up with design, schedule the review",
                x: 0.02, y: 0.45, width: 0.95, window: notesApp
            ),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: notesApp, fieldText: "")
        #expect(scene.mode == .composing)
        #expect(scene.conversationTurns.isEmpty)
    }

    // MARK: - Replying: mode, ordering, speaker attribution

    @Test("Chat register + vertical message list classifies as replying with ordered turns")
    func chatMessageListIsReplying() {
        let blocks = [
            block("hey are you around today", x: 0.05, y: 0.30, window: slack), // left -> other, oldest
            block("yeah free after 3pm works", x: 0.55, y: 0.60, window: slack), // right -> self, newest
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
        #expect(scene.conversationTurns[0].speaker == .other)
        #expect(scene.conversationTurns[0].text == "hey are you around today")
        #expect(scene.conversationTurns[1].speaker == .selfSpeaker)
        #expect(scene.conversationTurns[1].text == "yeah free after 3pm works")
        #expect(scene.referenceSnippets.isEmpty)
    }

    @Test("A block straddling the horizontal center remains unknown")
    func ambiguousAlignmentFallsBackToOther() {
        let blocks = [
            block("centered system message", x: 0.30, y: 0.30, width: 0.40, window: slack), // center 0.50
            block("clearly on the right", x: 0.60, y: 0.60, width: 0.35, window: slack), // center 0.775 -> self
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns[0].speaker == .unknown)
        #expect(scene.conversationTurns[1].speaker == .selfSpeaker)
    }

    @Test("Speaker bucketing is window-relative, not display-relative, for a non-fullscreen window")
    func speakerBucketingIsWindowRelative() {
        // The chat window occupies only the right half of the display
        // (x: 0.5...1.0). Both blocks sit in the LEFT half of that window --
        // display-normalized centerX would put both past the display
        // midpoint and misread them as `self`; window-relative centerX
        // correctly reads both as `other`.
        let rightHalfWindow = ScreenScene.NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let blocks = [
            block("hey are you around today", x: 0.52, y: 0.30, width: 0.20, window: slack, windowFrame: rightHalfWindow),
            block("free to talk later?", x: 0.53, y: 0.60, width: 0.20, window: slack, windowFrame: rightHalfWindow),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.allSatisfy { $0.speaker == .other })
    }

    @Test("Nothing at or below the compose field counts as a message")
    func composeFieldIsTheConversationFloor() {
        // Live 2026-08-23 geometry: five bubbles, then the user's wrapped
        // typed text in the reply box, then a label under the box.
        let frame = ScreenScene.NormalizedRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6)
        let blocks = [
            block("Hey, are you free Thursday afternoon?", x: 0.41, y: 0.45, width: 0.15, window: slack, windowFrame: frame),
            block("Should be, what time were you thinking?", x: 0.48, y: 0.50, width: 0.12, window: slack, windowFrame: frame),
            block("Could you make 3pm on Thursday?", x: 0.41, y: 0.56, width: 0.14, window: slack, windowFrame: frame),
            block("Let me check my calendar real quick.", x: 0.45, y: 0.60, width: 0.15, window: slack, windowFrame: frame),
            block("No rush, just let me know today if you can.", x: 0.41, y: 0.64, width: 0.13, window: slack, windowFrame: frame),
            // Typed text read back from the compose field, wrapped into fragments.
            block("I can make it", x: 0.48, y: 0.71, width: 0.05, window: slack, windowFrame: frame),
            block("on Thursday", x: 0.48, y: 0.73, width: 0.05, window: slack, windowFrame: frame),
            block("type your reply above", x: 0.47, y: 0.77, width: 0.07, window: slack, windowFrame: frame),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "I can make it on Thursday ")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.last?.text == "No rush, just let me know today if you can.")
        #expect(scene.conversationTurns.last?.speaker == .other)
        #expect(!scene.conversationTurns.contains { $0.text.contains("type your reply") })
        #expect(!scene.conversationTurns.contains { $0.text.contains("I can make it") })
    }

    @Test("With nothing typed there is no floor and the bottom bubbles are used as before")
    func emptyFieldKeepsLegacySelection() {
        let frame = ScreenScene.NormalizedRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6)
        let blocks = [
            block("Could you make 3pm on Thursday?", x: 0.41, y: 0.45, width: 0.14, window: slack, windowFrame: frame),
            block("No rush, just let me know today if you can.", x: 0.41, y: 0.64, width: 0.13, window: slack, windowFrame: frame),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.conversationTurns.count == 2)
    }

    @Test("Bubble width is window-relative: a normal chat window on a large display still reads as a list")
    func bubbleWidthIsWindowRelative() {
        // A ~560pt Messages window on a 3024px display is ~0.185 of the
        // display. Its 300-340pt bubbles are ~0.11 of the display -- below
        // bubbleMinWidth -- but ~0.6 of the window. Found live 2026-08-23:
        // every request from such a window classified as composing.
        let smallWindow = ScreenScene.NormalizedRect(x: 0.4, y: 0.2, width: 0.185, height: 0.5)
        let blocks = [
            block("Do you know what time the pharmacy closes?", x: 0.41, y: 0.25, width: 0.11, window: slack, windowFrame: smallWindow),
            block("I think it's 9, but let me double check.", x: 0.47, y: 0.35, width: 0.11, window: slack, windowFrame: smallWindow),
            block("Want me to swing by after work?", x: 0.41, y: 0.55, width: 0.10, window: slack, windowFrame: smallWindow),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 3)
        #expect(scene.conversationTurns.map(\.speaker) == [.other, .selfSpeaker, .other])
    }

    @Test("A full-window-wide block is not a bubble even when it is narrow on the display")
    func fullWindowWidthBlockIsNotABubble() {
        let smallWindow = ScreenScene.NormalizedRect(x: 0.4, y: 0.2, width: 0.185, height: 0.5)
        let blocks = [
            block("Thread title banner across the whole window", x: 0.4, y: 0.22, width: 0.18, window: slack, windowFrame: smallWindow),
            block("Another banner line across the window", x: 0.4, y: 0.42, width: 0.18, window: slack, windowFrame: smallWindow),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode != .replying)
    }

    @Test("Speaker remains unknown when the window frame is unavailable")
    func speakerFallsBackToOtherWithoutWindowFrame() {
        // Bypass the `block()` helper's "window implies fullscreen frame"
        // default -- this constructs bundle-ID attribution WITHOUT a frame,
        // which SCWindow metadata could in principle produce (or a future
        // caller could construct), and must not be treated as fullscreen.
        func blockNoFrame(_ text: String, x: Double, y: Double) -> ScreenScene.OCRBlock {
            ScreenScene.OCRBlock(
                text: text,
                boundingBox: ScreenScene.NormalizedRect(x: x, y: y, width: 0.35, height: 0.05),
                windowOwnerBundleID: slack,
                windowFrame: nil
            )
        }
        let blocks = [
            blockNoFrame("hey are you around today", x: 0.05, y: 0.30),
            blockNoFrame("yeah free after 3pm works", x: 0.55, y: 0.60),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.allSatisfy { $0.speaker == .unknown })
    }

    @Test("Blocks with no window attribution are excluded from the reply thread (unknown != frontmost)")
    func unattributedBlocksExcludedFromOwnWindow() {
        // Two unattributed blocks that would otherwise look exactly like a
        // message list (bubble widths, distinct bands) must NOT be folded
        // into the frontmost chat app's thread just because attribution
        // came back nil -- that's a fail-open path against drop-on-doubt.
        let blocks = [
            block("hey are you around today", x: 0.05, y: 0.30, window: nil),
            block("yeah free after 3pm works", x: 0.55, y: 0.60, window: nil),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .composing)
        #expect(scene.conversationTurns.isEmpty)
    }

    @Test("A bubble from a different window is excluded from the reply thread")
    func otherWindowBubbleExcludedFromReplyThread() {
        let blocks = [
            block("hey are you around today", x: 0.05, y: 0.30, window: slack),
            block("yeah free after 3pm works", x: 0.55, y: 0.60, window: slack),
            block("unrelated note from another app", x: 0.10, y: 0.45, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
        #expect(!scene.conversationTurns.contains { $0.text.contains("unrelated note") })
    }

    // MARK: - Replying: wrapped OCR lines vs genuinely separate turns

    /// Code review regression (P2, verify-then-fix): Vision's
    /// `VNRecognizeTextRequest` recognizes text line by line, so a real
    /// multi-line chat bubble arrives here as several adjacent `OCRBlock`s
    /// from the same speaker, not one. Left unmerged, a long three-line
    /// reply would look exactly like three short "terse" turns to
    /// `RawContinuationPrompt`'s terse-room clamp and wrongly shrink
    /// generation to a single short burst. Tightly stacked same-speaker
    /// blocks (small vertical gap relative to line height) must fold into
    /// one conversation turn.
    @Test("Tightly stacked same-speaker OCR lines merge into one wrapped-bubble turn")
    func wrappedBubbleLinesMergeIntoOneTurn() {
        let blocks = [
            block("I think we should probably wait until", x: 0.05, y: 0.30, window: slack),
            block("everyone gets back from the trip before", x: 0.05, y: 0.36, window: slack),
            block("we finalize the schedule for next quarter", x: 0.05, y: 0.42, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 1)
        #expect(scene.conversationTurns.first?.speaker == .other)
        #expect(
            scene.conversationTurns.first?.text
                == "I think we should probably wait until everyone gets back from the trip before we finalize the schedule for next quarter"
        )
    }

    /// The other half of the same fix: consecutive SHORT messages from the
    /// same speaker with ordinary bubble spacing -- the "up?" / "lol" /
    /// "u there" rapid-fire dogfood shape -- must stay as distinct turns.
    /// Merging on speaker alone (ignoring geometry) would wrongly collapse
    /// a genuinely terse room into one long-looking turn and defeat the
    /// clamp it exists to trigger.
    @Test("Separate same-speaker messages with ordinary spacing stay as distinct turns")
    func separateSameSpeakerMessagesStayDistinct() {
        let blocks = [
            block("up?", x: 0.05, y: 0.10, window: slack),
            block("lol", x: 0.05, y: 0.20, window: slack),
            block("u there", x: 0.05, y: 0.30, window: slack),
            block("??", x: 0.05, y: 0.40, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        // All four fit under maxTurns, and none of them got concatenated.
        #expect(scene.conversationTurns.count == 4)
        #expect(scene.conversationTurns.map(\.text) == ["up?", "lol", "u there", "??"])
    }

    // MARK: - Replying: caps

    @Test("At most maxTurns turns survive, keeping the most recent (bottom-most) ones")
    func capsAtMostRecentTurns() {
        let blocks = (1...10).map { index in
            block(
                "message number \(index)",
                x: index.isMultiple(of: 2) ? 0.55 : 0.05,
                y: 0.05 + Double(index) * 0.09,
                window: slack
            )
        }
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == ScreenScene.maxTurns)
        let texts = scene.conversationTurns.map(\.text)
        #expect(texts == (3...10).map { "message number \($0)" })
    }

    @Test("Turn text is capped to the shared character budget, freshest kept fullest")
    func turnsShareTheCharacterBudget() {
        let oldest = String(repeating: "a", count: 800)
        let middle = String(repeating: "b", count: 800)
        let newest = String(repeating: "c", count: 800)
        let blocks = [
            block(oldest, x: 0.05, y: 0.10, window: slack),
            block(middle, x: 0.55, y: 0.40, window: slack),
            block(newest, x: 0.05, y: 0.70, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        let totalChars = scene.conversationTurns.reduce(0) { $0 + $1.text.count }
        #expect(totalChars <= ScreenScene.maxTurnsCharacterBudget)
        // Newest turn is spent first and kept fully intact.
        #expect(scene.conversationTurns.last?.text == newest)
        #expect(scene.conversationTurns.last?.text.count == 800)
        // The 2,000 budget covers newest + middle in full and leaves 400
        // for the oldest, which is the one that gets truncated.
        #expect(scene.conversationTurns.map(\.text.count) == [400, 800, 800])
    }

    /// Live bug 2026-08-18: the merged block's own growing height was the
    /// gap reference, so after two wrapped lines joined, ordinary paragraph
    /// spacing passed the check and a paragraph-style conversation
    /// (Claude/ChatGPT-like, no bubbles, one speaker column) collapsed into
    /// a single mega-turn. The reference must be the LAST LINE's height.
    @Test("Paragraph-style messages stay distinct turns; only wrapped lines merge")
    func paragraphMessagesStayDistinctTurns() {
        let blocks = [
            block("first paragraph line one which wraps", x: 0.05, y: 0.10, window: slack),
            block("first paragraph line two", x: 0.05, y: 0.16, window: slack),
            block("first paragraph line three", x: 0.05, y: 0.22, window: slack),
            block("second paragraph line one after a gap", x: 0.05, y: 0.32, window: slack),
            block("second paragraph line two", x: 0.05, y: 0.38, window: slack),
            block("second paragraph line three", x: 0.05, y: 0.44, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
        #expect(scene.conversationTurns.first?.text.hasPrefix("first paragraph") == true)
        #expect(scene.conversationTurns.last?.text.hasPrefix("second paragraph") == true)
    }

    @Test("A newest turn over budget keeps its tail, not its head")
    func newestTurnOverBudgetKeepsItsTail() {
        let older = "short older message"
        let newest = String(repeating: "a", count: ScreenScene.maxTurnsCharacterBudget - 10) + " tail marker"
        let blocks = [
            block(older, x: 0.05, y: 0.10, window: slack),
            block(newest, x: 0.05, y: 0.70, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: "")
        let last = scene.conversationTurns.last?.text ?? ""
        #expect(last.count == ScreenScene.maxTurnsCharacterBudget)
        #expect(last.hasSuffix("tail marker"))
    }

    @Test("A bubble duplicating field text is excluded from the reply thread (dedupe)")
    func duplicateBubbleExcludedFromTurns() {
        let fieldText = "typing a reply about the schedule"
        let blocks = [
            block("about the schedule", x: 0.05, y: 0.30, window: slack), // substring of fieldText, deduped
            block("yeah free after 3pm works", x: 0.55, y: 0.60, window: slack),
            block("what time were you thinking", x: 0.05, y: 0.80, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: fieldText)
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
        #expect(!scene.conversationTurns.contains { $0.text == "about the schedule" })
    }

    @Test("Short bubble text is exempt from dedupe so trivial matches don't vanish")
    func shortBubbleTextExemptFromDedupe() {
        // "ok" would "match" almost any field text if containment applied unconditionally.
        let fieldText = "ok, sounds good, talk soon"
        let blocks = [
            block("ok", x: 0.05, y: 0.30, window: slack),
            block("sounds good, talk soon then", x: 0.55, y: 0.60, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: fieldText)
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.contains { $0.text == "ok" })
    }

    @Test("Dedupe is case-insensitive")
    func dedupeIsCaseInsensitive() {
        let fieldText = "typing a reply about the schedule"
        let blocks = [
            block("About The Schedule", x: 0.05, y: 0.30, window: slack), // differs only by case
            block("yeah free after 3pm works", x: 0.55, y: 0.60, window: slack),
            block("what time were you thinking", x: 0.05, y: 0.80, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: fieldText)
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 2)
        #expect(!scene.conversationTurns.contains { $0.text == "About The Schedule" })
    }

    @Test("Dedupe also excludes a bubble that fully contains the (shorter) field text")
    func dedupeCatchesReverseContainment() {
        // The field text is a short in-progress fragment that's fully
        // contained inside a longer bubble already on screen -- the old
        // one-directional check (candidate substring of field) missed this.
        let fieldText = "talk to you at 3pm"
        let blocks = [
            block("yeah, sounds good, talk to you at 3pm then", x: 0.05, y: 0.30, window: slack),
            block("what time were you thinking", x: 0.55, y: 0.60, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: fieldText)
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 1)
        #expect(scene.conversationTurns.first?.text == "what time were you thinking")
    }

    @Test("Dedupe tolerates whitespace/line-wrap differences between OCR and field text")
    func dedupeToleratesWrapping() {
        let fieldText = "typing a reply about\nthe schedule"
        let blocks = [
            block("about   the schedule", x: 0.05, y: 0.30, window: slack), // extra spaces, no newline
            block("yeah free after 3pm works", x: 0.55, y: 0.60, window: slack),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: slack, fieldText: fieldText)
        #expect(scene.mode == .replying)
        #expect(scene.conversationTurns.count == 1)
        #expect(!scene.conversationTurns.contains { $0.text == "about   the schedule" })
    }

    // MARK: - Referencing

    @Test("Text in a non-frontmost window sharing a rare word with the current sentence is a reference")
    func crossWindowSharedRareWordIsReferencing() {
        let fieldText = "Thanks for sending that over. Let me check the invoice number for acme corp"
        let blocks = [
            block("Invoice #48213 — Acme Corp — due Friday", x: 0.60, y: 0.20, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .referencing)
        #expect(scene.referenceSnippets == ["Invoice #48213 — Acme Corp — due Friday"])
        #expect(scene.conversationTurns.isEmpty)
    }

    @Test("Among multiple qualifying blocks, the largest by character count is chosen")
    func referencingPicksLargestQualifyingBlock() {
        let fieldText = "checking the invoice details now"
        let blocks = [
            block("invoice #1", x: 0.60, y: 0.20, window: notes),
            block("Invoice #48213 for the Acme Corp account, due Friday next week", x: 0.60, y: 0.40, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .referencing)
        #expect(scene.referenceSnippets == ["Invoice #48213 for the Acme Corp account, due Friday next week"])
    }

    @Test("A block from the frontmost window is never treated as a reference")
    func frontmostWindowBlockExcludedFromReferencing() {
        let fieldText = "checking the invoice details now"
        let blocks = [
            block("Invoice #48213 for Acme Corp, due Friday", x: 0.60, y: 0.20, window: textEdit),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .composing)
    }

    @Test("A block with no window attribution is never treated as a reference")
    func unattributedBlockExcludedFromReferencing() {
        let fieldText = "checking the invoice details now"
        let blocks = [
            block("Invoice #48213 for Acme Corp, due Friday", x: 0.60, y: 0.20, window: nil),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .composing)
    }

    @Test("A block sharing no rare word with the current sentence is not a reference")
    func unrelatedBlockIsNotAReference() {
        let fieldText = "checking the weather forecast for tomorrow"
        let blocks = [
            block("Invoice #48213 for Acme Corp, due Friday", x: 0.60, y: 0.20, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .composing)
    }

    @Test("A block already visible in the field text is deduped out of referencing")
    func referenceBlockDuplicatingFieldTextIsDeduped() {
        let fieldText = "as discussed, the invoice number for acme corp is 48213"
        let blocks = [
            block("the invoice number for acme corp is 48213", x: 0.60, y: 0.20, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .composing)
    }

    @Test("Reference snippet is capped at the reference character budget")
    func referenceSnippetCappedAt400Characters() {
        let fieldText = "checking the invoice details now"
        let longText = "Invoice details: " + String(repeating: "x", count: 1_500)
        let blocks = [block(longText, x: 0.60, y: 0.20, window: notes)]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .referencing)
        #expect(scene.referenceSnippets.first?.count == ScreenScene.maxReferenceCharacters)
        #expect(longText.hasPrefix(scene.referenceSnippets.first!))
    }

    @Test("Empty field text has no current sentence, so referencing never fires")
    func emptyFieldTextNeverReferences() {
        let blocks = [
            block("Invoice #48213 for Acme Corp, due Friday", x: 0.60, y: 0.20, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: "")
        #expect(scene.mode == .composing)
    }

    @Test("Only stopwords in the current sentence never yields a reference")
    func stopwordOnlySentenceNeverReferences() {
        let fieldText = "well then that would be with them"
        let blocks = [
            block("Invoice #48213 for Acme Corp, due Friday", x: 0.60, y: 0.20, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .composing)
    }

    @Test("Only the sentence currently being typed is matched, not earlier finished sentences")
    func onlyCurrentSentenceIsMatchedAgainst() {
        // "invoice" only appears in the finished first sentence, not the one in progress.
        let fieldText = "The invoice looks correct. Now let's talk about tomorrow's weather"
        let blocks = [
            block("Invoice #48213 for Acme Corp, due Friday", x: 0.60, y: 0.20, window: notes),
        ]
        let scene = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(scene.mode == .composing)
    }

    // MARK: - Determinism

    @Test("Classifying the same snapshot twice yields identical scenes")
    func classificationIsDeterministic() {
        let fieldText = "checking the invoice details now"
        let blocks = [
            block("invoice #1", x: 0.60, y: 0.20, window: notes),
            block("Invoice #48213 for the Acme Corp account, due Friday next week", x: 0.60, y: 0.40, window: notes),
            block("hey are you around today", x: 0.05, y: 0.30, window: slack),
        ]
        let first = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        let second = ScreenScene.classify(blocks: blocks, frontmostBundleID: textEdit, fieldText: fieldText)
        #expect(first == second)
    }
}

@Suite("Scene window title")
struct ScreenSceneWindowTitleTests {
    private func titled(_ title: String?) -> ScreenScene.OCRBlock {
        block("hello there", x: 0.1, y: 0.1, window: "com.example.chat", title: title)
    }

    @Test("The most common non-empty title wins, deterministically")
    func dominantTitle() {
        #expect(ScreenScene.dominantWindowTitle(of: []) == nil)
        #expect(ScreenScene.dominantWindowTitle(of: [titled(nil), titled("  ")]) == nil)
        #expect(ScreenScene.dominantWindowTitle(of: [titled("A"), titled("B"), titled("B")]) == "B")
        #expect(ScreenScene.dominantWindowTitle(of: [titled("B"), titled("A")]) == "A")
    }

    @Test("A scene built without a title keeps nil, so existing callers are unchanged")
    func defaultIsNil() {
        let scene = ScreenScene.Scene(mode: .replying, conversationTurns: [], referenceSnippets: [])
        #expect(scene.windowTitle == nil)
    }
}
