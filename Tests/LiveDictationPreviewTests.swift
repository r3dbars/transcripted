import Foundation

func testLiveDictationPreview() {
    runSuite("LiveDictationPreview joins finished utterances and clears the words in progress") {
        var preview = LiveDictationPreview()
        assertTrue(preview.isEmpty)
        preview.tentative = "hey can you"
        preview.commit("hey can you send me the deck")
        assertEqual(preview.settled, "hey can you send me the deck")
        assertEqual(preview.tentative, "", "a finished utterance replaces what was still being heard")
        preview.commit("  before the sync ")
        assertEqual(preview.settled, "hey can you send me the deck before the sync", "utterances join with one space")
        preview.commit("   ")
        assertEqual(preview.settled, "hey can you send me the deck before the sync", "an empty utterance adds nothing")
    }

    runSuite("LiveDictationPreview dims only the last words still being heard") {
        var preview = LiveDictationPreview()
        preview.settled = "send me the deck"
        preview.tentative = "from tuesday before the"
        let parts = preview.split(dimmingLast: 2)
        assertEqual(parts.settled, "send me the deck from tuesday", "the steady start of the partial reads as settled")
        assertEqual(parts.tentative, "before the")

        let released = preview.split(dimmingLast: 0)
        assertEqual(released.settled, "send me the deck from tuesday before the", "once released nothing is dimmed")
        assertEqual(released.tentative, "")

        preview.settled = ""
        preview.tentative = "hey"
        let short = preview.split(dimmingLast: 2)
        assertEqual(short.settled, "")
        assertEqual(short.tentative, "hey", "a partial shorter than the dimmed count is all dimmed")
    }
}
