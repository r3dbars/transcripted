import Foundation

/// Exercises only the actual action coordinator with memory closures. No
/// island, app delegate, preferences, capture library or clipboard is opened.
@MainActor
func testRecentDictationPasteAction() {
    runSuite("Paste again captures the visible take before dismissal can replace its state") {
        var visible: String? = "Visible take A"
        var newestSaved = "Newer saved take B"
        var reads = 0
        var dismissals = 0
        var delivered: [String] = []
        var trace: [String] = []
        let accepted = RecentDictationPasteAction.request(visibleText: {
            reads += 1
            trace.append("read")
            return visible
        }, dismiss: {
            trace.append("dismiss")
            dismissals += 1
            visible = nil
            newestSaved = "Still newer saved take C"
        }, deliver: {
            trace.append("deliver")
            delivered.append($0)
        })
        assertTrue(accepted)
        assertEqual(reads, 1)
        assertEqual(dismissals, 1)
        assertEqual(delivered, ["Visible take A"])
        assertEqual(trace, ["read", "dismiss", "deliver"])
        assertNil(visible)
        assertEqual(newestSaved, "Still newer saved take C")
    }

    runSuite("An absent or empty visible take neither dismisses nor falls back to another entry") {
        let unavailable: [String?] = [nil, ""]
        for text in unavailable {
            var reads = 0
            var dismissals = 0
            var delivered: [String] = []
            var trace: [String] = []
            let accepted = RecentDictationPasteAction.request(visibleText: {
                reads += 1
                trace.append("read")
                return text
            }, dismiss: {
                dismissals += 1
                trace.append("dismiss")
            }, deliver: {
                delivered.append($0)
                trace.append("deliver")
            })
            assertFalse(accepted)
            assertEqual(reads, 1)
            assertEqual(dismissals, 0)
            assertEqual(delivered, [])
            assertEqual(trace, ["read"])
        }
    }

    runSuite("The visible payload keeps its whitespace Unicode and line breaks exactly") {
        for text in ["  ", "first\nsecond", "\tCafé 👩🏽‍💻\r\n"] {
            var reads = 0
            var received: [String] = []
            var trace: [String] = []
            let accepted = RecentDictationPasteAction.request(visibleText: {
                reads += 1
                return text
            }, dismiss: { trace.append("dismiss") }, deliver: {
                trace.append("deliver")
                received.append($0)
            })
            assertTrue(accepted)
            assertEqual(received, [text])
            assertEqual(trace, ["dismiss", "deliver"])
            assertEqual(reads, 1)
        }
    }
}
