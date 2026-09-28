// NotchIslandSpeakerReviewPolicy.swift
// Foundation-pure rules for the island's "Who was on this call?" review:
// which question each voice gets, which calendar invitees show as one-tap
// names, what the name box suggests as you type, and what the island says
// once names are saved. NotchIslandSpeakerReviewView draws them.

import Foundation

enum NotchIslandSpeakerReviewPolicy {
    /// The Later button's ring. Touching the review (play, Yes, No, typing)
    /// stops it, so the island never closes on someone mid-answer.
    static let laterSeconds: Double = 20
    /// How long "Everyone's named" stays before the island closes itself.
    static let doneLingerSeconds: Double = 6
    /// Invitee names shown before the little arrow that reveals the rest.
    static let inviteeChipLimit = 3
    /// Autocomplete rows under the name box.
    static let suggestionLimit = 3

    enum Question: Equatable {
        /// A likely match: "Is this Maya?" with Yes and No.
        case confirm(name: String)
        /// No guess: a name box with the invitees as one-tap names.
        case name
    }

    /// A voice with a suggested name gets a yes/no question; one without
    /// gets a name box. The pipeline only sends voices it isn't sure about,
    /// so a suggestion here is always worth confirming, never assumed.
    static func question(currentName: String?, needsConfirmation: Bool) -> Question {
        let trimmed = currentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if needsConfirmation, !trimmed.isEmpty {
            return .confirm(name: trimmed)
        }
        return .name
    }

    /// The invitees to offer as one-tap names: people not already named in
    /// this review, in invite order. The first `limit` show; the arrow opens
    /// the rest.
    static func inviteeChips(
        invitees: [String],
        alreadyUsed: Set<String>,
        showAll: Bool,
        limit: Int = inviteeChipLimit
    ) -> (shown: [String], hidden: Int) {
        let used = Set(alreadyUsed.map(SpeakerNameSelectionPolicy.normalizedSearchText))
        var seen: Set<String> = []
        let available = invitees.compactMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SpeakerNameSelectionPolicy.normalizedSearchText(trimmed)
            guard !trimmed.isEmpty, !used.contains(key), seen.insert(key).inserted else { return nil }
            return trimmed
        }
        guard !showAll, available.count > limit else { return (available, 0) }
        return (Array(available.prefix(limit)), available.count - limit)
    }

    struct Suggestion: Equatable {
        var label: String
        var detail: String
    }

    /// What the name box offers for `query`: saved people and invitees that
    /// match, invitees first, then by how often you've met them. Empty until
    /// something is typed; the invitee chips cover the empty box.
    static func suggestions(
        query: String,
        people: [(label: String, callCount: Int)],
        invitees: [String],
        limit: Int = suggestionLimit
    ) -> [Suggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let invited = Set(invitees.map(SpeakerNameSelectionPolicy.normalizedSearchText))
        var callsByLabel: [String: Int] = [:]
        for person in people { callsByLabel[person.label] = person.callCount }
        // Invitees nobody has saved yet are still names you can pick.
        let savedKeys = Set(people.map { SpeakerNameSelectionPolicy.normalizedSearchText($0.label) })
        for name in invitees where !savedKeys.contains(SpeakerNameSelectionPolicy.normalizedSearchText(name)) {
            callsByLabel[name.trimmingCharacters(in: .whitespacesAndNewlines)] = 0
        }
        let labels = Array(callsByLabel.keys)
        let ranked = SpeakerNameSelectionPolicy.sortedLabels(
            matching: trimmed,
            labels: labels,
            optionsByLabel: Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) }),
            displayName: { $0 },
            callCount: { callsByLabel[$0] ?? 0 }
        )
        let invitedFirst = ranked.filter { invited.contains(SpeakerNameSelectionPolicy.normalizedSearchText($0)) }
            + ranked.filter { !invited.contains(SpeakerNameSelectionPolicy.normalizedSearchText($0)) }
        return invitedFirst.prefix(limit).map { label in
            let calls = callsByLabel[label] ?? 0
            let callText = calls == 1 ? "1 call" : "\(calls) calls"
            let isInvited = invited.contains(SpeakerNameSelectionPolicy.normalizedSearchText(label))
            let detail: String
            switch (isInvited, calls > 0) {
            case (true, true): detail = "on the invite · \(callText)"
            case (true, false): detail = "on the invite"
            case (false, _): detail = callText
            }
            return Suggestion(label: label, detail: detail)
        }
    }

    /// The title and line the island shows after Done.
    static func doneCopy(leftForLater: Int) -> (title: String, detail: String) {
        if leftForLater <= 0 {
            return ("Everyone’s named", "Next time they’re recognized on their own.")
        }
        let voices = leftForLater == 1 ? "1 voice" : "\(leftForLater) voices"
        return ("Names saved", "\(voices) left to name in Speakers.")
    }

    /// The header question, with the meeting's name when it is known.
    static func headerTitle(meetingTitle: String?) -> String {
        let trimmed = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Who was on this call?" : "Who was on \(trimmed)?"
    }
}
