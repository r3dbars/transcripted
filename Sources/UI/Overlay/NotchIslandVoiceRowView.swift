// NotchIslandVoiceRowView.swift
// One voice in the notch island's speaker review: recognized, suggested, or
// asking for a name. Split from NotchIslandSpeakerReviewView.swift; behavior unchanged.

import AppKit
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class NotchIslandVoiceRowView: NSView, NSTextFieldDelegate {
    enum Answer: Equatable {
        case none
        /// Yes to "Is this …?"
        case confirmed
        /// No to the suggestion, or "Not Taylor?" on a recognized voice
        /// (the name box opens).
        case rejected
        /// A name typed or picked for this voice.
        case named(String)
    }

    var onChange: (() -> Void)?
    var onInteract: (() -> Void)?
    var onWantsKeyboard: (() -> Void)?
    var onSubmit: (() -> Void)?

    private let entry: SpeakerNamingEntry
    private let question: NotchIslandSpeakerReviewPolicy.Question
    /// Named on its own in this meeting: shown as recognized, corrected on
    /// hover, never asked about.
    private let isRecognized: Bool
    private let knownPeopleByLabel: [String: SpeakerNameChoice]
    private let knownPeople: [(label: String, callCount: Int)]
    private var answer: Answer = .none
    private var isEditing = false
    private var showAllInvitees = false
    private var invitees: [String] = []
    private var usedNames: Set<String> = []
    /// The row under the name box the arrows moved to; nil means the
    /// default (an exact match, else the typed name as a new person).
    private var highlightedRow: Int?
    private var isPointerInside = false
    private var hoverArea: NSTrackingArea?
    /// "Not a person": not saved to People.
    private var isDiscarded = false
    /// "All me" is on for this local mic voice.
    private var isKeptAsYou = false
    /// The name box holds the calendar 1:1 name and nobody has touched it.
    private var prefilledUntouched = false

    private let stack = NSStackView()
    private let clip: NotchIslandClipButton
    private lazy var nameField: NotchIslandNameField = {
        let field = NotchIslandNameField()
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: NotchIslandSpeakerReviewView.contentWidth - 60).isActive = true
        field.heightAnchor.constraint(equalToConstant: 30).isActive = true
        field.onFocusRequest = { [weak self] in
            self?.onInteract?()
            self?.onWantsKeyboard?()
        }
        return field
    }()

    init(entry: SpeakerNamingEntry, knownPeople: [SpeakerNameChoice], recognized: Bool = false) {
        self.entry = entry
        self.isRecognized = recognized && !(entry.currentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        self.question = NotchIslandSpeakerReviewPolicy.question(
            currentName: entry.currentName,
            needsConfirmation: entry.needsConfirmation
        )
        let labels = SpeakerNameSelectionPolicy.makeIdentityLabels(
            for: knownPeople.filter { $0.id != entry.id },
            id: { $0.id },
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        self.knownPeopleByLabel = labels.lookup
        self.knownPeople = labels.labels.map { ($0, labels.lookup[$0]?.callCount ?? 0) }
        self.clip = NotchIslandClipButton(clipURL: entry.clipURL)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: NotchIslandSpeakerReviewView.contentWidth).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        clip.onPress = { [weak self] in self?.onInteract?() }
        if case .name = question, !isRecognized { isEditing = true }
        rebuild()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        if isRecognized, let name = entry.currentName {
            // VoiceOver can't hover: offer the correction as an action.
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: NotchIslandSpeakerReviewPolicy.correctionPrompt(name: name)) { [weak self] in
                    self?.reject()
                    return true
                },
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var isMic: Bool { entry.channel == .mic }

    /// The voice came with a suggested name (the window's `hasSuggestedName`).
    var hasSuggestedName: Bool {
        !(entry.currentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var lock: NotchIslandSpeakerReviewPolicy.Lock? {
        NotchIslandSpeakerReviewPolicy.lock(isMic: isMic, keepMicAsYou: isKeptAsYou, discarded: isDiscarded)
    }

    var isAnswered: Bool {
        if lock != nil { return true }
        switch answer {
        case .confirmed, .named: return true
        case .none: return isRecognized
        case .rejected: return false
        }
    }

    /// The name this voice has been given here, so invitee chips don't
    /// offer the same person twice.
    var chosenName: String? {
        if lock != nil { return nil }
        switch answer {
        case .confirmed: return entry.currentName
        case .named(let label): return knownPeopleByLabel[label]?.displayName ?? label
        case .none: return isRecognized ? entry.currentName : nil
        case .rejected: return nil
        }
    }

    func setInvitees(_ names: [String], alreadyUsed: Set<String>) {
        let own = chosenName.map { Set([$0]) } ?? []
        let used = alreadyUsed.subtracting(own)
        guard names != invitees || used != usedNames else { return }
        invitees = names
        usedNames = used
        if isEditing { rebuild() }
    }

    func beginNamingIfNeeded() {
        guard !isAnswered else { return }
        isEditing = true
        rebuild()
        onChange?()
        focusField()
    }

    /// Fills the open, empty name box with the calendar 1:1 name, as the
    /// review window did: under a saved person's label when exactly one saved
    /// person has that name, else as typed. Still editable; it saves on Done
    /// like a typed name. Returns whether the box was filled.
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
        rebuild()
        return true
    }

    /// "All me" was switched on or off for the local mic voices.
    func setKeptAsYou(_ kept: Bool) {
        guard isMic, kept != isKeptAsYou else { return }
        isKeptAsYou = kept
        if kept, let editor = nameField.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
        rebuild()
    }

    /// "Not a person" / "Undo".
    private func toggleDiscard() {
        onInteract?()
        guard !isKeptAsYou else { return }
        isDiscarded.toggle()
        if isDiscarded {
            stopClipIfPlaying()
            if let editor = nameField.currentEditor(), window?.firstResponder === editor {
                window?.makeFirstResponder(nil)
            }
        }
        rebuild()
        onChange?()
    }

    // MARK: Hover (recognized voices)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard isRecognized else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerInside(false)
    }

    private func setPointerInside(_ inside: Bool) {
        guard isRecognized, inside != isPointerInside else { return }
        isPointerInside = inside
        // Only the resting "recognized" line changes on hover.
        guard answer == .none, !isEditing else { return }
        replaceTopLine()
    }

    // MARK: Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(topLine())
        // A voice kept as You or discarded shows only its note, dimmed like the window's.
        alphaValue = lock == nil ? 1 : 0.62
        if isEditing, lock == nil {
            let field = fieldLine()
            stack.addArrangedSubview(field)
            if let chips = inviteeLine() { stack.addArrangedSubview(chips) }
            let suggestions = suggestionList()
            if let suggestions { stack.addArrangedSubview(suggestions) }
        }
        setAccessibilityLabel(accessibilitySummary)
        needsLayout = true
    }

    private func replaceTopLine() {
        guard let first = stack.arrangedSubviews.first else { return rebuild() }
        stack.removeArrangedSubview(first)
        first.removeFromSuperview()
        stack.insertArrangedSubview(topLine(), at: 0)
        needsLayout = true
    }

    private func topLine() -> NSView {
        var views: [NSView] = [clip]
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        switch (answer, question) {
        case _ where lock != nil:
            text.addArrangedSubview(title(lock.map(NotchIslandSpeakerReviewPolicy.lockNote) ?? ""))
            text.addArrangedSubview(caption(quote))
        case (.confirmed, _):
            text.addArrangedSubview(title(entry.currentName ?? "Confirmed"))
            text.addArrangedSubview(caption("confirmed"))
        case (.named(let label), _):
            text.addArrangedSubview(title(knownPeopleByLabel[label]?.displayName ?? label))
            text.addArrangedSubview(caption(isRecognized ? "corrected" : "named"))
        case (.none, _) where isRecognized:
            text.addArrangedSubview(title(entry.currentName ?? ""))
            text.addArrangedSubview(caption("recognized"))
        case (_, .confirm(let name)) where answer == .none:
            text.addArrangedSubview(title("Is this \(name)?"))
            text.addArrangedSubview(caption(quote))
        default:
            text.addArrangedSubview(title(isEditing ? "Who is this?" : "Unknown voice"))
            text.addArrangedSubview(caption(prefilledUntouched ? NotchIslandSpeakerReviewPolicy.prefillNote : quote))
        }
        views.append(text)
        views.append(NSView())

        switch (answer, question) {
        case _ where lock == .keptAsYou:
            break
        case _ where lock == .discarded:
            let undo = pill(NotchIslandSpeakerReviewPolicy.discardTitle(discarded: true), style: .subtle) { [weak self] in
                self?.toggleDiscard()
            }
            undo.setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.undoDiscardAccessibilityLabel)
            undo.setAccessibilityHelp("Save this voice to People after all.")
            views.append(undo)
        case (.none, _) where isRecognized:
            if isPointerInside, let name = entry.currentName {
                let correct = pill(NotchIslandSpeakerReviewPolicy.correctionPrompt(name: name), style: .subtle) { [weak self] in
                    self?.reject()
                }
                correct.setAccessibilityHelp("Correct the name Transcripted gave this voice.")
                views.append(correct)
            } else {
                views.append(checkmark())
            }
        case (.rejected, _) where isRecognized:
            if let name = entry.currentName {
                let keep = pill("Keep \(Self.firstName(name))", style: .subtle) { [weak self] in
                    self?.keepRecognized()
                }
                keep.setAccessibilityHelp("It was \(name) after all.")
                views.append(keep)
            }
        case (.none, .confirm):
            views.append(pill("No", style: .plain) { [weak self] in self?.reject() })
            views.append(pill("Yes", style: .accent) { [weak self] in self?.confirm() })
        case (.confirmed, _), (.named, _):
            views.append(pill("Change", style: .subtle) { [weak self] in self?.change() })
        default:
            if NotchIslandSpeakerReviewPolicy.offersDiscard(isRecognized: isRecognized, nameBoxOpen: isEditing, keptAsYou: isKeptAsYou) {
                views.append(NotchIslandDiscardControl { [weak self] in self?.toggleDiscard() })
            }
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: NotchIslandSpeakerReviewView.contentWidth - 20).isActive = true
        // Same height whether the hover pill or the check shows.
        line.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        return line
    }

    private func checkmark() -> NSView {
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold)) ?? NSImage())
        check.contentTintColor = NotchIslandPalette.secondaryText
        check.setContentHuggingPriority(.required, for: .horizontal)
        return check
    }

    private static func firstName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
    }

    private func fieldLine() -> NSView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let line = NSStackView(views: [spacer, nameField])
        line.orientation = .horizontal
        line.spacing = 10
        return line
    }

    private func inviteeLine() -> NSView? {
        guard NotchIslandSpeakerReviewPolicy.showsInviteeChips(typed: nameField.stringValue) else { return nil }
        var names = NotchIslandSpeakerReviewPolicy.inviteeChips(
            invitees: invitees,
            alreadyUsed: usedNames,
            showAll: showAllInvitees
        )
        if entry.channel == .mic {
            // Your own mic: "Me" is always one tap away.
            names.shown.insert(SpeakerNameSelectionPolicy.ownerLabel, at: 0)
        }
        guard !names.shown.isEmpty else { return nil }
        var views: [NSView] = []
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 30).isActive = true
        views.append(spacer)
        for name in names.shown {
            let chip = pill(name == SpeakerNameSelectionPolicy.ownerLabel ? "Me" : name, style: .plain, height: 26, fontSize: 12) { [weak self] in
                self?.pick(name)
            }
            chip.setAccessibilityHelp(name == SpeakerNameSelectionPolicy.ownerLabel
                ? "This is your own voice."
                : "\(name) was on the calendar invite.")
            views.append(chip)
        }
        if names.hidden > 0 {
            let more = pill("›", style: .plain, height: 26, fontSize: 13) { [weak self] in
                self?.showAllInvitees = true
                self?.rebuild()
                self?.onChange?()
            }
            more.setAccessibilityLabel("Show \(names.hidden) more invitees")
            views.append(more)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.spacing = 6
        return line
    }

    private func suggestionList() -> NSView? {
        let typed = nameField.stringValue
        let suggestions = currentSuggestions
        let rows = NotchIslandSpeakerReviewPolicy.nameBoxRows(typed: typed, suggestions: suggestions)
        guard !rows.isEmpty else { return nil }
        let highlighted = highlightedRow ?? NotchIslandSpeakerReviewPolicy.defaultHighlight(typed: typed, suggestions: suggestions)
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        list.wantsLayer = true
        list.layer?.backgroundColor = NotchIslandPalette.buttonSubtle.cgColor
        list.layer?.cornerRadius = 10
        let width = NotchIslandSpeakerReviewView.contentWidth - 60
        let details = Dictionary(suggestions.map { ($0.label, $0.detail) }, uniquingKeysWith: { first, _ in first })
        for (index, row) in rows.enumerated() {
            let detail: String
            switch row {
            case .saved(let label): detail = details[label] ?? ""
            case .newPerson: detail = "new person"
            }
            list.addArrangedSubview(suggestionRow(row, detail: detail, highlighted: index == highlighted, width: width - 8))
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalToConstant: width).isActive = true
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let line = NSStackView(views: [spacer, list])
        line.orientation = .horizontal
        line.spacing = 10
        line.alignment = .top
        return line
    }

    private func suggestionRow(_ row: NotchIslandSpeakerReviewPolicy.NameBoxRow, detail: String, highlighted: Bool, width: CGFloat) -> NSView {
        let button = NotchIslandSuggestionButton(title: row.displayTitle, detail: detail, width: width)
        button.isHighlightedRow = highlighted
        button.onPress = { [weak self] in self?.pick(row.label) }
        return button
    }

    private var currentSuggestions: [NotchIslandSpeakerReviewPolicy.Suggestion] {
        NotchIslandSpeakerReviewPolicy.suggestions(
            query: nameField.stringValue,
            people: knownPeople,
            invitees: invitees,
            includeOwner: entry.channel == .mic
        )
    }

    private var quote: String {
        let text = entry.sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Play to hear this voice." }
        let short = text.count > 60 ? String(text.prefix(58)) + "…" : text
        return "“\(short)”"
    }

    private func title(_ text: String) -> NSTextField {
        let label = NotchIslandPalette.label(text, font: .systemFont(ofSize: 14, weight: .semibold), color: NotchIslandPalette.primaryText)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NotchIslandPalette.label(text, font: .systemFont(ofSize: 11), color: NotchIslandPalette.secondaryText)
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        return label
    }

    private func pill(
        _ title: String,
        style: NotchIslandButton.Style,
        height: CGFloat = 28,
        fontSize: CGFloat = 13,
        action: @escaping () -> Void
    ) -> NotchIslandButton {
        let button = NotchIslandButton(title: title, style: style, height: height, fontSize: fontSize)
        button.onPress = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private var accessibilitySummary: String {
        if let lock { return NotchIslandSpeakerReviewPolicy.lockNote(lock) }
        switch (answer, question) {
        case (.confirmed, _): return "\(entry.currentName ?? "Voice"), confirmed"
        case (.named(let label), _):
            return "\(knownPeopleByLabel[label]?.displayName ?? label), \(isRecognized ? "corrected" : "named")"
        case (.none, _) where isRecognized: return "\(entry.currentName ?? "Voice"), recognized"
        case (.none, .confirm(let name)): return "Is this \(name)?"
        default: return "Unnamed voice"
        }
    }

    // MARK: Answers

    /// Answering a voice ends its clip, so the next one is ready to play.
    private func stopClipIfPlaying() {
        if SpeakerClipPlayback.isPlaying(entry.clipURL) {
            SpeakerClipPlayback.stop()
        }
    }

    private func confirm() {
        onInteract?()
        stopClipIfPlaying()
        answer = .confirmed
        isEditing = false
        rebuild()
        onChange?()
        onSubmit?()
    }

    private func reject() {
        onInteract?()
        answer = .rejected
        isEditing = true
        nameField.stringValue = ""
        highlightedRow = nil
        prefilledUntouched = false
        rebuild()
        onChange?()
        focusField()
    }

    /// "Keep Taylor": the recognized name was right after all.
    private func keepRecognized() {
        onInteract?()
        answer = .none
        isEditing = false
        nameField.stringValue = ""
        highlightedRow = nil
        prefilledUntouched = false
        window?.makeFirstResponder(nil)
        rebuild()
        onChange?()
    }

    private func change() {
        onInteract?()
        answer = (question == .name && !isRecognized) ? .none : .rejected
        isEditing = true
        nameField.stringValue = ""
        highlightedRow = nil
        prefilledUntouched = false
        rebuild()
        onChange?()
        focusField()
    }

    private func pick(_ label: String) {
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
        isEditing = false
        nameField.stringValue = ""
        highlightedRow = nil
        prefilledUntouched = false
        window?.makeFirstResponder(nil)
        rebuild()
        onChange?()
        onSubmit?()
    }

    private static func sameName(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return SpeakerNameSelectionPolicy.normalizedSearchText(a) == SpeakerNameSelectionPolicy.normalizedSearchText(b)
    }

    private func focusField() {
        onWantsKeyboard?()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditing, let window = self.nameField.window else { return }
            window.makeFirstResponder(self.nameField)
        }
    }

    /// The same `SpeakerReviewUpdate` the review window would build for this
    /// row, or nil when the voice was left unnamed (or, for a recognized
    /// voice, left as it was). A name still sitting in an open box counts,
    /// read the way Return would read it, except an untouched calendar name
    /// on Later. All me and Not a person win over any name, and build
    /// the window's `.collapsedToMe` and `.discardedFromDatabase` updates.
    func buildUpdate(finish: NotchIslandSpeakerReviewPolicy.Finish) -> SpeakerReviewUpdate? {
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
                  let pending = NotchIslandSpeakerReviewPolicy.answerOnFinish(
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
        if isEditing { replaceTopLine() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // The row arrowed to, else an exact match, else what was typed
            // as a new person. Never a longer saved name nobody picked.
            guard let name = NotchIslandSpeakerReviewPolicy.nameToSave(
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
            guard let moved = NotchIslandSpeakerReviewPolicy.movedHighlight(
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

    /// Only the list under the box changes while typing, so the box keeps
    /// focus and the caret.
    private func refreshSuggestions() {
        guard isEditing, lock == nil else { return }
        // Keep the top line and the name box; redo the invitees and the list.
        while stack.arrangedSubviews.count > 2 {
            stack.arrangedSubviews.last?.removeFromSuperview()
        }
        if let chips = inviteeLine() { stack.addArrangedSubview(chips) }
        if let list = suggestionList() { stack.addArrangedSubview(list) }
        onChange?()
    }
}
