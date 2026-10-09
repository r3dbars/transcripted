// NotchIslandVoiceRowView+Naming.swift
// Naming a voice in place: the title-as-name-field's typing, arrows, Return /
// Tab / Esc, the 1:1 calendar name, picking a chip or a suggestion, and the
// `SpeakerReviewUpdate` the row hands back on Done or Later (the same one the
// review window built).

import AppKit
import TranscriptedCore

@available(macOS 14.0, *)
extension NotchIslandVoiceRowView {
    func wireNameField() {
        nameField.delegate = self
        nameField.onFocusRequest = { [weak self] in
            self?.onInteract?()
            self?.onWantsKeyboard?()
        }
        titleField.onFocusChange = { [weak self] _ in self?.focusChanged() }
    }

    /// The chips fade in while the field has the keyboard and nothing is
    /// typed. Only rebuild under the field when that changes, so a click on
    /// a suggestion never loses its button mid-click.
    private func focusChanged() {
        guard isEditing, lock == nil else { return }
        let wantsChips = Policy.showsInviteeChips(typed: nameField.stringValue, focused: titleField.isFocused)
        guard wantsChips != showsChips else { return }
        rebuildBelow()
        onChange?()
    }

    var currentSuggestions: [Policy.Suggestion] {
        Policy.suggestions(
            query: nameField.stringValue,
            people: knownPeople,
            invitees: invitees,
            includeOwner: isMic
        )
    }

    /// Fills the open, empty name field with the calendar 1:1 name, as the
    /// review window did: under a saved person's label when exactly one saved
    /// person has that name, else as typed. Still editable; it saves on Done
    /// like a typed name. Returns whether the field was filled.
    @discardableResult
    func prefill(_ name: String) -> Bool {
        guard !isRecognized, isEditing, answer == .none, lock == nil,
              nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let label = MeetingInviteeSuggestionPolicy.suggestionLabels(
            inviteeNames: [name],
            labels: knownPeople.map { $0.label },
            optionsByLabel: knownPeopleByLabel,
            displayName: { $0.displayName }
        ).first ?? name
        nameField.stringValue = label
        highlightedRow = nil
        prefilledUntouched = true
        rebuild(animated: false)
        return true
    }

    /// A chip, a suggestion, or Return: name the voice. Picking the
    /// suggested or recognized person is the same as ✓ / keeping them.
    func pick(_ label: String) {
        onInteract?()
        stopClipIfPlaying()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isRecognized, Self.sameName(trimmed, entry.currentName) {
            keepRecognized()
            return
        }
        if case .confirm(let suggested) = question,
           Self.sameName(trimmed, suggested),
           entry.currentName != nil {
            confirm()
            return
        }
        answer = .named(trimmed)
        namedTarget = target(forNamed: trimmed)
        isEditing = false
        clearField()
        endEditingIfNeeded()
        rebuild()
        commitAnswer(celebrate: true)
        onSubmit?()
    }

    /// Who the name saves as, read from the update Core will get: a merge
    /// into someone in Speakers, "Me", or a new person under this voice.
    private func target(forNamed label: String) -> (kind: Policy.NamedAs, personID: UUID?) {
        if label == SpeakerNameSelectionPolicy.ownerLabel { return (.owner, nil) }
        switch namedUpdate(label)?.action {
        case .merged(let target)?: return (.savedPerson, target)
        case .collapsedToMe?: return (.owner, nil)
        default: return (.newPerson, nil)
        }
    }

    static func sameName(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return SpeakerNameSelectionPolicy.normalizedSearchText(a) == SpeakerNameSelectionPolicy.normalizedSearchText(b)
    }

    // MARK: The saved answer

    /// The same `SpeakerReviewUpdate` the review window would build for this
    /// row, or nil when the voice was left unnamed (or, for a recognized
    /// voice, left as it was). A name still sitting in an open field counts,
    /// read the way Return would read it, except an untouched calendar name
    /// on Later. All me and Not a person win over any name, and build
    /// the window's `.collapsedToMe` and `.discardedFromDatabase` updates.
    func buildUpdate(finish: Policy.Finish) -> SpeakerReviewUpdate? {
        if let lock {
            switch lock {
            case .keptAsYou:
                return SpeakerReviewUpdate(
                    persistentSpeakerId: entry.id,
                    diarizerSpeakerId: entry.diarizerSpeakerId,
                    channel: SpeakerReviewBridge.channel(entry.channel),
                    newName: "You",
                    previousName: entry.currentName,
                    action: .collapsedToMe
                )
            case .discarded:
                return SpeakerReviewUpdate(
                    persistentSpeakerId: entry.id,
                    diarizerSpeakerId: entry.diarizerSpeakerId,
                    channel: SpeakerReviewBridge.channel(entry.channel),
                    newName: entry.currentName ?? "Speaker \(entry.diarizerSpeakerId)",
                    previousName: entry.currentName,
                    action: .discardedFromDatabase
                )
            }
        }
        switch answer {
        case .confirmed:
            return confirmedUpdate()
        case .named(let label):
            return namedUpdate(label)
        case .none, .rejected:
            guard isEditing,
                  let pending = Policy.answerOnFinish(
                    committed: nil,
                    typed: nameField.stringValue,
                    suggestions: currentSuggestions,
                    highlighted: highlightedRow,
                    typedIsUntouchedPrefill: prefilledUntouched,
                    finish: finish
                  ) else { return nil }
            if isRecognized, Self.sameName(pending, entry.currentName) { return nil }
            if case .confirm(let suggested) = question, Self.sameName(pending, suggested) {
                return confirmedUpdate()
            }
            return namedUpdate(pending)
        }
    }

    private func confirmedUpdate() -> SpeakerReviewUpdate? {
        guard let current = entry.currentName, !current.isEmpty else { return nil }
        if let suggestedProfileId = entry.suggestedProfileId {
            return SpeakerReviewUpdate(
                persistentSpeakerId: entry.id,
                diarizerSpeakerId: entry.diarizerSpeakerId,
                channel: SpeakerReviewBridge.channel(entry.channel),
                newName: current,
                action: .merged(targetProfileId: suggestedProfileId)
            )
        }
        return SpeakerReviewUpdate(
            persistentSpeakerId: entry.id,
            diarizerSpeakerId: entry.diarizerSpeakerId,
            channel: SpeakerReviewBridge.channel(entry.channel),
            newName: current,
            previousName: current,
            action: .confirmed
        )
    }

    /// A typed or picked name. On a recognized voice this is a correction:
    /// a new name saves as `.corrected`, and a saved person as a merge that
    /// the naming coordinator turns into a correction of the recognized
    /// person (their match is undone and disputed, the pick learns the voice).
    private func namedUpdate(_ label: String) -> SpeakerReviewUpdate? {
        SpeakerReviewBridge.typedNameUpdate(
            entry: entry,
            typedName: label,
            optionsByLabel: knownPeopleByLabel
        )
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        onInteract?()
        highlightedRow = nil
        clearPrefillNote()
        refreshSuggestions()
    }

    /// Typing over the calendar name makes it the person's own answer.
    private func clearPrefillNote() {
        guard prefilledUntouched else { return }
        prefilledUntouched = false
        if isEditing {
            rebuildTextColumn(animated: false)
            refreshAccessibility()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // The row arrowed to, else an exact match, else what was typed
            // as a new person. Never a longer saved name nobody picked.
            guard let name = Policy.nameToSave(
                typed: nameField.stringValue,
                suggestions: currentSuggestions,
                highlighted: highlightedRow
            ) else {
                return commandSelector == #selector(NSResponder.insertNewline(_:))
            }
            pick(name)
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            guard let moved = Policy.movedHighlight(
                from: highlightedRow,
                by: delta,
                typed: nameField.stringValue,
                suggestions: currentSuggestions
            ) else { return false }
            highlightedRow = moved
            refreshSuggestions()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            nameField.stringValue = ""
            highlightedRow = nil
            clearPrefillNote()
            refreshSuggestions()
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// Only what's under the field changes while typing, so the field keeps
    /// the keyboard and the caret.
    func refreshSuggestions() {
        guard isEditing, lock == nil else { return }
        rebuildBelow()
        onChange?()
    }
}
