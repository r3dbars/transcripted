import Foundation

/// Foundation-pure renderer for the live transcript drawer's "Copy" action.
///
/// Extracted from `MeetingOverlayController.makeTranscriptPlainText()` so the
/// clipboard payload can be unit-tested without the AppKit overlay. It renders
/// the in-memory `LiveMeetingTranscriptFeed` value types to plain text: final
/// lines in order, then the newest partial per source. Each line is labelled by
/// source — the microphone is "You", the system tap is "Them".
///
/// The copied text is user-facing, so labelling, ordering, and the newline
/// join must stay byte-for-byte identical to the original inline helper.
enum LiveTranscriptPlainTextRenderer {
    static func makeTranscriptPlainText(
        finals: [LiveMeetingCodexTranscriptEntry],
        partials: [LiveMeetingCodexSource: LiveMeetingCodexTranscriptEntry]
    ) -> String {
        var lines: [String] = []
        for entry in finals {
            lines.append("\(entry.source == .microphone ? "You" : "Them"): \(entry.text)")
        }
        for source in [LiveMeetingCodexSource.microphone, .system] {
            if let partial = partials[source] {
                lines.append("\(source == .microphone ? "You" : "Them"): \(partial.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
