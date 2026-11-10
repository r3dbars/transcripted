import Foundation

func testNextSentenceTypingPolicy() {
    runSuite("Non-text keys cannot start editing or insert function-key glyphs") {
        let nonText: [(Int64, String)] = [
            (117, "\u{F728}"), (115, "\u{F729}"), (119, "\u{F72B}"),
            (116, "\u{F72C}"), (121, "\u{F72D}"), (122, "\u{F704}"),
            (0, ""), (0, "\u{0}"), (0, "\u{7F}"), (0, "\u{85}"),
            (0, "\u{F700}"), (0, "\u{F8FF}"), (0, "a\u{F728}")
        ]
        for (code, text) in nonText {
            let action = NextSentencePolicy.typingAction(text: text, keyCode: code)
            assertEqual(action, .ignore, "non-text payloads leave card text untouched")
            assertTrue(NextSentencePolicy.consumes(action), "the key must not edit the app behind the card")
        }
    }

    runSuite("Ordinary Unicode typing and Backspace still enter card editing") {
        for text in ["a", "A", " ", "é", "e\u{301}", "你好", "👩‍💻", "\u{E000}", "\u{F6FF}", "\u{F900}"] {
            assertEqual(NextSentencePolicy.typingAction(text: text, keyCode: 0), .typeIntoCard)
        }
        for text in ["", "\u{7F}"] {
            assertEqual(NextSentencePolicy.typingAction(text: text, keyCode: NextSentencePolicy.KeyCode.delete), .typeIntoCard,
                        "Backspace keeps the controller's existing delete-backward path")
        }
    }
}
