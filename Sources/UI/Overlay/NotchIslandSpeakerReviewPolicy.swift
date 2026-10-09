// NotchIslandSpeakerReviewPolicy.swift
// Foundation-pure rules for the island's "Who spoke?" review: which question
// each voice gets, what each row shows around its voice print (title, the line
// under it, the buttons, how many rings are lit, when it celebrates), which
// calendar invitees show as one-tap names, what the name field suggests as you
// type, and what the island says once names are saved; plus the 1:1 calendar
// name, "All me" (keep local mic as You), and "Not a person" (discard) carried
// over from the review window. NotchIslandSpeakerReviewView and
// NotchIslandVoiceRowView draw them.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum NotchIslandSpeakerReviewPolicy {
    /// The Later button's ring. Touching the review (play, Yes, No, typing)
    /// stops it, so the island never closes on someone mid-answer. It only
    /// runs while the review is on screen (`laterCountdownRuns`).
    static let laterSeconds: Double = 20
    /// How long "Everyone's named" stays before the island closes itself.
    static let doneLingerSeconds: Double = 6
    /// Invitee names shown before the little arrow that reveals the rest.
    static let inviteeChipLimit = 3
    /// Autocomplete rows under the name box. Typing hides the invitee chips,
    /// so the list has room for more.
    static let suggestionLimit = 5

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

    // MARK: Voice prints

    /// Progress toward silent naming for the person a row claims, as Core
    /// reported it: confirmed meetings before this review, the bar this
    /// meeting used, and whether the person is trusted (not on probation).
    struct Progress: Equatable {
        var confirmed: Int
        var required: Int
        var isTrusted: Bool
        var earnsConfirmation: Bool

        init(confirmed: Int, required: Int, isTrusted: Bool = true, earnsConfirmation: Bool = true) {
            self.confirmed = confirmed
            self.required = required
            self.isTrusted = isTrusted
            self.earnsConfirmation = earnsConfirmation
        }

        var tier: SpeakerNamingTier {
            SpeakerNamingTier.tier(confirmedMeetings: confirmed, requiredMeetings: required, isTrusted: isTrusted)
        }

        /// After one more yes in this review.
        var afterYes: Progress {
            Progress(confirmed: max(0, confirmed) + (earnsConfirmation ? 1 : 0), required: required, isTrusted: isTrusted, earnsConfirmation: earnsConfirmation)
        }

        /// Lit rings out of five, scaled when the bar is lower than five.
        var litRings: Int {
            SpeakerNamingTierPresentation.filledSegments(confirmed: confirmed, required: required, tier: tier)
        }
    }

    /// Where a voice's name field came from, for what Undo does there.
    enum NamingOrigin: Equatable {
        /// No guess: the field is the question.
        case unknownVoice
        /// ✕ on "Marcus Reed?": Undo asks again.
        case rejectedSuggestion
        /// "Not Priya?" on a voice named silently: Undo keeps Priya.
        case correctingRecognized
    }

    /// Who a typed or picked name is.
    enum NamedAs: Equatable {
        /// Typed: someone new, saved under this voice.
        case newPerson
        /// A person already in Speakers (their progress isn't in the request).
        case savedPerson
        /// "Me" on a local mic voice.
        case owner
    }

    /// What one row is showing.
    enum RowState: Equatable {
        /// "Marcus Reed?" with ✕ and ✓.
        case asking
        /// ✓ was tapped.
        case confirmed
        /// Transcripted named this voice on its own: the name, nothing else.
        case recognized
        /// The title is the name field ("Who's this?").
        case naming(NamingOrigin)
        /// A name was typed or picked in place.
        case named(NamedAs)
        /// "All me" or "Not a person".
        case locked(Lock)
    }

    /// Buttons at a row's right edge, left to right.
    enum RowControl: Equatable {
        /// Round dark ✕.
        case no
        /// Round white ✓.
        case yes
        /// "Undo" after an answer.
        case undo
        /// "Not Priya?" on hover over a voice named silently.
        case correct
        /// "Undo" on a "Not Priya?" field: it was Priya after all.
        case keep
        /// The faint × for "Not a person".
        case discard
        /// "Undo" on a voice marked not a person.
        case undoDiscard
    }

    /// The row's title, or nil when the title is the name field.
    static func rowTitle(_ state: RowState, name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch state {
        case .asking: return "\(trimmed)?"
        case .confirmed, .recognized, .named: return trimmed
        case .naming: return nil
        case .locked(let lock): return lockNote(lock)
        }
    }

    /// "Marcus Reed?" reads a little dimmer until it's answered.
    static func titleIsUnanswered(_ state: RowState) -> Bool {
        state == .asking
    }

    /// Rings lit in the row's print. ✓ shows the count this answer earns; a
    /// voice the row no longer claims (a name field, All me, Not a person)
    /// shows an empty print. A name picked from Speakers keeps that person's
    /// print empty because the request doesn't carry their count.
    static func litRings(_ state: RowState, progress: Progress?) -> Int {
        switch state {
        case .asking: return progress?.litRings ?? 0
        case .confirmed: return progress?.afterYes.litRings ?? 0
        case .recognized: return progress?.litRings ?? VoicePrintGeometry.ringCount
        case .named(.newPerson): return newPersonProgress.litRings
        // Naming a voice as someone already saved is a yes for them.
        case .named(.savedPerson): return progress?.afterYes.litRings ?? 0
        case .named(.owner), .naming, .locked: return 0
        }
    }

    /// A typed name is a new person with this meeting as their first.
    static let newPersonProgress = Progress(confirmed: 1, required: SpeakerNamingPolicy.requiredConfirmedMeetings)

    /// The line under the name (shared copy in SpeakerNamingTierPresentation),
    /// or the calendar note on a 1:1 name nobody touched.
    static func rowHint(_ state: RowState, progress: Progress?, prefilledUntouched: Bool = false) -> SpeakerNamingTierPresentation.ReviewHint? {
        switch state {
        case .asking:
            guard let progress else { return nil }
            return SpeakerNamingTierPresentation.reviewHint(
                moment: .asking, confirmedBefore: progress.confirmed, required: progress.required, isTrusted: progress.isTrusted, earnsConfirmation: progress.earnsConfirmation
            )
        case .confirmed, .named(.savedPerson):
            guard let progress else { return nil }
            return SpeakerNamingTierPresentation.reviewHint(
                moment: .confirmed, confirmedBefore: progress.confirmed, required: progress.required, isTrusted: progress.isTrusted, earnsConfirmation: progress.earnsConfirmation
            )
        case .named(.newPerson):
            return SpeakerNamingTierPresentation.reviewHint(
                moment: .savedNew, confirmedBefore: 0, required: newPersonProgress.required, isTrusted: true
            )
        case .naming:
            return prefilledUntouched ? SpeakerNamingTierPresentation.ReviewHint(text: prefillNote, usesPersonColor: false) : nil
        case .recognized, .named(.owner), .locked:
            return nil
        }
    }

    /// The row's buttons. A voice named silently shows only its name until
    /// the pointer is on the row, then "Not Priya?".
    static func rowControls(_ state: RowState, hovered: Bool) -> [RowControl] {
        switch state {
        case .asking: return [.no, .yes]
        case .confirmed, .named: return [.undo]
        case .recognized: return hovered ? [.correct] : []
        case .naming(.correctingRecognized): return [.keep]
        case .naming(.rejectedSuggestion):
            return offersDiscard(isRecognized: false, nameBoxOpen: true, keptAsYou: false) ? [.discard, .undo] : [.undo]
        case .naming(.unknownVoice):
            return offersDiscard(isRecognized: false, nameBoxOpen: true, keptAsYou: false) ? [.discard] : []
        case .locked(.discarded): return [.undoDiscard]
        case .locked(.keptAsYou): return []
        }
    }

    /// What Undo goes back to. After ✓, or on the name field ✕ opened, it
    /// asks "Marcus Reed?" again; after a typed or picked name it goes
    /// back to the name field the name came from (`origin`).
    static func undoTarget(_ state: RowState, origin: NamingOrigin) -> RowState {
        switch state {
        case .confirmed, .naming(.rejectedSuggestion): return .asking
        case .named: return .naming(origin)
        default: return state
        }
    }

    /// Moving on after an answer opens the next open row only when its title
    /// is the name field. An asked row has nothing to type into, so the
    /// island doesn't take the keyboard for it.
    static func takesKeyboardOnAdvance(_ state: RowState) -> Bool {
        if case .naming = state { return true }
        return false
    }

    /// The order colors are handed out in (`VoicePrintStyle.colorIndices`):
    /// everyone who already has a color keeps their place, even after their
    /// row stops claiming them, and new people join at the end. So a color
    /// never moves to someone else mid-review, and nobody new takes one
    /// that's on screen or was.
    static func colorOrder(existing: [UUID], claims: [UUID]) -> [UUID] {
        var order = existing
        var seen = Set(existing)
        for id in claims where seen.insert(id).inserted {
            order.append(id)
        }
        return order
    }

    /// The match animation plays on ✓ and on naming a new voice in place;
    /// small while the print is filling, full when it completes.
    static func celebrates(_ state: RowState) -> Bool {
        switch state {
        case .confirmed, .named(.newPerson), .named(.savedPerson): return true
        default: return false
        }
    }

    /// The row still stands for a saved (or just named) person, so its print
    /// takes a color on this call.
    static func claimsPerson(_ state: RowState) -> Bool {
        switch state {
        case .asking, .confirmed, .recognized, .named(.newPerson), .named(.savedPerson): return true
        case .named(.owner), .naming, .locked: return false
        }
    }

    /// Counted (with a glowing dot) in "N people named automatically": a voice
    /// named silently on this call, or a ✓ that completes the print.
    static func namedAutomatically(_ state: RowState, progress: Progress?) -> Bool {
        switch state {
        case .recognized: return true
        case .confirmed, .named(.savedPerson): return progress?.afterYes.tier == .auto
        default: return false
        }
    }

    /// One footer dot per saved person, even when diarization split their
    /// voice into several rows. Unresolved plain names keep a name key.
    static func footerPersonKey(personID: UUID?, name: String? = nil, fallback: String) -> String {
        if let personID { return "person-\(personID.uuidString)" }
        if let name {
            let normalized = SpeakerNameSelectionPolicy.normalizedSearchText(name)
            if !normalized.isEmpty { return "name-\(normalized)" }
        }
        return fallback
    }

    /// Keep the first qualifying row's color and landing behavior, not just
    /// its key. Undo recomputes this list from the remaining qualifying rows.
    static func uniqueFooterPeople<Entry>(_ entries: [Entry], key: (Entry) -> String) -> [Entry] {
        var seen = Set<String>()
        return entries.filter { seen.insert(key($0)).inserted }
    }

    /// Whose print a row shows: the saved person it claims (the suggested
    /// person on "Is this …?", or the one picked in place), else the voice
    /// itself.
    static func printOwner(_ state: RowState, voiceID: UUID, suggestedID: UUID?, pickedID: UUID?) -> UUID {
        switch state {
        case .asking, .confirmed, .recognized: return suggestedID ?? voiceID
        case .named(.savedPerson): return pickedID ?? voiceID
        default: return voiceID
        }
    }

    /// The hover tip on a print and its VoiceOver hint.
    static func printExplanation(_ state: RowState, name: String?, progress: Progress?) -> String {
        let listen = "Press play to listen."
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return listen }
        let shown: Progress?
        switch state {
        case .asking, .recognized: shown = progress
        case .confirmed, .named(.savedPerson): shown = progress?.afterYes
        case .named(.newPerson): shown = newPersonProgress
        default: shown = nil
        }
        guard let shown else { return listen }
        return SpeakerNamingTierPresentation.explanation(
            name: name, confirmed: shown.confirmed, required: shown.required, tier: shown.tier, isTrusted: shown.isTrusted
        )
    }

    /// VoiceOver's name for a row: what it shows, then the line under it.
    /// `corrected`: the name replaced one Transcripted gave on its own.
    static func rowAccessibilityLabel(_ state: RowState, name: String?, hint: String?, corrected: Bool = false) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary: String
        switch state {
        case .asking: summary = "Is this \(trimmed)?"
        case .confirmed: summary = "\(trimmed), confirmed"
        case .recognized: summary = "\(trimmed), named automatically"
        case .named: summary = corrected ? "\(trimmed), corrected" : "\(trimmed), named"
        case .naming: summary = "Unnamed voice"
        case .locked(let lock): summary = lockNote(lock)
        }
        guard let hint, !hint.isEmpty else { return summary }
        let endsSentence = summary.last.map { ".?!".contains($0) } ?? false
        return endsSentence ? "\(summary) \(hint)" : "\(summary). \(hint)"
    }

    /// The invitee chips fade in under the name field only while it has the
    /// keyboard and nothing is typed; typing swaps them for the list.
    static func showsInviteeChips(typed: String, focused: Bool) -> Bool {
        focused && showsInviteeChips(typed: typed)
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

    /// The invitee chips cover the empty box. Once something is typed they
    /// step aside and the list under the box takes their place.
    static func showsInviteeChips(typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the name box offers for `query`: saved people and invitees that
    /// match, invitees first, then by how often you've met them. Empty until
    /// something is typed. On a local mic voice (`includeOwner`), "Me" leads
    /// when the typing could be "me", since its chip is hidden by then.
    static func suggestions(
        query: String,
        people: [(label: String, callCount: Int)],
        invitees: [String],
        includeOwner: Bool = false,
        limit: Int = suggestionLimit
    ) -> [Suggestion] {
        let matches = savedSuggestions(query: query, people: people, invitees: invitees, limit: limit)
        let key = SpeakerNameSelectionPolicy.normalizedSearchText(query)
        guard includeOwner, !key.isEmpty, "me".hasPrefix(key) else { return matches }
        let owner = Suggestion(label: SpeakerNameSelectionPolicy.ownerLabel, detail: "your own voice")
        return Array(([owner] + matches.filter { $0.label != owner.label }).prefix(limit))
    }

    private static func savedSuggestions(
        query: String,
        people: [(label: String, callCount: Int)],
        invitees: [String],
        limit: Int
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

        /// What the row reads: "Me" for your own voice, and "Add “Jo”" for a
        /// typed name that would become someone new.
        var displayTitle: String {
            switch self {
            case .saved(let label): return label == SpeakerNameSelectionPolicy.ownerLabel ? "Me" : label
            case .newPerson(let label): return "Add \u{201C}\(label)\u{201D}"
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
        /// "All me" is on: every local mic voice saves as You.
        case keptAsYou
        /// "Not a person": not saved to People. The transcript stays saved.
        case discarded
    }

    /// Which lock a voice is under. Keep as You covers every local mic voice
    /// and wins over a discard, the same as the review window.
    static func lock(isMic: Bool, keepMicAsYou: Bool, discarded: Bool) -> Lock? {
        if isMic, keepMicAsYou { return .keptAsYou }
        return discarded ? .discarded : nil
    }

    /// The local mic section's toggle, shown only when local mic voices are asked about.
    static func keepAsYouTitle(keepMicAsYou: Bool) -> String {
        keepMicAsYou ? "Undo" : "All me"
    }

    static func keepAsYouHelp(keepMicAsYou: Bool) -> String {
        keepMicAsYou
            ? "Name each local mic voice again."
            : "Use one \u{201C}You\u{201D} label for everyone picked up by the local microphone."
    }

    /// VoiceOver names for the two Undo buttons, which look the same.
    static func keepAsYouAccessibilityLabel(keepMicAsYou: Bool) -> String {
        keepMicAsYou ? "Undo All me" : "All me"
    }

    static let undoDiscardAccessibilityLabel = "Undo Not a person"

    /// The per-voice discard button.
    static func discardTitle(discarded: Bool) -> String {
        discarded ? "Undo" : "Not a person"
    }

    static let discardHelp = "Do not save this voice to People. The transcript stays saved."

    /// What the small × says when the pointer rests on it.
    static let discardTooltip = "Don\u{2019}t save this voice"

    /// The line a locked voice shows in place of its question.
    static func lockNote(_ lock: Lock) -> String {
        switch lock {
        case .keptAsYou: return "Saved as You"
        case .discarded: return "Not saved to People"
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
        return suggestions.firstIndex {
            SpeakerNameSelectionPolicy.normalizedSearchText($0.label) == key
                || ($0.label == SpeakerNameSelectionPolicy.ownerLabel && key == "me")
        }
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
    /// A recognized voice with its name box open ("Not Taylor?", mid-answer)
    /// holds it too: closing would save a half-typed name.
    static func hardCapClosesNow(hovered: Bool, answering: Bool) -> Bool {
        !hovered && !answering
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

    /// Keys of the voices Transcripted named on its own (silently) in this
    /// review, for `meeting_speaker_match_reviewed`'s `auto_recognized`: a
    /// correction on one of these is a wrong silent name. Matches
    /// `entriesByKey`, where an asked voice wins a shared key.
    static func autoRecognizedKeys<Entry>(
        asked: [Entry],
        recognized: [Entry],
        key: (Entry) -> String
    ) -> Set<String> {
        Set(recognized.map(key)).subtracting(asked.map(key))
    }

    /// `auto_recognized` as the analytics string.
    static func autoRecognizedProperty(updateKey: String, autoRecognizedKeys: Set<String>) -> String {
        autoRecognizedKeys.contains(updateKey) ? "true" : "false"
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
            return ("Everyone’s named", "After a few confirmed meetings, Transcripted names them on its own.")
        }
        return ("Names saved", "\(leftForLater) left to name in Speakers.")
    }

    /// The header: the same short question whether the review asks or only
    /// lists who was on the call.
    static let headerTitle = "Who spoke?"

    /// The meeting's name, small and grey on the header's right, or nil.
    static func headerDetail(meetingTitle: String?) -> String? {
        let trimmed = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The review's VoiceOver name: the question, then the meeting.
    static func accessibilityTitle(meetingTitle: String?) -> String {
        headerDetail(meetingTitle: meetingTitle).map { "\(headerTitle) \($0)" } ?? headerTitle
    }
}
