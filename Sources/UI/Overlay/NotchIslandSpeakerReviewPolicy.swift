// NotchIslandSpeakerReviewPolicy.swift
// Foundation-pure rules for the island's "Who was on this call?" review:
// which question each voice gets, which calendar invitees show as one-tap
// names, what the name box suggests as you type, and what the island says
// once names are saved; plus the 1:1 calendar name, Keep Local Mic as You,
// and Discard Voice carried over from the review window.
// NotchIslandSpeakerReviewView draws them.

import Foundation

enum NotchIslandSpeakerReviewPolicy {
    /// The Later button's ring. Touching the review (play, Yes, No, typing)
    /// stops it, so the island never closes on someone mid-answer. It only
    /// runs while the review is on screen (`laterCountdownRuns`).
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
    /// gets a name box. Voices the pipeline named by itself don't come
    /// through here: they're listed as recognized, with a hover correction.
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

    // MARK: The name box

    /// One row in the list under the name box.
    enum NameBoxRow: Equatable {
        /// A saved person or invitee from the suggestions.
        case saved(String)
        /// What was typed, saved as someone new.
        case newPerson(String)

        var label: String {
            switch self {
            case .saved(let label), .newPerson(let label): return label
            }
        }
    }

    /// The rows under the name box: the suggestions, then what was typed as
    /// a new person unless a suggestion already is exactly that name.
    static func nameBoxRows(typed: String, suggestions: [Suggestion]) -> [NameBoxRow] {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var rows = suggestions.map { NameBoxRow.saved($0.label) }
        if exactMatchIndex(typed: trimmed, suggestions: suggestions) == nil {
            rows.append(.newPerson(trimmed))
        }
        return rows
    }

    /// The row Return picks when nobody used the arrows: an exact match if
    /// there is one, otherwise the typed name as a new person. Never a
    /// longer saved name, so "Chris" can't turn into "Christina".
    static func defaultHighlight(typed: String, suggestions: [Suggestion]) -> Int? {
        let rows = nameBoxRows(typed: typed, suggestions: suggestions)
        guard !rows.isEmpty else { return nil }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return exactMatchIndex(typed: trimmed, suggestions: suggestions) ?? (rows.count - 1)
    }

    /// ↓ / ↑ from `highlighted` (nil = the default row), kept inside the rows.
    static func movedHighlight(from highlighted: Int?, by delta: Int, typed: String, suggestions: [Suggestion]) -> Int? {
        let rows = nameBoxRows(typed: typed, suggestions: suggestions)
        guard !rows.isEmpty,
              let start = highlighted ?? defaultHighlight(typed: typed, suggestions: suggestions) else { return nil }
        return min(max(start + delta, 0), rows.count - 1)
    }

    /// What Return or Tab saves: the row the person arrowed to, else the
    /// default row. Nil for an empty box.
    static func nameToSave(typed: String, suggestions: [Suggestion], highlighted: Int?) -> String? {
        let rows = nameBoxRows(typed: typed, suggestions: suggestions)
        if let highlighted, rows.indices.contains(highlighted) {
            return rows[highlighted].label
        }
        guard let index = defaultHighlight(typed: typed, suggestions: suggestions) else { return nil }
        return rows[index].label
    }

    /// How the review was closed.
    enum Finish: Equatable {
        /// Done: the person looked over the list and saved it.
        case done
        /// Later, or its ring running out.
        case later
    }

    /// The name a voice ends up with when Done or Later is pressed: one
    /// already submitted, else whatever is sitting in its name box, read the
    /// same way Return would. No typed name is lost. A name the calendar
    /// filled in for a 1:1 that nobody touched is only a suggestion: Done
    /// saves it like a typed name, Later leaves the voice unnamed.
    static func answerOnFinish(
        committed: String?,
        typed: String,
        suggestions: [Suggestion],
        highlighted: Int?,
        typedIsUntouchedPrefill: Bool = false,
        finish: Finish = .done
    ) -> String? {
        if let committed { return committed }
        if typedIsUntouchedPrefill, finish == .later { return nil }
        return nameToSave(typed: typed, suggestions: suggestions, highlighted: highlighted)
    }

    // MARK: 1:1 calendar name

    /// The name to fill into the one remote voice's box when the calendar
    /// meeting was a 1:1, by the review window's rule
    /// (`MeetingInviteeSuggestionPolicy.oneOnOnePrefill`): exactly one
    /// invitee, exactly one remote voice in the whole meeting, and that voice
    /// is asked about with no suggested name. `askedRemoteVoicesHaveSuggestion`
    /// has one entry per remote voice the review asks about (recognized
    /// voices aren't asked; they only count in `remoteVoicesInMeeting`).
    /// The name is filled in, never saved on its own.
    static func oneOnOnePrefill(
        invitees: [String],
        remoteVoicesInMeeting: Int?,
        askedRemoteVoicesHaveSuggestion: [Bool]
    ) -> String? {
        MeetingInviteeSuggestionPolicy.oneOnOnePrefill(
            inviteeNames: invitees,
            remoteVoicesInMeeting: remoteVoicesInMeeting,
            remoteRowsInReview: askedRemoteVoicesHaveSuggestion.count,
            remoteRowHasSuggestion: askedRemoteVoicesHaveSuggestion.first ?? false
        )
    }

    /// The line under a voice whose name the calendar filled in (short: the
    /// caption is one truncating line).
    static let prefillNote = "Filled in from your calendar"

    // MARK: Keep as You and Discard Voice

    /// A voice set aside from naming: kept as you, or thrown away.
    enum Lock: Equatable {
        /// "Keep Local Mic as You" is on: every local mic voice saves as You.
        case keptAsYou
        /// "Discard Voice": not saved to People. The transcript stays saved.
        case discarded
    }

    /// Which lock a voice is under. Keep as You covers every local mic voice
    /// and wins over a discard, the same as the review window.
    static func lock(isMic: Bool, keepMicAsYou: Bool, discarded: Bool) -> Lock? {
        if isMic, keepMicAsYou { return .keptAsYou }
        return discarded ? .discarded : nil
    }

    /// The local mic section's switch, shown only when local mic voices are asked about.
    static func keepAsYouTitle(keepMicAsYou: Bool) -> String {
        keepMicAsYou ? "Review Local Mic Voices" : "Keep Local Mic as You"
    }

    static let keepAsYouHelp = "Use one \u{201C}You\u{201D} label for everyone picked up by the local microphone."

    /// The per-voice discard button.
    static func discardTitle(discarded: Bool) -> String {
        discarded ? "Undo Discard" : "Discard Voice"
    }

    static let discardHelp = "Do not save this voice to People. The transcript stays saved."

    /// The line a locked voice shows in place of its question.
    static func lockNote(_ lock: Lock) -> String {
        switch lock {
        case .keptAsYou: return "Will be saved as \u{201C}You\u{201D}"
        case .discarded: return "Will not be saved to People"
        }
    }

    /// Discard is offered on a voice the review asks about while its name
    /// box is open (a voice with no guess, or after No), and never under Keep
    /// as You. Voices Transcripted recognized on its own are corrected, not
    /// discarded.
    static func offersDiscard(isRecognized: Bool, nameBoxOpen: Bool, keptAsYou: Bool) -> Bool {
        !isRecognized && nameBoxOpen && !keptAsYou
    }

    private static func exactMatchIndex(typed: String, suggestions: [Suggestion]) -> Int? {
        let key = SpeakerNameSelectionPolicy.normalizedSearchText(typed)
        return suggestions.firstIndex { SpeakerNameSelectionPolicy.normalizedSearchText($0.label) == key }
    }

    // MARK: Timing

    /// The Later ring (and the review's own close) counts down only while
    /// the review is on screen and the pointer is off it. Hidden behind a
    /// dictation or a busy meeting, it waits.
    static func laterCountdownRuns(visible: Bool, hovered: Bool) -> Bool {
        visible && !hovered
    }

    /// A list where everyone was recognized asks nothing, so it closes on its
    /// own this long after it arrives, even if it is still waiting hidden
    /// behind a dictation or the next meeting. It never holds on forever.
    static let recognizedOnlyHardCapSeconds: Double = 120

    /// How long a review may wait in all before it closes itself: only a
    /// list with nobody to ask has a cap; a review that asks waits for answers.
    static func hardCapSeconds(recognizedOnly: Bool) -> Double? {
        recognizedOnly ? recognizedOnlyHardCapSeconds : nil
    }

    /// At the cap, a pointer over the island holds the close until it leaves.
    static func hardCapClosesNow(hovered: Bool) -> Bool {
        !hovered
    }

    /// The asked and recognized voices of one review, keyed for looking up
    /// which voice an answer was about (so "Not Taylor?" corrections report
    /// the recognized voice's match). An asked voice wins a key collision.
    static func entriesByKey<Entry>(
        asked: [Entry],
        recognized: [Entry],
        key: (Entry) -> String
    ) -> [String: Entry] {
        Dictionary((asked + recognized).map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Recognized voices

    /// The hover offer on a voice Transcripted named by itself.
    static func correctionPrompt(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        return "Not \(first)?"
    }

    /// Done on a list where everyone was recognized just closes unless
    /// something was corrected; a review that asked always sums up.
    static func doneShowsSummary(recognizedOnly: Bool, updates: Int) -> Bool {
        !recognizedOnly || updates > 0
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
    /// When every voice was recognized nothing is asked, so the header just
    /// says who was on it.
    static func headerTitle(meetingTitle: String?, recognizedOnly: Bool = false) -> String {
        let trimmed = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if recognizedOnly {
            return trimmed.isEmpty ? "On this call" : "On \(trimmed)"
        }
        return trimmed.isEmpty ? "Who was on this call?" : "Who was on \(trimmed)?"
    }
}
