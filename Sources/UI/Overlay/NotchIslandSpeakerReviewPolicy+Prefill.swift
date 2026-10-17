// NotchIslandSpeakerReviewPolicy+Prefill.swift
// Which name, if any, fills an unnamed voice's name box before anyone types:
// the name the call app showed while that voice talked, else the calendar
// 1:1 invitee. Both are only a starting point; nothing is saved or learned
// until the person saves the row. Shared by the island review and the
// Speakers page's "Name these people" rows.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

extension NotchIslandSpeakerReviewPolicy {
    /// Where a filled-in name came from (it picks the line under the field).
    enum PrefillSource: Equatable {
        /// The call app's speaker tile (Zoom, Meet, Teams, Slack).
        case callApp
        /// The calendar event was a 1:1.
        case calendar
    }

    struct Prefill: Equatable {
        let name: String
        let source: PrefillSource
    }

    /// The quiet line under a name the call app filled in.
    static let callAppPrefillNote = "From the call"

    static func prefillNote(for source: PrefillSource) -> String {
        switch source {
        case .callApp: return callAppPrefillNote
        case .calendar: return prefillNote
        }
    }

    /// The name to fill into a voice's empty name box. The call app's name
    /// wins over the calendar 1:1 name; a voice that already has a guess
    /// (voiceprint) or isn't asked for a name gets no call-app name; text
    /// already in the box is never replaced.
    static func prefill(
        callAppSuggestedName: String?,
        needsNaming: Bool,
        hasSuggestedName: Bool,
        oneOnOneName: String?,
        typed: String = ""
    ) -> Prefill? {
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if needsNaming, !hasSuggestedName, let name = trimmedName(callAppSuggestedName) {
            return Prefill(name: name, source: .callApp)
        }
        if let name = trimmedName(oneOnOneName) {
            return Prefill(name: name, source: .calendar)
        }
        return nil
    }

    /// `prefill` for a review entry. `oneOnOneName` is what
    /// `oneOnOnePrefill` gave for the meeting (nil before the calendar is
    /// read, or when the meeting wasn't a 1:1 with this one remote voice).
    static func prefillName(
        for entry: SpeakerNamingEntry,
        oneOnOneName: String? = nil,
        typed: String = ""
    ) -> Prefill? {
        prefill(
            callAppSuggestedName: entry.callAppSuggestedName,
            needsNaming: entry.needsNaming,
            hasSuggestedName: trimmedName(entry.currentName) != nil,
            oneOnOneName: oneOnOneName,
            typed: typed
        )
    }

    /// The Speakers page row's first draft.
    struct RowDraft: Equatable {
        let name: String
        /// The call app filled it in (the row says "From the call").
        let isFromCall: Bool
    }

    /// The Speakers page row's first draft: the voice's saved name when it
    /// has one (today's behavior), else the call app's name. Nil leaves the
    /// draft alone (someone already typed, or there's nothing to fill in).
    static func reviewRowDraft(
        currentDraft: String,
        savedName: String?,
        callAppSuggestedName: String?
    ) -> RowDraft? {
        guard currentDraft.isEmpty else { return nil }
        if let saved = trimmedName(savedName) {
            return RowDraft(name: saved, isFromCall: false)
        }
        return trimmedName(callAppSuggestedName).map { RowDraft(name: $0, isFromCall: true) }
    }

    private static func trimmedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
