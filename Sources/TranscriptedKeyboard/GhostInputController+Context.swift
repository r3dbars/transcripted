#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Cocoa
import InputMethodKit
import OSLog

extension GhostInputController {
    // MARK: - Tickets and context

    /// One read of the client's cursor and identity, shared by everything
    /// that needs it within a single synchronous turn.
    ///
    /// Every `selectedRange()` / `bundleIdentifier()` is a cross-process call
    /// into the app being typed into, made on the same main thread that has to
    /// service the next keystroke — and `contextBeforeCaret`,
    /// ticket construction and `trailingTextAfterCaret` each used to make
    /// those calls independently, so one `present()` paid for three
    /// `selectedRange()` round trips and `updateSuggestion` for four. The
    /// client cannot change underneath us mid-turn, so reading once is exactly
    /// equivalent and materially cheaper — most of all in Electron hosts,
    /// whose own main thread is often already busy.
    struct FieldSnapshot {
        let selection: NSRange
        let bundleIdentifier: String
    }
    /// What `present` already read this turn, so `.shown` doesn't read it again.
    typealias ShownFieldState = (bundleIdentifier: String, precedingCharacter: Character?)

    func fieldSnapshot(_ client: IMKTextInput) -> FieldSnapshot {
        // Secure Event Input first, before any read. The readers below checked
        // this before touching the client at all, and routing them through a
        // snapshot must not quietly invert that ordering: in a password field
        // Tilde reads nothing, not even the caret or the host identity.
        guard !IsSecureEventInputEnabled() else {
            return FieldSnapshot(selection: Self.unset, bundleIdentifier: "")
        }
        return FieldSnapshot(
            selection: client.selectedRange(),
            bundleIdentifier: client.bundleIdentifier() ?? ""
        )
    }

    func ticket(context: String, field: FieldSnapshot) -> InlineSuggestionTicket {
        InlineSuggestionTicket(
            clientIdentifier: suggestionSessionIdentifier,
            bundleIdentifier: field.bundleIdentifier,
            contextFingerprint: InlineSuggestionTicket.fingerprint(context),
            selectionLocation: field.selection.location == NSNotFound ? -1 : field.selection.location,
            selectionLength: field.selection.length == NSNotFound ? -1 : field.selection.length,
            requestIdentifier: scheduleRevision
        )
    }

    /// Re-read the bounded context on acceptance so a same-range field change
    /// cannot commit a stale suggestion.
    func matchingVisibleState(
        for client: IMKTextInput
    ) -> (ticket: InlineSuggestionTicket, context: String)? {
        guard let visible = state.visibleTicket else { return nil }
        let field = fieldSnapshot(client)
        let context = contextBeforeCaret(client, selection: field.selection)
        let current = ticket(context: context, field: field)
        return visible.matchesFieldState(of: current) ? (visible, context) : nil
    }

    func contextBeforeCaret(_ client: IMKTextInput) -> String {
        guard !IsSecureEventInputEnabled() else { return "" }
        return contextBeforeCaret(client, selection: client.selectedRange())
    }

    /// Takes the caret alone, never a whole `FieldSnapshot`: this reader has no
    /// use for the bundle identifier, and making it demand one would add a
    /// cross-process call per keystroke rather than remove one.
    func contextBeforeCaret(_ client: IMKTextInput, selection: NSRange) -> String {
        contextBeforeCaret(client, hostText: hostContextBeforeCaret(client, selection: selection))
    }

    /// `nil` host text reads nothing; empty falls back to what this session typed.
    func contextBeforeCaret(_ client: IMKTextInput, hostText: String?) -> String {
        guard let hostText, hostText.isEmpty else { return hostText ?? "" }
        return fallbackOwner(for: client) == fallbackOwner ? typedFallback : ""
    }

    /// Host text only: `nil` under secure input or with no caret, "" when the host has none.
    func hostContextBeforeCaret(_ client: IMKTextInput, selection: NSRange) -> String? {
        guard !IsSecureEventInputEnabled() else { return nil }
        guard selection.location != NSNotFound, selection.length == 0 else { return nil }
        if selection.location > 0 {
            // Quantized start: once the field is past the limit, a window
            // that slides one character per keystroke moves every byte of
            // the prompt behind the scaffold and defeats the helper's
            // prompt-cache reuse for the rest of the session. The window is
            // never longer than the limit and never more than one quantum
            // shorter.
            let start = RawContinuationPrompt.stableWindowStart(
                end: selection.location,
                limit: Self.contextLimit
            )
            let range = NSRange(location: start, length: selection.location - start)
            if let text = client.attributedSubstring(from: range)?.string, !text.isEmpty {
                return text
            }
        }
        return ""
    }

    func trailingTextAfterCaret(_ client: IMKTextInput) -> String {
        guard !IsSecureEventInputEnabled() else { return "" }
        return trailingTextAfterCaret(client, selection: client.selectedRange())
    }

    func trailingTextAfterCaret(_ client: IMKTextInput, selection: NSRange) -> String {
        guard !IsSecureEventInputEnabled() else { return "" }
        guard let range = Self.trailingContextRange(
            selection: selection,
            markedRange: client.markedRange(),
            documentLength: client.length()
        ) else {
            return ""
        }
        return client.attributedSubstring(from: range)?.string ?? ""
    }

    func canAcceptSuggestion(in client: IMKTextInput) -> Bool {
        SuggestionActivationPolicy.isAtGrowingEdge(
            trailingTextAfterCaret: trailingTextAfterCaret(client)
        )
    }
}
