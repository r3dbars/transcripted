// NotchIslandVoiceRowView.swift
// One voice in the notch island's "Who spoke?" review (Prints.dc.html): the
// person's voice print on the left with play in its middle, then the title
// (a name, "Marcus Reed?", or the name field itself), the short line under
// it, and its buttons. What shows comes from NotchIslandSpeakerReviewPolicy;
// layout is +Layout, typing and the saved answer are +Naming.
//
// The print stands for whoever the row claims: the suggested or recognized
// person, a name picked in place, or (unclaimed) the voice itself, unlit. ✓ and
// naming a new voice play the match animation (VoicePrintView.celebrate); Undo
// cancels it and puts the print back.

import AppKit
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class NotchIslandVoiceRowView: NSView, NSTextFieldDelegate {
    typealias Policy = NotchIslandSpeakerReviewPolicy

    enum Answer: Equatable {
        case none
        /// ✓ on "Marcus Reed?"
        case confirmed
        /// ✕ on the suggestion, or "Not Taylor?" on a recognized voice (the
        /// title becomes the name field).
        case rejected
        /// A name typed or picked for this voice.
        case named(String)
    }

    var onChange: (() -> Void)?
    var onInteract: (() -> Void)?
    var onWantsKeyboard: (() -> Void)?
    var onSubmit: (() -> Void)?
    /// The pointer rests on the print (its explanation) or left it (nil).
    var onPrintTip: ((_ text: String?, _ anchor: NSView) -> Void)?

    let entry: SpeakerNamingEntry
    let question: Policy.Question
    /// Named on its own in this meeting: shown by name, corrected on hover,
    /// never asked about.
    let isRecognized: Bool
    let knownPeopleByLabel: [String: SpeakerNameChoice]
    let knownPeople: [(label: String, callCount: Int)]
    /// The suggested person's progress before this review, from Core.
    let entryProgress: Policy.Progress?

    /// Progress of whoever the row claims: the person picked in place when the
    /// voice was named as someone already saved, else the suggested person.
    var progress: Policy.Progress? {
        if case .named(.savedPerson) = rowState, let id = namedTarget?.personID,
           let picked = knownPeopleByLabel.values.first(where: { $0.id == id }) {
            return Policy.Progress(confirmed: picked.confirmedMeetings, required: SpeakerNamingPolicy.requiredConfirmedMeetings, isTrusted: picked.isTrusted, earnsConfirmation: picked.earnsConfirmation)
        }
        return entryProgress
    }
    var answer: Answer = .none
    /// Who a typed or picked name turned out to be, and their saved ID.
    var namedTarget: (kind: Policy.NamedAs, personID: UUID?)?
    var isEditing = false
    var showAllInvitees = false
    var invitees: [String] = []
    var usedNames: Set<String> = []
    /// The row under the name field the arrows moved to; nil means the
    /// default (an exact match, else the typed name as a new person).
    var highlightedRow: Int?
    var isPointerInside = false
    var hoverArea: NSTrackingArea?
    /// "Not a person": not saved to People.
    var isDiscarded = false
    /// "All me" is on for this local mic voice.
    var isKeptAsYou = false
    /// The name field holds the calendar 1:1 name and nobody has touched it.
    var prefilledUntouched = false
    /// Palette index for this row's person on this call; the review assigns
    /// it so nobody on the call shares a color.
    private(set) var colorIndex: Int
    /// An answer is being applied: the review recolors before the print
    /// celebrates, so color pushes wait for it.
    var isApplyingAnswer = false
    /// The hint shown last, so a new one rises in and a repeat doesn't.
    var shownHint: String?
    /// The line under the title, recolored when the person's color changes.
    var hintLabel: NSTextField?
    var hintUsesPersonColor = false
    /// Whether the invitee chips were showing, so focus changes only rebuild
    /// what's under the field when that changes.
    var showsChips = false
    private var playbackObserver: NSObjectProtocol?

    let stack = NSStackView()
    let topLine = NSStackView()
    let textColumn = NSStackView()
    let controls = NSStackView()
    let printSlot: NotchIslandPrintSlot
    let titleField = NotchIslandTitleField()
    lazy var titleFieldHolder: NSView = makeTitleFieldHolder()
    var nameField: NotchIslandNameField { titleField.field }

    static let printDiameter: CGFloat = 42
    static let printGap: CGFloat = 14
    /// Chips and the list sit under the title, past the print.
    static var belowIndent: CGFloat { printDiameter + printGap }

    init(entry: SpeakerNamingEntry, knownPeople: [SpeakerNameChoice], recognized: Bool = false, colorIndex: Int = 0) {
        self.entry = entry
        self.isRecognized = recognized && !(entry.currentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        self.question = Policy.question(currentName: entry.currentName, needsConfirmation: entry.needsConfirmation)
        let labels = SpeakerNameSelectionPolicy.makeIdentityLabels(
            for: knownPeople.filter { $0.id != entry.id },
            id: { $0.id },
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        self.knownPeopleByLabel = labels.lookup
        self.knownPeople = labels.labels.map { ($0, labels.lookup[$0]?.callCount ?? 0) }
        self.entryProgress = entry.confirmationProgress.map {
            Policy.Progress(confirmed: $0.confirmedMeetings, required: $0.requiredMeetings, isTrusted: $0.isTrusted, earnsConfirmation: $0.earnsConfirmation)
        }
        self.colorIndex = colorIndex
        self.printSlot = NotchIslandPrintSlot(print: VoicePrintView(
            diameter: Self.printDiameter,
            model: VoicePrintView.Model(style: VoicePrintStyle(id: entry.id), colorIndex: colorIndex, litRings: 0, surface: .island)
        ))
        super.init(frame: .zero)
        if case .name = question, !isRecognized { isEditing = true }
        buildSkeleton()
        wirePrint()
        wireNameField()
        rebuild(animated: false)
        applyPrint(celebrate: false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        if isRecognized, let name = entry.currentName {
            // VoiceOver can't hover: offer the correction as an action.
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: Policy.correctionPrompt(name: name)) { [weak self] in
                    self?.reject()
                    return true
                },
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let playbackObserver { NotificationCenter.default.removeObserver(playbackObserver) }
    }

    override var isFlipped: Bool { true }

    // MARK: State

    var isMic: Bool { entry.channel == .mic }

    /// The voice came with a suggested name (the window's `hasSuggestedName`).
    var hasSuggestedName: Bool {
        !(entry.currentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var lock: Policy.Lock? {
        Policy.lock(isMic: isMic, keepMicAsYou: isKeptAsYou, discarded: isDiscarded)
    }

    var rowState: Policy.RowState {
        if let lock { return .locked(lock) }
        switch answer {
        case .confirmed: return .confirmed
        case .named: return .named(namedTarget?.kind ?? .newPerson)
        case .rejected: return .naming(isRecognized ? .correctingRecognized : .rejectedSuggestion)
        case .none:
            if isRecognized { return .recognized }
            if case .confirm = question { return .asking }
            return .naming(.unknownVoice)
        }
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
        case .named(let label): return displayName(for: label)
        case .none: return isRecognized ? entry.currentName : nil
        case .rejected: return nil
        }
    }

    /// The name the row shows for its person, if it claims one.
    var shownName: String? {
        switch rowState {
        case .asking, .confirmed, .recognized: return entry.currentName
        case .named: if case .named(let label) = answer { return displayName(for: label) } else { return nil }
        case .naming, .locked: return nil
        }
    }

    func displayName(for label: String) -> String {
        knownPeopleByLabel[label]?.displayName ?? label
    }

    /// The saved person this row's print stands for, when it claims one
    /// (for the review's color assignment).
    var claimedPersonID: UUID? {
        Policy.claimsPerson(rowState) ? printOwnerID : nil
    }

    var printOwnerID: UUID {
        Policy.printOwner(rowState, voiceID: entry.id, suggestedID: entry.suggestedProfileId, pickedID: namedTarget?.personID)
    }

    /// Counted in the footer's "N people named automatically".
    var isNamedAutomatically: Bool {
        Policy.namedAutomatically(rowState, progress: progress)
    }

    /// The person's color on this call.
    var personColor: NSColor {
        NSColor(cgColor: VoicePrintInk.personColor(colorIndex: colorIndex, tone: .dark).cgColor) ?? .white
    }

    // MARK: Inputs from the review

    func setColorIndex(_ index: Int) {
        guard index != colorIndex else { return }
        colorIndex = index
        guard !isApplyingAnswer else { return }
        applyPrint(celebrate: false)
        updateHintColor()
    }

    func setInvitees(_ names: [String], alreadyUsed: Set<String>) {
        let own = chosenName.map { Set([$0]) } ?? []
        let used = alreadyUsed.subtracting(own)
        guard names != invitees || used != usedNames else { return }
        invitees = names
        usedNames = used
        if isEditing { rebuildBelow() }
    }

    /// Moving on from the row above: open this row's name field and take
    /// the keyboard, but only when the title is the field. An asked row
    /// ("Marcus Reed?") has nothing to type into, so it's left alone.
    func beginNamingIfNeeded() {
        guard !isAnswered, Policy.takesKeyboardOnAdvance(rowState) else { return }
        isEditing = true
        rebuild()
        onChange?()
        focusField()
    }

    /// "All me" was switched on or off for the local mic voices.
    func setKeptAsYou(_ kept: Bool) {
        guard isMic, kept != isKeptAsYou else { return }
        isKeptAsYou = kept
        if kept { endEditingIfNeeded() }
        rebuild()
        applyPrint(celebrate: false)
    }

    // MARK: The print

    private func wirePrint() {
        let print = printSlot.print
        print.onPlay = { [weak self] in
            guard let self else { return }
            self.onInteract?()
            SpeakerClipPlayback.play(self.entry.clipURL)
            self.syncPlayback()
        }
        printSlot.onHover = { [weak self] inside in
            guard let self else { return }
            self.onPrintTip?(inside ? self.printExplanation : nil, self.printSlot)
        }
        playbackObserver = NotificationCenter.default.addObserver(
            forName: SpeakerClipPlayback.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPlayback() }
        }
        syncPlayback()
    }

    private func syncPlayback() {
        printSlot.print.isPlaying = SpeakerClipPlayback.isPlaying(entry.clipURL)
    }

    var printExplanation: String {
        Policy.printExplanation(rowState, name: shownName, progress: progress)
    }

    /// Shows the print for the row's state. With `celebrate`, a ✓ or a new
    /// name plays the match animation from the rings lit before up to the
    /// ones this answer earns.
    func applyPrint(celebrate: Bool) {
        let state = rowState
        let print = printSlot.print
        let target = VoicePrintView.Model(
            style: VoicePrintStyle(id: printOwnerID),
            colorIndex: colorIndex,
            litRings: Policy.litRings(state, progress: progress),
            surface: .island
        )
        if celebrate, Policy.celebrates(state), target.litRings > 0 {
            var before = target
            before.litRings = print.model.style == target.style ? min(print.model.litRings, target.litRings) : 0
            print.model = before
            print.celebrate(toLitRings: target.litRings)
        } else {
            print.model = target
        }
        let first = shownName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        print.accessibilityName = first
        print.setAccessibilityHelp(printExplanation)
    }

    /// An answer changed: let the review recolor and resize, then draw the
    /// print (celebrating when the answer earns it).
    func commitAnswer(celebrate: Bool) {
        isApplyingAnswer = true
        onChange?()
        isApplyingAnswer = false
        applyPrint(celebrate: celebrate)
        updateHintColor()
    }

    // MARK: Answers

    /// Answering a voice ends its clip, so the next one is ready to play.
    func stopClipIfPlaying() {
        if SpeakerClipPlayback.isPlaying(entry.clipURL) {
            SpeakerClipPlayback.stop()
        }
    }

    func confirm() {
        onInteract?()
        stopClipIfPlaying()
        endEditingIfNeeded()
        answer = .confirmed
        isEditing = false
        rebuild()
        commitAnswer(celebrate: true)
        onSubmit?()
    }

    func reject() {
        onInteract?()
        answer = .rejected
        namedTarget = nil
        isEditing = true
        clearField()
        rebuild()
        commitAnswer(celebrate: false)
        focusField()
    }

    /// "Undo" on a "Not Taylor?" field: the recognized name was right.
    func keepRecognized() {
        onInteract?()
        answer = .none
        namedTarget = nil
        isEditing = false
        clearField()
        endEditingIfNeeded()
        rebuild()
        commitAnswer(celebrate: false)
    }

    /// Where this row's name field comes from, for what Undo goes back to.
    var namingOrigin: Policy.NamingOrigin {
        if isRecognized { return .correctingRecognized }
        if case .confirm = question { return .rejectedSuggestion }
        return .unknownVoice
    }

    /// "Undo" after ✓, after ✕, or after a name: back to the question, or to
    /// the name field the name was typed into (Policy.undoTarget). A running
    /// match animation stops.
    func undo() {
        onInteract?()
        printSlot.print.cancelAnimations()
        switch Policy.undoTarget(rowState, origin: namingOrigin) {
        case .asking:
            answer = .none
            isEditing = false
        case .naming(.unknownVoice):
            answer = .none
            isEditing = true
        case .naming:
            answer = .rejected
            isEditing = true
        default:
            return
        }
        namedTarget = nil
        clearField()
        if !isEditing { endEditingIfNeeded() }
        rebuild()
        commitAnswer(celebrate: false)
        if isEditing { focusField() }
    }

    /// "Not a person" / "Undo".
    func toggleDiscard() {
        onInteract?()
        guard !isKeptAsYou else { return }
        isDiscarded.toggle()
        if isDiscarded {
            stopClipIfPlaying()
            endEditingIfNeeded()
        }
        rebuild()
        commitAnswer(celebrate: false)
    }

    /// Hands the keyboard back before the name field leaves the row.
    func endEditingIfNeeded() {
        if let editor = nameField.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
    }

    func clearField() {
        nameField.stringValue = ""
        highlightedRow = nil
        prefilledUntouched = false
    }

    func focusField() {
        onWantsKeyboard?()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditing, self.lock == nil, let window = self.nameField.window else { return }
            window.makeFirstResponder(self.nameField)
        }
    }
}
