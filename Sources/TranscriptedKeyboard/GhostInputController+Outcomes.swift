#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Cocoa
import InputMethodKit
import OSLog

extension GhostInputController {
    func recordOutcomeShown(_ client: IMKTextInput, shown: ShownFieldState?) {
        let field = shown == nil ? fieldSnapshot(client) : nil
        let bundleIdentifier = shown?.bundleIdentifier ?? field?.bundleIdentifier ?? ""
        guard !Self.isOutcomeExcluded(bundleIdentifier: bundleIdentifier) else { return }
        let precedingCharacter = shown.map { $0.precedingCharacter }
            ?? field.flatMap { contextBeforeCaret(client, selection: $0.selection).last }
        // The receipt travels with the presentation that produced this
        // `.shown`; a mismatch can only mean a ghost the reducer showed
        // without passing through `present`, which does not exist today,
        // so the fallback is labelled legacy rather than guessed at.
        let provenance = presentedProvenance.flatMap { presented in
            presented.ticket == state.visibleTicket ? presented.provenance : nil
        } ?? GhostProvenance(
            register: ContinuationRegister.from(bundleIdentifier: bundleIdentifier),
            source: .unknownLegacy
        )
        let answered = openOpportunity.flatMap { open in
            open.ticket == state.visibleTicket ? open : nil
        }
        if answered != nil { openOpportunity = nil }
        GhostOutcomeLedger.noteShown(
            opportunityID: answered?.id,
            sessionIdentifier: suggestionSessionIdentifier,
            register: provenance.register,
            source: provenance.source,
            candidateCharacters: state.visibleText.count,
            candidateWordCount: state.visibleText.split(whereSeparator: \Character.isWhitespace).count,
            precedingCharacter: precedingCharacter,
            excluded: false,
            receipt: provenance.receipt
        )
    }

    /// Whether a model request may go out from `context`, and the boundary
    /// the flight recorder will file it under — `nil` when the caret is not
    /// an eligible opportunity at all.
    ///
    /// Word and (when served) punctuation boundaries are the long-standing
    /// case. Mid-word is the new one: with `allowsMidWordContinuation` on, a
    /// caret inside a word the writer has typed at least
    /// `RawContinuationPrompt.minimumMidWordPartialLetters` letters of is
    /// also a request, and the opportunity it opens is recorded with boundary
    /// `mid-word` — `openOpportunity` below hands the ledger the same
    /// preceding character this reads, so the two cannot drift.
    static func opportunityBoundary(
        context: String,
        allowsPunctuation: Bool,
        allowsMidWordContinuation: Bool
    ) -> TextFreeCursorBoundary? {
        RawContinuationPrompt.requestBoundary(
            in: context,
            allowingPunctuation: allowsPunctuation,
            allowingMidWord: allowsMidWordContinuation
        )
    }

    /// An eligible opportunity: the caret sits where a request may start and
    /// a model request is about to go out. Opens exactly one pending record.
    func openOpportunity(
        ticket: InlineSuggestionTicket,
        context: String,
        field: FieldSnapshot
    ) -> UUID? {
        endOpenOpportunity(.supersededByTyping, deadlineMissed: true)
        guard !Self.isOutcomeExcluded(bundleIdentifier: field.bundleIdentifier) else { return nil }
        let id = UUID()
        openOpportunity = (ticket, id)
        GhostOutcomeLedger.noteOpportunityOpened(
            id: id,
            sessionIdentifier: suggestionSessionIdentifier,
            hostRegister: ContinuationRegister.from(bundleIdentifier: field.bundleIdentifier),
            precedingCharacter: context.last,
            excluded: false
        )
        return id
    }

    /// Ends the open opportunity without a ghost. With `ticket`, only the
    /// opportunity for that request is ended; a stale caller is a no-op.
    /// Main thread only, like every other touch of controller state.
    func endOpenOpportunity(
        _ reason: SuggestionDecisionReason,
        ticket: InlineSuggestionTicket? = nil,
        receipt: GhostDecisionReceipt? = nil,
        deadlineMissed: Bool = false
    ) {
        guard let open = openOpportunity, ticket == nil || open.ticket == ticket else { return }
        openOpportunity = nil
        GhostOutcomeLedger.noteOpportunityEnded(
            id: open.id,
            reason: reason,
            receipt: receipt,
            deadlineMissed: deadlineMissed
        )
    }

    static func isOutcomeExcluded(
        bundleIdentifier: String,
        secureInput: Bool = IsSecureEventInputEnabled()
    ) -> Bool {
        if secureInput { return true }
        let configured = Set(
            UserDefaults.standard.stringArray(
                forKey: PersonalHistorySettingsContract.excludedAppsKey
            ) ?? []
        )
        return DefaultExcludedApps.isExcluded(
            bundleIdentifier,
            configuredExcludedApps: configured
        )
    }
}
