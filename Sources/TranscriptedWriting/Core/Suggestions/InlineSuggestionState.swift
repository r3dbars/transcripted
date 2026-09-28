import Foundation

public struct InlineSuggestionTicket: Equatable, Sendable {
    public let clientIdentifier: String
    public let bundleIdentifier: String
    public let contextFingerprint: UInt64
    public let selectionLocation: Int
    public let selectionLength: Int
    public let requestIdentifier: Int

    public init(
        clientIdentifier: String,
        bundleIdentifier: String,
        contextFingerprint: UInt64,
        selectionLocation: Int,
        selectionLength: Int,
        requestIdentifier: Int = 0
    ) {
        self.clientIdentifier = clientIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.contextFingerprint = contextFingerprint
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.requestIdentifier = requestIdentifier
    }

    public static func fingerprint(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    public static func boundedContext(_ text: String, utf16Limit: Int) -> String {
        let utf16Text = text as NSString
        return utf16Text.substring(from: max(0, utf16Text.length - max(0, utf16Limit)))
    }

    public func advancing(
        with text: String,
        boundedContext: String,
        utf16Limit: Int
    ) -> Self {
        let nextContext = Self.boundedContext(
            boundedContext + text,
            utf16Limit: utf16Limit
        )
        let utf16Count = text.utf16.count
        return Self(
            clientIdentifier: clientIdentifier,
            bundleIdentifier: bundleIdentifier,
            contextFingerprint: Self.fingerprint(nextContext),
            selectionLocation: selectionLocation < 0 ? selectionLocation : selectionLocation + utf16Count,
            selectionLength: 0,
            requestIdentifier: requestIdentifier
        )
    }

    /// A visible suggestion keeps its original request identity while the user
    /// types through it. Only the live field state must still match.
    public func matchesFieldState(of other: Self) -> Bool {
        clientIdentifier == other.clientIdentifier
            && bundleIdentifier == other.bundleIdentifier
            && contextFingerprint == other.contextFingerprint
            && selectionLocation == other.selectionLocation
            && selectionLength == other.selectionLength
    }
}

public struct InlineSuggestionState: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case awaitSuggestion(InlineSuggestionTicket)
        case present(String, InlineSuggestionTicket)
        /// Extends an already-visible streamed suggestion without recording a
        /// second impression. The ticket must still match the live field.
        case update(String, InlineSuggestionTicket)
        case type(String, current: InlineSuggestionTicket?, advanced: InlineSuggestionTicket?)
        case acceptNextWord(
            current: InlineSuggestionTicket?,
            boundedContext: String,
            utf16Limit: Int
        )
        /// `appendsSeparator` moves the following space into the inserted
        /// text, the way a word accept already does, so the writer can keep
        /// typing (or a chained request can fire) without pressing space.
        case acceptAll(current: InlineSuggestionTicket?, appendsSeparator: Bool = false)
        /// Dismisses only the request that still owns pending or visible
        /// state. A late callback cannot erase a newer request.
        case dismissTicket(InlineSuggestionTicket)
        case dismiss
    }

    public enum Effect: Equatable, Sendable {
        case hide
        case insert(String)
        case show(String)
        case schedule(afterTyping: String)
        /// A fresh presentation became visible: either nothing was visible
        /// before, or a different suggestion was replaced. The re-show of a
        /// shortened remainder after a matching keystroke or a Tab accept is
        /// a continuation of the same presentation and does not repeat this.
        case shown
        /// The first word-accept of the current presentation. Later Tab
        /// presses that walk further through the same presentation do not
        /// repeat this.
        case accepted
    }

    public private(set) var visibleText = ""
    public private(set) var visibleTicket: InlineSuggestionTicket?
    public private(set) var pendingTicket: InlineSuggestionTicket?
    /// Whether the current presentation has already recorded its one
    /// `.accepted` effect. Reset whenever a new presentation begins.
    private var presentationAccepted = false

    public init() {}

    public var isVisible: Bool { !visibleText.isEmpty }

    public mutating func reduce(_ event: Event) -> [Effect] {
        switch event {
        case let .awaitSuggestion(ticket):
            let effects: [Effect] = isVisible ? [.hide] : []
            visibleText = ""
            visibleTicket = nil
            pendingTicket = ticket
            return effects

        case let .present(text, ticket):
            guard !text.isEmpty, pendingTicket == ticket else { return [] }
            pendingTicket = nil
            visibleText = text
            visibleTicket = ticket
            presentationAccepted = false
            return [.shown, .show(text)]

        case let .update(text, ticket):
            guard !text.isEmpty else { return [] }
            if pendingTicket == ticket {
                pendingTicket = nil
                visibleText = text
                visibleTicket = ticket
                presentationAccepted = false
                return [.shown, .show(text)]
            }
            guard visibleTicket == ticket else { return [] }
            // A stream may only grow the already-visible prefix. Rewrites,
            // shrinking frames, and duplicate frames are ignored so marked
            // text never flickers or moves backwards.
            guard text.count > visibleText.count, text.hasPrefix(visibleText) else { return [] }
            visibleText = text
            // `show` replaces the current marked text in IMKit; no hide/show
            // round-trip keeps streamed updates quiet while the user types.
            return [.show(text)]

        case let .type(grapheme, current, advanced):
            pendingTicket = nil
            guard
                visibleTicket == current,
                let advanced,
                let first = visibleText.first,
                String(first) == grapheme
            else {
                let effects: [Effect] = isVisible
                    ? [.hide, .insert(grapheme), .schedule(afterTyping: grapheme)]
                    : [.insert(grapheme), .schedule(afterTyping: grapheme)]
                visibleText = ""
                visibleTicket = nil
                return effects
            }

            let remainder = String(visibleText.dropFirst())
            visibleText = remainder
            visibleTicket = remainder.isEmpty ? nil : advanced
            return remainder.isEmpty
                ? [.hide, .insert(grapheme)]
                : [.hide, .insert(grapheme), .show(remainder)]

        case let .acceptNextWord(current, boundedContext, utf16Limit):
            pendingTicket = nil
            guard isVisible, let current, visibleTicket == current else {
                let effects: [Effect] = isVisible ? [.hide] : []
                visibleText = ""
                visibleTicket = nil
                return effects
            }
            let rawAccepted = Self.nextWordPrefix(in: visibleText)
            let rawRemainder = visibleText.dropFirst(rawAccepted.count)
            let remainder = String(rawRemainder.drop(while: \Character.isWhitespace))
            let accepted = rawAccepted.contains(where: { !$0.isWhitespace })
                && rawAccepted.last?.isWhitespace != true
                ? rawAccepted + " "
                : rawAccepted
            let recordAccepted = !presentationAccepted
            presentationAccepted = true
            visibleText = remainder
            visibleTicket = remainder.isEmpty
                ? nil
                : current.advancing(
                    with: accepted,
                    boundedContext: boundedContext,
                    utf16Limit: utf16Limit
                )
            var effects: [Effect] = remainder.isEmpty
                ? [.hide, .insert(accepted)]
                : [.hide, .insert(accepted), .show(remainder)]
            if recordAccepted { effects.append(.accepted) }
            return effects

        case let .acceptAll(current, appendsSeparator):
            pendingTicket = nil
            guard isVisible, let current, visibleTicket == current else {
                let effects: [Effect] = isVisible ? [.hide] : []
                visibleText = ""
                visibleTicket = nil
                return effects
            }
            let accepted = appendsSeparator && visibleText.last?.isWhitespace != true
                ? visibleText + " "
                : visibleText
            visibleText = ""
            visibleTicket = nil
            presentationAccepted = true
            return [.hide, .insert(accepted), .accepted]

        case let .dismissTicket(ticket):
            guard pendingTicket == ticket || visibleTicket == ticket else { return [] }
            let effects: [Effect] = visibleTicket == ticket && isVisible ? [.hide] : []
            if pendingTicket == ticket { pendingTicket = nil }
            if visibleTicket == ticket {
                visibleText = ""
                visibleTicket = nil
            }
            return effects

        case .dismiss:
            pendingTicket = nil
            let effects: [Effect] = isVisible ? [.hide] : []
            visibleText = ""
            visibleTicket = nil
            return effects
        }
    }

    /// Includes whitespace before the first visible word. Acceptance moves the
    /// following separator into the inserted text so the user can type again
    /// immediately while repeated Tab presses still advance one word at a time.
    private static func nextWordPrefix(in text: String) -> String {
        guard let wordStart = text.firstIndex(where: { !$0.isWhitespace }) else {
            return text
        }
        guard let nextSeparator = text[wordStart...].firstIndex(where: \Character.isWhitespace) else {
            return text
        }
        return String(text[..<nextSeparator])
    }
}
