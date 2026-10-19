import CoreGraphics
import Foundation

func testNextSentencePolicy() {
    let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let card = CGSize(width: 460, height: 90)

    runSuite("Next Sentence opens just below the line being typed, lined up with the cursor") {
        let caret = CGRect(x: 300, y: 500, width: 2, height: 18)
        let placement = NextSentencePolicy.place(card: card, under: caret, in: visible)
        assertFalse(placement.above, "there's room below, so it goes below")
        assertEqual(placement.origin.y, 500 - 90 - 6, "the card's top sits just under the line")
        assertEqual(placement.origin.x, 286, "the card lines up a little left of the cursor")
    }

    runSuite("Next Sentence flips above the line when there's no room below, so it never covers the text") {
        let caret = CGRect(x: 300, y: 40, width: 2, height: 18)
        let placement = NextSentencePolicy.place(card: card, under: caret, in: visible)
        assertTrue(placement.above, "near the bottom of the screen it goes above")
        assertEqual(placement.origin.y, 58 + 6, "the card's bottom sits just over the line")
    }

    runSuite("Next Sentence stays on screen near the right edge") {
        let caret = CGRect(x: 1_400, y: 500, width: 2, height: 18)
        let placement = NextSentencePolicy.place(card: card, under: caret, in: visible)
        assertEqual(placement.origin.x, 1_440 - 460 - 4, "the card is pulled back inside the screen")
    }

    runSuite("Accessibility rects convert to Cocoa screen coordinates") {
        let ax = CGRect(x: 100, y: 200, width: 2, height: 20)
        assertEqual(NextSentencePolicy.cocoaRect(fromAccessibility: ax, primaryScreenMaxY: 900),
                    CGRect(x: 100, y: 680, width: 2, height: 20), "y flips around the primary screen")
    }

    runSuite("While the card is open, its keys are caught and shortcuts go back to the app") {
        func action(_ code: Int64, shift: Bool = false, command: Bool = false) -> NextSentencePolicy.KeyAction {
            NextSentencePolicy.action(keyCode: code, command: command, control: false, option: false, shift: shift)
        }
        assertEqual(action(NextSentencePolicy.KeyCode.tab), .nextReply, "Tab shows another reply")
        assertEqual(action(NextSentencePolicy.KeyCode.tab, shift: true), .previousReply, "Shift-Tab goes back a reply")
        assertEqual(action(NextSentencePolicy.KeyCode.up), .shorter, "↑ makes it shorter, like the pad")
        assertEqual(action(NextSentencePolicy.KeyCode.down), .longer, "↓ makes it longer")
        assertEqual(action(NextSentencePolicy.KeyCode.left), .moreDirect, "← is more direct, the pad's left")
        assertEqual(action(NextSentencePolicy.KeyCode.right), .warmer, "→ is warmer")
        assertEqual(action(NextSentencePolicy.KeyCode.slash), .edit, "/ starts editing the text")
        assertEqual(action(NextSentencePolicy.KeyCode.returnKey), .returnDown, "Return down starts insert-or-send")
        assertEqual(NextSentencePolicy.action(keyCode: NextSentencePolicy.KeyCode.returnKey, command: false, control: false,
                                              option: false, shift: false, isRepeat: true), .ignore,
                    "a held Return's repeats are swallowed, never typed into the app")
        assertEqual(NextSentencePolicy.releaseAction(keyCode: NextSentencePolicy.KeyCode.returnKey), .returnUp, "letting go of Return decides")
        assertEqual(NextSentencePolicy.releaseAction(keyCode: 0), .passThrough, "other key-ups pass through")
        assertEqual(action(NextSentencePolicy.KeyCode.escape), .close, "Esc closes")
        assertEqual(action(0), .typeIntoCard, "typing a letter starts editing the card's text")
        assertEqual(action(NextSentencePolicy.KeyCode.returnKey, command: true), .passThrough, "shortcuts are left alone")
        assertTrue(NextSentencePolicy.consumes(.returnDown) && NextSentencePolicy.consumes(.ignore), "the app never sees the Return that inserts")
        assertTrue(NextSentencePolicy.consumes(.typeIntoCard), "typed letters go into the card, not the app behind it")
        assertFalse(NextSentencePolicy.consumes(.passThrough), "shortcuts still reach the app")
    }

    runSuite("Holding fills a ring; the pad and the end handle step through tone and length") {
        assertEqual(NextSentencePolicy.holdProgress(heldFor: 0.35, needed: 0.7), 0.5, "the ring fills with the hold")
        assertEqual(NextSentencePolicy.holdProgress(heldFor: 2, needed: 0.7), 1, "and stops full")
        assertEqual(NextSentencePolicy.stepTone(2, by: 1), 2, "tone stops at warm instead of wrapping")
        assertEqual(NextSentencePolicy.stepLength(0, by: -1), 0, "length stops at Tiny")
        let pad = CGSize(width: 58, height: 38)
        let cell = NextSentencePolicy.padCell(at: CGPoint(x: 1, y: 1), size: pad)
        assertTrue(cell.tone == 0 && cell.length == 0, "the pad's top left is direct and tiny")
        let corner = NextSentencePolicy.padCell(at: CGPoint(x: 99, y: 99), size: pad)
        assertTrue(corner.tone == 2 && corner.length == 4, "dragging past the bottom right is warm and full")
        let center = NextSentencePolicy.padCenter(tone: 1, length: 2, size: pad)
        let back = NextSentencePolicy.padCell(at: center, size: pad)
        assertTrue(back.tone == 1 && back.length == 2, "the dot rests in the middle of its cell")
        assertEqual(NextSentencePolicy.gripLength(base: 2, dragged: 31).length, 3, "30pt right is one length longer")
        assertEqual(NextSentencePolicy.gripLength(base: 2, dragged: -65).length, 0, "two steps left is Tiny")
        let past = NextSentencePolicy.gripLength(base: 4, dragged: 40)
        assertTrue(past.length == 4 && past.wanted == 5, "dragging past Full stays Full but knows they wanted more")
    }

    runSuite("Next Sentence searches for the distinctive words, newest first, without filler") {
        let terms = NextSentencePrompt.searchTerms(in: "hey, are we still on for the launch? marketing wants the date for Transcripted")
        assertTrue(terms.contains("transcripted"), "names in the newest message are searched")
        assertTrue(terms.contains("marketing"), "content words are searched")
        assertFalse(terms.contains("still") || terms.contains("wants") || terms.contains("hey"), "filler words are not")
        assertTrue(terms.count <= 5, "at most five searches")
    }

    runSuite("The prompt only asks for marked facts when it wants JSON back") {
        let request = NextSentencePrompt.Request(appName: "Slack", windowTitle: "#product", screenText: "when do we ship?",
                                                 draft: "", hasScreenshot: true,
                                                 sources: [.init(id: "S1", kind: "meeting", date: "2026-10-14", title: "Sync", quote: "ship on the 3rd")],
                                                 voiceExamples: ["yeah let's ship it"])
        let streamed = NextSentencePrompt.streamPrompt(request, tone: .direct)
        let full = NextSentencePrompt.fullPrompt(request)
        assertTrue(streamed.contains("[S1] meeting 2026-10-14 Sync: ship on the 3rd"), "sources are listed with their ids")
        assertTrue(streamed.contains("screenshot of the window"), "the screenshot is explained when there is one")
        assertFalse(streamed.contains("Output JSON only"), "the streamed version is plain text")
        assertTrue(full.contains("Output JSON only") && full.contains("\"facts\""), "the full version asks for marked facts")
    }

    runSuite("Three guesses parse with every tone and length, and the quick pass fills one tone") {
        let lengths = ["Yes.", "Yes, Nov 3.", "Yes, Nov 3 still.", "Yes, Nov 3 still. Beta first.", "Yes, Nov 3 still. Beta goes out first."]
        let item: [String: Any] = ["label": "Confirm", "casual": lengths, "direct": lengths, "warm": lengths,
                                   "facts": [["phrase": "Nov 3", "source": "S1"]]]
        let full = NextSentencePrompt.parseFull(["guesses": [item, item, item]])
        assertEqual(full?.count, 3, "three guesses")
        assertEqual(full?.first?.text(tone: .warm, length: 4), "Yes, Nov 3 still. Beta goes out first.", "all five lengths are there, Tiny to Full")
        assertTrue(NextSentencePrompt.parseFull(["guesses": [item]]) == nil, "fewer than three guesses is rejected, not half-shown")

        let quick = NextSentencePrompt.parseGuesses(["guesses": [
            ["label": "Confirm", "text": "Yes, Nov 3.", "facts": []],
            ["label": "Push back", "text": "Not yet.", "facts": []],
            ["label": "Ask", "text": "Which date?", "facts": []],
        ]], tone: .direct)
        assertEqual(quick?[1].text(tone: .direct, length: NextSentencePrompt.mediumLength), "Not yet.", "the quick pass fills the current tone's medium")
        assertTrue(quick?[1].text(tone: .warm, length: NextSentencePrompt.mediumLength) == nil, "other tones wait for the full pass")
    }

    runSuite("Facts are underlined where their words appear in the reply") {
        let ranges = NextSentencePrompt.factRanges(in: "Yes, still Nov 3 for launch.",
                                                    facts: [.init(phrase: "nov 3", source: "S1"), .init(phrase: "Friday", source: "S2")])
        assertEqual(ranges.count, 1, "only phrases that appear are marked")
        assertEqual(ranges.first?.range, NSRange(location: 11, length: 5), "matched without caring about case")
        assertEqual(ranges.first?.source, "S1", "the mark remembers where it came from")
    }

    runSuite("A single word asks for replacements, a phrase asks for rephrasings") {
        assertTrue(NextSentencePrompt.alternativesPrompt(text: "we pushed it a week", selection: "pushed").contains("replacements for the word"),
                   "one word gets word swaps")
        assertTrue(NextSentencePrompt.alternativesPrompt(text: "we pushed it a week", selection: "pushed it a week").contains("rephrasings"),
                   "several words get rephrased")
        assertEqual(NextSentencePrompt.parseOptions(["options": [" moved ", "", "slid"]]), ["moved", "slid"], "blank options are dropped")
    }

    runSuite("Word swaps arrive in one pass, and a rewrite keeps their voice") {
        let swaps = NextSentencePrompt.parseSwaps(["swaps": [
            ["word": "Pushed", "options": ["moved", "pushed", " slid "]],
            ["word": "two words", "options": ["x"]],
            ["word": "week", "options": []],
        ]])
        assertEqual(swaps["pushed"], ["moved", "slid"], "keyed by the lowercased word, without the word itself")
        assertTrue(swaps["two words"] == nil && swaps["week"] == nil, "phrases and words with no options are dropped")
        let request = NextSentencePrompt.Request(appName: "Messages", windowTitle: "Sam", screenText: "launch date?", draft: "",
                                                 hasScreenshot: false, sources: [], voiceExamples: [])
        let fresh = NextSentencePrompt.rewritePrompt(request, current: "Nov 3.", instruction: "")
        assertTrue(fresh.contains("fresh take") && fresh.contains("Nov 3."), "no instruction asks for a fresh take of the card's message")
        let spoken = NextSentencePrompt.rewritePrompt(request, current: "Nov 3.", instruction: "mention the beta")
        assertTrue(spoken.contains("mention the beta") && spoken.contains("like they wrote it"), "a spoken change is worked in, in their voice")
    }
}
