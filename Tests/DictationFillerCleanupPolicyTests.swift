import Foundation

func testDictationFillerCleanupPolicy() {
    runSuite("DictationFillerCleanupPolicy removes clear spoken fillers") {
        let cleaned = DictationFillerCleanupPolicy.clean("Um, okay, I I think we should ship this uh today")

        assertEqual(
            cleaned.text,
            "I think we should ship this today.",
            "cleanup should remove fillers, trim a leading opener, collapse duplicates, and add final punctuation"
        )
        assertTrue(cleaned.changed, "cleanup should report that it changed the text")
        assertEqual(cleaned.removedCount, 4, "cleanup should count removed fillers/openers/duplicates")
    }

    runSuite("DictationFillerCleanupPolicy preserves already clean text") {
        let cleaned = DictationFillerCleanupPolicy.clean("I think we should ship this today.")

        assertEqual(cleaned.text, "I think we should ship this today.", "clean text should pass through")
        assertFalse(cleaned.changed, "unchanged text should not report cleanup")
        assertEqual(cleaned.removedCount, 0, "unchanged text should not report removed items")
    }

    runSuite("DictationFillerCleanupPolicy keeps short opener-only notes") {
        let cleaned = DictationFillerCleanupPolicy.clean("Okay good")

        assertEqual(cleaned.text, "Okay good", "short notes should not lose meaningful openers")
        assertFalse(cleaned.changed, "short opener-only notes should not report cleanup")
    }

    runSuite("DictationFillerCleanupPolicy avoids URLs and code-ish punctuation") {
        let cleaned = DictationFillerCleanupPolicy.clean("open https://transcripted.app/download um now")

        assertEqual(
            cleaned.text,
            "open https://transcripted.app/download now",
            "cleanup may remove clear filler but should not add sentence punctuation to URLs"
        )
    }

    runSuite("DictationFillerCleanupPolicy preserves filler-looking URL and path segments") {
        let url = DictationFillerCleanupPolicy.clean("open https://example.com/er now")
        let filePath = DictationFillerCleanupPolicy.clean("save this under /tmp/um-notes today")

        assertEqual(url.text, "open https://example.com/er now", "URL path segment should not be removed")
        assertEqual(filePath.text, "save this under /tmp/um-notes today", "file path segment should not be removed")
    }

    runSuite("DictationFillerCleanupPolicy does not collapse emphasized punctuation") {
        let cleaned = DictationFillerCleanupPolicy.clean("This is very, very important.")

        assertEqual(cleaned.text, "This is very, very important.", "comma-separated emphasis should survive")
        assertFalse(cleaned.changed, "emphasis should not count as cleanup")
    }

    runSuite("DictationFillerCleanupPolicy can reduce filler-only dictation to empty") {
        let cleaned = DictationFillerCleanupPolicy.clean("um uh ah")

        assertEqual(cleaned.text, "", "filler-only dictation should become empty so existing no-speech handling can run")
        assertEqual(cleaned.removedCount, 3, "all clear fillers should be counted")
    }
}
