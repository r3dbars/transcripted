import Foundation

func testLiveTranscriptPlainTextRenderer() {
    func entry(
        source: LiveMeetingCodexSource,
        text: String,
        isFinal: Bool = true,
        at seconds: TimeInterval = 1
    ) -> LiveMeetingCodexTranscriptEntry {
        LiveMeetingCodexTranscriptEntry(
            source: source,
            text: text,
            timestampSeconds: seconds,
            createdAt: Date(timeIntervalSince1970: seconds),
            isFinal: isFinal
        )
    }

    runSuite("LiveTranscriptPlainTextRenderer — empty feed renders an empty string") {
        assertEqual(
            LiveTranscriptPlainTextRenderer.makeTranscriptPlainText(finals: [], partials: [:]),
            "",
            "no finals and no partials means nothing to copy"
        )
    }

    runSuite("LiveTranscriptPlainTextRenderer — labels mic as You and system as Them") {
        let finals = [
            entry(source: .microphone, text: "hello everyone"),
            entry(source: .system, text: "hi there"),
        ]
        assertEqual(
            LiveTranscriptPlainTextRenderer.makeTranscriptPlainText(finals: finals, partials: [:]),
            "You: hello everyone\nThem: hi there",
            "mic becomes You, system becomes Them, finals stay in order joined by newlines"
        )
    }

    runSuite("LiveTranscriptPlainTextRenderer — finals come first, then partials by source order") {
        let finals = [entry(source: .microphone, text: "final mic")]
        let partials: [LiveMeetingCodexSource: LiveMeetingCodexTranscriptEntry] = [
            .system: entry(source: .system, text: "partial them", isFinal: false),
            .microphone: entry(source: .microphone, text: "partial me", isFinal: false),
        ]
        assertEqual(
            LiveTranscriptPlainTextRenderer.makeTranscriptPlainText(finals: finals, partials: partials),
            "You: final mic\nYou: partial me\nThem: partial them",
            "finals render before partials, and the partial pass is microphone then system regardless of dict order"
        )
    }

    runSuite("LiveTranscriptPlainTextRenderer — only the present partial source is appended") {
        let partials: [LiveMeetingCodexSource: LiveMeetingCodexTranscriptEntry] = [
            .system: entry(source: .system, text: "them only", isFinal: false),
        ]
        assertEqual(
            LiveTranscriptPlainTextRenderer.makeTranscriptPlainText(finals: [], partials: partials),
            "Them: them only",
            "a missing mic partial should not produce a line"
        )
    }
}
