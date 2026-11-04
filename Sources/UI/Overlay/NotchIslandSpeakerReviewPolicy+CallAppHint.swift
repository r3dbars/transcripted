// NotchIslandSpeakerReviewPolicy+CallAppHint.swift
// What sits around a voice's name box before anyone types. The calendar 1:1
// invitee fills an empty box (still only saved on Done). The name the call
// app showed while that voice talked is only a hint next to it ("Call app
// showed: Maya"): it fills the box when the person taps it, never on its
// own, and an untouched hint is never saved or learned. Where the voiceprint
// already asks "Is this Maya?", the hint only says whether the call app
// agreed. Shared by the island review and the Speakers page's review rows.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

extension NotchIslandSpeakerReviewPolicy {
    // MARK: Calendar 1:1 prefill

    /// The calendar 1:1 name to fill into a voice's empty name box. Text
    /// already in the box is never replaced. The call app's name never
    /// fills a box (`callAppHint`).
    static func prefillName(
        for entry: SpeakerNamingEntry,
        oneOnOneName: String? = nil,
        typed: String = ""
    ) -> String? {
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return trimmedName(oneOnOneName)
    }

    // MARK: Call-app hint

    /// What the call app's name adds to one row. Never a prefill.
    enum CallAppHint: Equatable {
        /// The row asks for a name: "Call app showed: Maya". Tapping it puts
        /// the name in the box; nothing saves until the person saves the row.
        case offer(name: String)
        /// The voiceprint's guess is the same person: corroboration only.
        case agrees(name: String)
        /// The voiceprint guessed someone else. Its question stays; the call
        /// app's name is just shown next to it.
        case differs(name: String)

        var name: String {
            switch self {
            case .offer(let name), .agrees(let name), .differs(let name): return name
            }
        }

        var text: String {
            switch self {
            case .offer(let name), .differs(let name): return NotchIslandSpeakerReviewPolicy.callAppShowedText(name)
            case .agrees(let name): return "Call app showed \(name) too"
            }
        }

        /// The name a tap puts in the box; only an offer can be tapped.
        var fillsName: String? {
            if case .offer(let name) = self { return name }
            return nil
        }
    }

    static func callAppShowedText(_ name: String) -> String {
        "Call app showed: \(name)"
    }

    /// The call app's hint for a row in `state`, or nil when it has none
    /// or nothing to add. `currentName` is the voiceprint's guess (or the
    /// name a recognized voice carries); a name the person just said no to
    /// isn't offered back to them.
    static func callAppHint(
        callAppShownName: String?,
        state: RowState,
        currentName: String?
    ) -> CallAppHint? {
        guard let name = trimmedName(callAppShownName) else { return nil }
        let sameAsCurrent = trimmedName(currentName).map { comparable($0) == comparable(name) } ?? false
        switch state {
        case .asking:
            return sameAsCurrent ? .agrees(name: name) : .differs(name: name)
        case .naming:
            return sameAsCurrent ? nil : .offer(name: name)
        case .confirmed, .recognized, .named, .locked:
            return nil
        }
    }

    /// The Speakers page row's first draft: the voice's saved name when it
    /// has one. The call app's name never drafts itself in; it is offered
    /// as a tappable hint. Nil leaves the draft alone.
    static func reviewRowDraft(currentDraft: String, savedName: String?) -> String? {
        guard currentDraft.isEmpty else { return nil }
        return trimmedName(savedName)
    }

    /// The Speakers page row's call-app hint: offered only while the voice
    /// has no saved name.
    static func reviewRowCallAppHint(callAppShownName: String?, savedName: String?) -> CallAppHint? {
        guard trimmedName(savedName) == nil, let name = trimmedName(callAppShownName) else { return nil }
        return .offer(name: name)
    }

    /// Same person, the way Core compares a call-app name with a
    /// voiceprint name: inner whitespace collapsed, case folded.
    private static func comparable(_ name: String) -> String {
        SpeakerNameSelectionPolicy.normalizedSearchText(
            name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        )
    }

    private static func trimmedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
