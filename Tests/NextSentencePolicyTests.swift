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
assertEqual(NextSentencePolicy.wordsKept(before: 10, in: "Yes, Nov 3 still on"), 3, "the end snaps to the words before the pointer")
        assertEqual(NextSentencePolicy.wordsKept(before: 0, in: "Yes, Nov 3 still on"), 1, "one word always stays")
        assertEqual(NextSentencePolicy.trimWords("Yes, Nov 3 still, beta goes out first.", dropping: 4), "Yes, Nov 3 still",
                    "cut at a word, with no dangling comma")
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
        let full = NextSentencePrompt.variationsPrompt(request, base: "Nov 3.", tone: .direct, length: 2)
        assertTrue(streamed.contains("[S1] meeting 2026-10-14 Sync: ship on the 3rd"), "sources are listed with their ids")
        assertTrue(streamed.contains("screenshot of the window"), "the screenshot is explained when there is one")
        assertFalse(streamed.contains("Output JSON only"), "the streamed version is plain text")
        assertTrue(full.contains("Output JSON only") && full.contains("\"facts\""), "the full version asks for marked facts")
    }

    runSuite("The one reply comes back in every tone and length") {
        let lengths = ["Yes.", "Yes, Nov 3.", "Yes, Nov 3 still.", "Yes, Nov 3 still. Beta first.", "Yes, Nov 3 still. Beta goes out first."]
        let object: [String: Any] = ["casual": lengths, "direct": lengths, "warm": lengths, "facts": [["phrase": "Nov 3", "source": "S1"]]]
        let reply = NextSentencePrompt.parseVariations(object)
        assertEqual(reply?.text(tone: .warm, length: 4), "Yes, Nov 3 still. Beta goes out first.", "all five lengths are there, Tiny to Full")
        assertEqual(reply?.facts.first?.phrase, "Nov 3", "facts come along")
        var short = object
        short["warm"] = ["Yes."]
        assertTrue(NextSentencePrompt.parseVariations(short) == nil, "a tone missing lengths is rejected, not half-shown")
        let request = NextSentencePrompt.Request(appName: "Messages", windowTitle: "Riley", screenText: "launch?", draft: "",
                                                 hasScreenshot: false, sources: [], voiceExamples: [])
        let prompt = NextSentencePrompt.variationsPrompt(request, base: "Yes, still Nov 3.", tone: .casual, length: 2)
        assertTrue(prompt.contains("Yes, still Nov 3.") && prompt.contains("\"casual\" medium version is the reply above"),
                   "the variations are built from the exact reply shown")
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
        assertTrue(NextSentencePrompt.alternativesPrompt(text: "we pushed it a week", selection: "pushed it a week").contains("3 rephrasings"),
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

    runSuite("Captures split into passages, and context found by meaning comes first") {
        let day = """
        ---
        title: "Dictations for October 2, 2026"
        date: 2026-10-02
        ---

        # Dictations for October 2, 2026

        ## 9:10 AM - Launch thoughts

        Entry ID: `dictation-1`
        Source app: Notes
        Words: 14

        We should slide the launch to November third so the audio fixes get another week.

        ## 9:12 AM - g i t

        g
        i
        t
        """
        let passages = NextSentenceChunker.chunks(markdown: day, kind: "dictation")
        assertEqual(passages.count, 1, "keystroke noise is skipped")
        assertEqual(passages.first?.text, "We should slide the launch to November third so the audio fixes get another week.",
                    "bookkeeping lines are dropped")
        assertTrue(passages.first?.date == "2026-10-02" && passages.first?.title == "9:10 AM", "date and time come along")

        let meeting = """
        ---
        title: "Launch sync"
        date: 2026-10-01
        ---

        ## Transcript

        **00:00**  [System/Riley]
        Marketing needs the launch date by Friday so they can book the posts.

        **00:09**  [Mic/You]
        Then let's lock November third at Tuesday's sync.
        """
        let turns = NextSentenceChunker.chunks(markdown: meeting, kind: "meeting")
        assertEqual(turns.count, 1, "short meetings stay one passage")
        assertTrue(turns.first?.text.hasPrefix("Riley: Marketing needs") == true && turns.first?.text.contains("You: Then") == true,
                   "turns read as speaker: words")
        assertEqual(NextSentenceChunker.split(String(repeating: "word ", count: 400)).count, 3, "long text splits between words")

        let merged = NextSentencePrompt.mergeSources(
            meaning: [.init(kind: "meeting", date: "2026-10-01", title: "Launch sync", text: "Marketing needs the launch date by Friday.")],
            keywords: [.init(id: "S1", kind: "dictation", date: "2026-10-02", title: "", quote: "We should slide the launch.")])
        assertEqual(merged.map(\.id), ["S1", "S2"], "renumbered in order")
        assertEqual(merged.first?.kind, "meeting", "the passage found by meaning comes first")
    }

    runSuite("Words from their history are tinted; words from the screen are not") {
        let sources = [NextSentencePrompt.Source(id: "S1", kind: "meeting", date: "", title: "", quote: "we moved launch to November third for the audio fixes")]
        let text = "Yes, launch is November third, after the audio fixes."
        let marks = NextSentencePrompt.historyRanges(in: text, sources: sources, screen: "when is the launch?")
        let phrases = marks.map { (text as NSString).substring(with: $0.range) }
        assertTrue(phrases.contains("November third"), "adjacent history words join into one phrase")
        assertTrue(phrases.contains("audio fixes"), "every phrase from the source is found")
        assertFalse(phrases.contains { $0.contains("launch") }, "a word that's on screen isn't credited to history")
    }

    runSuite("Only a quick tap of fn on its own opens the card") {
        assertTrue(NextSentencePolicy.isFnTap(heldFor: 0.12, withOtherKey: false), "a quick tap counts")
        assertFalse(NextSentencePolicy.isFnTap(heldFor: 0.12, withOtherKey: true), "fn with another key is a shortcut, not a tap")
        assertFalse(NextSentencePolicy.isFnTap(heldFor: 0.9, withOtherKey: false), "holding fn down isn't a tap")
    }

    runSuite("The people in a conversation are found from the title, speaker labels and repeated names") {
        let people = NextSentencePrompt.people(screen: "Riley Park: are we still on for launch?\nme: I think so\nRiley Park: ok tell Dana too",
                                               windowTitle: "Riley Park")
        assertEqual(people.first, "Riley", "the window title and speaker labels name the person, by first name")
        assertFalse(people.contains("Park"), "last names aren't searched on their own")
        assertFalse(people.contains("I"), "pronouns aren't people")
        assertTrue(NextSentencePrompt.people(screen: "Monday works. Thanks!", windowTitle: "Messages").isEmpty, "days and app names aren't people")
        let merged = NextSentencePrompt.mergeSources(
            meaning: [], people: [("Riley", .init(kind: "meeting", date: "2026-10-01", title: "1:1", text: "Riley owns the launch checklist."))],
            keywords: [])
        assertEqual(merged.first?.about, "Riley", "a passage found for a person says who it's about")
        let request = NextSentencePrompt.Request(appName: "Messages", windowTitle: "Riley Park", screenText: "", draft: "",
                                                 hasScreenshot: false, sources: merged, voiceExamples: [], people: ["Riley"])
        assertTrue(NextSentencePrompt.body(request, json: false).contains("PEOPLE IN THIS CONVERSATION: Riley"), "the writer is told who's involved")
    }

    runSuite("A new version glides the words it shares, in order, and marks the rest as new") {
        let new = "Yes! Still on for Nov 3."
        let pairs = NextSentencePolicy.matchedWords(from: "Yes, still Nov 3.", to: new)
        let shared = pairs.map { (new as NSString).substring(with: $0.new) }
        assertEqual(shared, ["Yes", "Still", "Nov", "3"], "shared words match regardless of case or punctuation")
        let fresh = NextSentencePolicy.wordRanges(in: new).filter { range in !pairs.contains { $0.new == range } }
        assertEqual(fresh.map { (new as NSString).substring(with: $0) }, ["on", "for"], "only the new words are new")
        assertEqual(NextSentencePolicy.matchedWords(from: "a b c", to: "c b a").count, 1, "words that swapped order don't all glide")
        assertTrue(NextSentencePolicy.matchedWords(from: "", to: "Hello there").isEmpty, "nothing to glide from an empty card")
    }

    runSuite("Stretching the card keeps whole sentences") {
        let text = "Thanks for the call. Can you send it by Thursday? That way we ship next week!  "
        let ends = NextSentencePolicy.sentenceEnds(in: text)
        assertEqual(ends.map { (text as NSString).substring(to: $0) },
                    ["Thanks for the call.", "Thanks for the call. Can you send it by Thursday?",
                     "Thanks for the call. Can you send it by Thursday? That way we ship next week!"],
                    "each end is just after a sentence's punctuation, without trailing spaces")
        assertEqual(NextSentencePolicy.sentenceEnds(in: "no punctuation here").count, 1, "an unpunctuated message is one sentence")
        assertTrue(NextSentencePolicy.sentenceEnds(in: "").isEmpty, "an empty message has no sentences")
    }

    runSuite("Holding fn and speaking tells it what the message should say") {
        let request = NextSentencePrompt.Request(appName: "Messages", windowTitle: "Riley", screenText: "launch date?", draft: "",
                                                 hasScreenshot: false, sources: [], voiceExamples: [], intent: "say yes but the beta goes first")
        let body = NextSentencePrompt.body(request, json: false)
        assertTrue(body.contains("WHAT THEY WANT THIS MESSAGE TO SAY") && body.contains("say yes but the beta goes first"),
                   "what they said goes to the writer, marked as what the message should say")
        let plain = NextSentencePrompt.Request(appName: "Messages", windowTitle: "Riley", screenText: "launch date?", draft: "",
                                               hasScreenshot: false, sources: [], voiceExamples: [])
        assertFalse(NextSentencePrompt.body(plain, json: false).contains("WHAT THEY WANT"), "a quick tap writes without it")
        assertTrue(NextSentencePolicy.isFnTap(heldFor: 0.39, withOtherKey: false), "under the limit is a tap")
        assertFalse(NextSentencePolicy.isFnTap(heldFor: 0.41, withOtherKey: false), "past it is a hold, not a tap")
    }
}
