// NotchIslandSpeakerReviewView.swift
// "Who was on this call?" inside the notch island, in place of the speaker
// review window. It opens by itself when a saved meeting has voices the
// pipeline isn't sure about:
//
//   - voices Transcripted named on its own show as "recognized"
//   - a likely match asks "Is this Maya?" with Yes and No
//   - No, or a voice with no guess, opens a name box with the calendar
//     invitees as one-tap names (an arrow shows more than three) and
//     autocomplete from people already saved in Speakers
//   - each voice has a clip to play; while it plays the button is Pause
//     and a ring fills around it until the clip ends
//
// Done saves the answers through the same `SpeakerNameUpdate`s the review
// window builds, then shows "Everyone's named" with Open transcript. Later
// (or its 20 s ring running out) saves whatever was answered and leaves
// the rest for Speakers. The rules live in NotchIslandSpeakerReviewPolicy.

import AppKit
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class NotchIslandSpeakerReviewView: NSView {
    static let contentWidth = NotchIslandGeometry.dropWidth - 40

    /// The rows changed height; the island should resize around them.
    var onLayoutChange: (() -> Void)?
    /// A name box wants the keyboard.
    var onWantsKeyboard: (() -> Void)?
    /// Done: `updates` to save and how many voices are still unnamed.
    var onDone: ((_ updates: [SpeakerNameUpdate], _ leftForLater: Int) -> Void)?
    /// Later, or the ring ran out: save what was answered, leave the rest.
    var onLater: ((_ updates: [SpeakerNameUpdate]) -> Void)?
    var onOpenTranscript: (() -> Void)?
    /// "Everyone's named" has been up long enough.
    var onDoneLingerEnded: (() -> Void)?

    let requestID: UUID
    private let request: SpeakerNamingRequest
    private let stack = NSStackView()
    private var rows: [NotchIslandVoiceRowView] = []
    private var meetingTitle: String?
    private var invitees: [String] = []
    private var laterButton: NotchIslandButton?
    private var laterTask: Task<Void, Never>?
    private var laterDeadline: Date?
    private var laterPausedRemaining: TimeInterval?
    private var laterStopped = false
    private var lingerTask: Task<Void, Never>?
    private var isHovered = false
    private(set) var isFinished = false

    init(request: SpeakerNamingRequest) {
        self.request = request
        self.requestID = request.id
        super.init(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 10))
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Doubtful suggestions first: the first answer teaches the matcher most.
        let ranked = SpeakerReviewPrioritizer.ranked(request.speakers.filter { $0.channel == .system })
            + SpeakerReviewPrioritizer.ranked(request.speakers.filter { $0.channel == .mic })
        rows = ranked.map { entry in
            let row = NotchIslandVoiceRowView(entry: entry, knownPeople: request.knownPeople)
            row.onChange = { [weak self] in self?.rowChanged() }
            row.onInteract = { [weak self] in self?.stopLaterCountdown() }
            row.onWantsKeyboard = { [weak self] in self?.onWantsKeyboard?() }
            row.onSubmit = { [weak self, weak row] in self?.focusNextOpenRow(after: row) }
            return row
        }
        rebuild()
        startLaterCountdown()
        trackShown()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.headerTitle(meetingTitle: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        laterTask?.cancel()
        lingerTask?.cancel()
    }

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat { ceil(fittingSize.height) }

    // MARK: Inputs

    func setMeetingTitle(_ title: String?) {
        meetingTitle = title
        setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.headerTitle(meetingTitle: title))
        guard !isFinished else { return }
        rebuild()
    }

    func setInvitees(_ names: [String]) {
        invitees = names
        refreshInvitees()
    }

    /// The pointer is over the island: hold the Later ring and the
    /// "Everyone's named" linger.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if !laterStopped {
            laterButton?.setCountdownPaused(hovered)
            if hovered {
                if let laterDeadline {
                    laterPausedRemaining = max(1, laterDeadline.timeIntervalSinceNow)
                }
                laterTask?.cancel()
                laterTask = nil
            } else if let remaining = laterPausedRemaining {
                laterPausedRemaining = nil
                scheduleLater(after: remaining)
            }
        }
        if isFinished {
            if hovered {
                lingerTask?.cancel()
                lingerTask = nil
            } else {
                scheduleLingerEnd()
            }
        }
    }

    // MARK: Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isFinished { return }

        let header = NotchIslandPalette.label(
            NotchIslandSpeakerReviewPolicy.headerTitle(meetingTitle: meetingTitle),
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: NotchIslandPalette.primaryText
        )
        header.lineBreakMode = .byTruncatingTail
        header.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(10, after: header)

        for name in request.recognizedSpeakerNames {
            stack.addArrangedSubview(recognizedRow(name))
        }
        for row in rows {
            stack.addArrangedSubview(row)
        }
        refreshInvitees()

        let later = NotchIslandButton(title: "Later", style: .plain, height: 30)
        later.onPress = { [weak self] in self?.finishLater() }
        later.setAccessibilityHelp("Save what you answered and name the rest later in Speakers.")
        if !laterStopped {
            later.startCountdown(seconds: max(1, laterDeadline.map { $0.timeIntervalSinceNow } ?? NotchIslandSpeakerReviewPolicy.laterSeconds))
            if isHovered { later.setCountdownPaused(true) }
        }
        laterButton = later
        let done = NotchIslandButton(title: "Done", style: .accent, height: 30)
        done.onPress = { [weak self] in self?.finishDone() }
        let buttons = NSStackView(views: [later, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let footer = NSStackView(views: [NSView(), buttons])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        stack.setCustomSpacing(12, after: rows.last ?? header)
        stack.addArrangedSubview(footer)
    }

    private func recognizedRow(_ name: String) -> NSView {
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold)) ?? NSImage())
        check.contentTintColor = NotchIslandPalette.secondaryText
        let nameLabel = NotchIslandPalette.label(name, font: .systemFont(ofSize: 14, weight: .semibold), color: NotchIslandPalette.primaryText)
        let note = NotchIslandPalette.label("recognized", font: .systemFont(ofSize: 12), color: NotchIslandPalette.secondaryText)
        let row = NSStackView(views: [nameLabel, NSView(), note, check])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        row.layer?.cornerRadius = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(name), recognized")
        return row
    }

    private func refreshInvitees() {
        let used = Set(rows.compactMap(\.chosenName) + request.recognizedSpeakerNames)
        for row in rows {
            row.setInvitees(invitees, alreadyUsed: used)
        }
    }

    private func rowChanged() {
        refreshInvitees()
        onLayoutChange?()
    }

    private func focusNextOpenRow(after row: NotchIslandVoiceRowView?) {
        guard let row, let index = rows.firstIndex(where: { $0 === row }) else { return }
        if let next = rows[(index + 1)...].first(where: { !$0.isAnswered }) {
            next.beginNamingIfNeeded()
        }
    }

    // MARK: Later ring

    private func startLaterCountdown() {
        scheduleLater(after: NotchIslandSpeakerReviewPolicy.laterSeconds)
    }

    private func scheduleLater(after seconds: TimeInterval) {
        laterTask?.cancel()
        laterDeadline = Date().addingTimeInterval(seconds)
        laterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.laterStopped, !self.isFinished else { return }
            self.finishLater()
        }
    }

    /// Someone started answering: the review waits for them now.
    private func stopLaterCountdown() {
        guard !laterStopped else { return }
        laterStopped = true
        laterTask?.cancel()
        laterTask = nil
        laterDeadline = nil
        laterPausedRemaining = nil
        laterButton?.stopCountdown()
    }

    // MARK: Finishing

    private func collectUpdates() -> (updates: [SpeakerNameUpdate], unanswered: Int) {
        var updates: [SpeakerNameUpdate] = []
        var unanswered = 0
        for row in rows {
            if let update = row.buildUpdate() {
                updates.append(update)
            } else {
                unanswered += 1
            }
        }
        return (updates, unanswered)
    }

    private func finishLater() {
        guard !isFinished else { return }
        isFinished = true
        laterTask?.cancel()
        SpeakerClipPlayback.stop()
        let updates = collectUpdates().updates
        trackSubmitted(completionKind: "review_later", updates: updates)
        onLater?(updates)
    }

    private func finishDone() {
        guard !isFinished else { return }
        isFinished = true
        laterTask?.cancel()
        SpeakerClipPlayback.stop()
        let result = collectUpdates()
        trackSubmitted(completionKind: "save", updates: result.updates)
        showDone(leftForLater: result.unanswered)
        onDone?(result.updates, result.unanswered)
    }

    private func showDone(leftForLater: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let copy = NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: leftForLater)
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold)) ?? NSImage())
        check.contentTintColor = NotchIslandPalette.primaryText
        let title = NotchIslandPalette.label(copy.title, font: .systemFont(ofSize: 15, weight: .semibold), color: NotchIslandPalette.primaryText)
        let titleRow = NSStackView(views: [check, title])
        titleRow.orientation = .horizontal
        titleRow.spacing = 7
        let detail = NotchIslandPalette.label(copy.detail, font: .systemFont(ofSize: 12), color: NotchIslandPalette.secondaryText)
        let open = NotchIslandButton(title: "Open transcript", style: .accent, height: 30)
        open.onPress = { [weak self] in self?.onOpenTranscript?() }
        let footer = NSStackView(views: [NSView(), open])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(detail)
        stack.setCustomSpacing(12, after: detail)
        stack.addArrangedSubview(footer)
        setAccessibilityLabel("\(copy.title). \(copy.detail)")
        onLayoutChange?()
        if !isHovered { scheduleLingerEnd() }
    }

    // MARK: Analytics (same events as the review window, surface "speaker_review_island")

    private static let surface = "speaker_review_island"

    private func trackShown() {
        AnalyticsReporter.track("meeting_speaker_review_shown", properties: analyticsProperties())
    }

    private func trackSubmitted(completionKind: String, updates: [SpeakerNameUpdate]) {
        var properties = analyticsProperties()
        properties["completion_kind"] = completionKind
        properties["result"] = updates.isEmpty ? "no_updates" : "updates_submitted"
        properties["updates_submitted_bucket"] = AnalyticsReporter.countBucket(updates.count)
        AnalyticsReporter.track("meeting_speaker_review_submitted", properties: properties)
        trackMatchOutcomes(updates)
    }

    private func analyticsProperties() -> [String: String] {
        let mic = request.speakers.filter { $0.channel == .mic }.count
        let system = request.speakers.count - mic
        let needsNaming = request.speakers.contains { $0.needsNaming }
        let needsConfirmation = request.speakers.contains { $0.needsConfirmation }
        let reason: String
        switch (needsNaming, needsConfirmation) {
        case (true, true): reason = "mixed"
        case (true, false): reason = "needs_naming"
        case (false, true): reason = "needs_confirmation"
        case (false, false): reason = "unknown"
        }
        return [
            "known_people_bucket": AnalyticsReporter.countBucket(request.knownPeople.count),
            "local_voice_bucket": AnalyticsReporter.countBucket(mic),
            "match_suggestion_bucket": AnalyticsReporter.countBucket(request.speakers.filter { $0.suggestedProfileId != nil }.count),
            "remote_voice_bucket": AnalyticsReporter.countBucket(system),
            "review_item_bucket": AnalyticsReporter.countBucket(request.speakers.count),
            "review_reason": reason,
            "surface": Self.surface,
        ]
    }

    /// One bucketed event per verdict, joining the matcher's confidence to
    /// the answer, exactly as the review window reports it.
    private func trackMatchOutcomes(_ updates: [SpeakerNameUpdate]) {
        let entriesByKey = Dictionary(
            request.speakers.map { ($0.channel.speakerKey(diarizerSpeakerId: $0.diarizerSpeakerId), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for update in updates {
            guard let kind = SpeakerMatchOutcomeKind(reviewAction: update.action) else { continue }
            let entry = entriesByKey[update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)]
            AnalyticsReporter.track(
                "meeting_speaker_match_reviewed",
                properties: [
                    "review_action": kind.rawValue,
                    "similarity_bucket": SpeakerRecognitionTelemetry.similarityBucket(entry?.matchSimilarity),
                    "margin_bucket": SpeakerRecognitionTelemetry.marginBucket(
                        similarity: entry?.matchSimilarity,
                        secondSimilarity: entry?.matchSecondSimilarity
                    ),
                    "call_count_bucket": AnalyticsReporter.countBucket(entry?.callCount ?? 0),
                    "channel": update.channel.rawValue,
                    "had_suggestion": entry?.currentName != nil ? "true" : "false",
                    "surface": Self.surface,
                ]
            )
        }
    }

    private func scheduleLingerEnd() {
        lingerTask?.cancel()
        lingerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchIslandSpeakerReviewPolicy.doneLingerSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.onDoneLingerEnded?()
        }
    }
}

// MARK: - One voice

@available(macOS 14.0, *)
@MainActor
final class NotchIslandVoiceRowView: NSView, NSTextFieldDelegate {
    enum Answer: Equatable {
        case none
        /// Yes to "Is this …?"
        case confirmed
        /// No to the suggestion (the name box opens).
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
    private let knownPeopleByLabel: [String: SpeakerIdentityOption]
    private let knownPeople: [(label: String, callCount: Int)]
    private var answer: Answer = .none
    private var isEditing = false
    private var showAllInvitees = false
    private var invitees: [String] = []
    private var usedNames: Set<String> = []
    private var highlightedSuggestion = 0

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

    init(entry: SpeakerNamingEntry, knownPeople: [SpeakerIdentityOption]) {
        self.entry = entry
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
        if case .name = question { isEditing = true }
        rebuild()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var isAnswered: Bool {
        switch answer {
        case .confirmed, .named: return true
        case .none, .rejected: return false
        }
    }

    /// The name this voice has been given here, so invitee chips don't
    /// offer the same person twice.
    var chosenName: String? {
        switch answer {
        case .confirmed: return entry.currentName
        case .named(let label): return knownPeopleByLabel[label]?.displayName ?? label
        case .none, .rejected: return nil
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

    // MARK: Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(topLine())
        if isEditing {
            let field = fieldLine()
            stack.addArrangedSubview(field)
            if let chips = inviteeLine() { stack.addArrangedSubview(chips) }
            let suggestions = suggestionList()
            if let suggestions { stack.addArrangedSubview(suggestions) }
        }
        setAccessibilityLabel(accessibilitySummary)
        needsLayout = true
    }

    private func topLine() -> NSView {
        var views: [NSView] = [clip]
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        switch (answer, question) {
        case (.confirmed, _):
            text.addArrangedSubview(title(entry.currentName ?? "Confirmed"))
            text.addArrangedSubview(caption("confirmed"))
        case (.named(let label), _):
            text.addArrangedSubview(title(knownPeopleByLabel[label]?.displayName ?? label))
            text.addArrangedSubview(caption("named"))
        case (_, .confirm(let name)) where answer == .none:
            text.addArrangedSubview(title("Is this \(name)?"))
            text.addArrangedSubview(caption(quote))
        default:
            text.addArrangedSubview(title(isEditing ? "Who is this?" : "Unknown voice"))
            text.addArrangedSubview(caption(quote))
        }
        views.append(text)
        views.append(NSView())

        switch (answer, question) {
        case (.none, .confirm):
            views.append(pill("No", style: .plain) { [weak self] in self?.reject() })
            views.append(pill("Yes", style: .accent) { [weak self] in self?.confirm() })
        case (.confirmed, _), (.named, _):
            views.append(pill("Change", style: .subtle) { [weak self] in self?.change() })
        default:
            break
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: NotchIslandSpeakerReviewView.contentWidth - 20).isActive = true
        return line
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
        let suggestions = currentSuggestions
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        list.wantsLayer = true
        list.layer?.backgroundColor = NotchIslandPalette.buttonSubtle.cgColor
        list.layer?.cornerRadius = 10
        let width = NotchIslandSpeakerReviewView.contentWidth - 60
        for (index, suggestion) in suggestions.enumerated() {
            list.addArrangedSubview(suggestionRow(suggestion.label, detail: suggestion.detail, highlighted: index == highlightedSuggestion, width: width - 8))
        }
        let exactMatch = suggestions.contains {
            SpeakerNameSelectionPolicy.normalizedSearchText($0.label) == SpeakerNameSelectionPolicy.normalizedSearchText(typed)
        }
        if !exactMatch {
            list.addArrangedSubview(suggestionRow(typed, detail: "new person", highlighted: suggestions.isEmpty, width: width - 8))
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

    private func suggestionRow(_ label: String, detail: String, highlighted: Bool, width: CGFloat) -> NSView {
        let button = NotchIslandSuggestionButton(title: label, detail: detail, width: width)
        button.isHighlightedRow = highlighted
        button.onPress = { [weak self] in self?.pick(label) }
        return button
    }

    private var currentSuggestions: [NotchIslandSpeakerReviewPolicy.Suggestion] {
        NotchIslandSpeakerReviewPolicy.suggestions(
            query: nameField.stringValue,
            people: knownPeople,
            invitees: invitees
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
        switch (answer, question) {
        case (.confirmed, _): return "\(entry.currentName ?? "Voice"), confirmed"
        case (.named(let label), _): return "\(knownPeopleByLabel[label]?.displayName ?? label), named"
        case (.none, .confirm(let name)): return "Is this \(name)?"
        default: return "Unnamed voice"
        }
    }

    // MARK: Answers

    private func confirm() {
        onInteract?()
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
        rebuild()
        onChange?()
        focusField()
    }

    private func change() {
        onInteract?()
        answer = question == .name ? .none : .rejected
        isEditing = true
        nameField.stringValue = ""
        rebuild()
        onChange?()
        focusField()
    }

    private func pick(_ label: String) {
        onInteract?()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .confirm(let suggested) = question,
           SpeakerNameSelectionPolicy.normalizedSearchText(trimmed) == SpeakerNameSelectionPolicy.normalizedSearchText(suggested),
           entry.currentName != nil {
            confirm()
            return
        }
        answer = .named(trimmed)
        isEditing = false
        nameField.stringValue = ""
        highlightedSuggestion = 0
        window?.makeFirstResponder(nil)
        rebuild()
        onChange?()
        onSubmit?()
    }

    private func focusField() {
        onWantsKeyboard?()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditing, let window = self.nameField.window else { return }
            window.makeFirstResponder(self.nameField)
        }
    }

    /// The same `SpeakerNameUpdate` the review window would build for this
    /// row, or nil when the voice was left unnamed.
    func buildUpdate() -> SpeakerNameUpdate? {
        switch answer {
        case .confirmed:
            guard let current = entry.currentName, !current.isEmpty else { return nil }
            if let suggestedProfileId = entry.suggestedProfileId {
                return SpeakerNameUpdate(
                    persistentSpeakerId: entry.id,
                    diarizerSpeakerId: entry.diarizerSpeakerId,
                    channel: entry.channel,
                    newName: current,
                    action: .merged(targetProfileId: suggestedProfileId)
                )
            }
            return SpeakerNameUpdate(
                persistentSpeakerId: entry.id,
                diarizerSpeakerId: entry.diarizerSpeakerId,
                channel: entry.channel,
                newName: current,
                previousName: current,
                action: .confirmed
            )
        case .named(let label):
            return SpeakerNamingPolicy.typedNameUpdate(
                entry: entry,
                typedName: label,
                optionsByLabel: knownPeopleByLabel
            )
        case .none, .rejected:
            return nil
        }
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        onInteract?()
        highlightedSuggestion = 0
        refreshSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return commandSelector == #selector(NSResponder.insertNewline(_:)) }
            let suggestions = currentSuggestions
            if suggestions.indices.contains(highlightedSuggestion) {
                pick(suggestions[highlightedSuggestion].label)
            } else {
                pick(typed)
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            let count = currentSuggestions.count
            guard count > 0 else { return false }
            highlightedSuggestion = min(highlightedSuggestion + 1, count - 1)
            refreshSuggestions()
            return true
        case #selector(NSResponder.moveUp(_:)):
            highlightedSuggestion = max(0, highlightedSuggestion - 1)
            refreshSuggestions()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            nameField.stringValue = ""
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
        guard isEditing else { return }
        // Keep the top line and the name box; redo the invitees and the list.
        while stack.arrangedSubviews.count > 2 {
            stack.arrangedSubviews.last?.removeFromSuperview()
        }
        if let chips = inviteeLine() { stack.addArrangedSubview(chips) }
        if let list = suggestionList() { stack.addArrangedSubview(list) }
        onChange?()
    }
}

// MARK: - Controls

/// Play / pause for a voice clip. While the clip plays, a ring fills around
/// the button; a full circle means the clip has finished.
@available(macOS 14.0, *)
@MainActor
final class NotchIslandClipButton: NSButton {
    var onPress: (() -> Void)?
    private let clipURL: URL
    private let track = CAShapeLayer()
    private let progressRing = CAShapeLayer()
    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private static let size: CGFloat = 30

    init(clipURL: URL) {
        self.clipURL = clipURL
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        layer?.masksToBounds = false
        imagePosition = .imageOnly
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true
        for (shape, color) in [(track, NSColor(white: 1, alpha: 0.14)), (progressRing, NSColor.white)] {
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = 2
            shape.lineCap = .round
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        observer = NotificationCenter.default.addObserver(
            forName: SpeakerClipPlayback.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        pollTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        // A circle 4 pt outside the button, drawn from the top, clockwise.
        let inset: CGFloat = -4
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let top = isFlipped ? -CGFloat.pi / 2 : CGFloat.pi / 2
        path.addArc(center: center, radius: radius, startAngle: top, endAngle: top + (isFlipped ? 2 : -2) * .pi, clockwise: !isFlipped)
        track.path = path
        progressRing.path = path
        track.frame = bounds
        progressRing.frame = bounds
    }

    @objc private func pressed() {
        onPress?()
        SpeakerClipPlayback.play(clipURL)
        sync()
    }

    private func sync() {
        let playing = SpeakerClipPlayback.isPlaying(clipURL)
        let symbol = playing ? "pause.fill" : "play.fill"
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: playing ? "Pause" : "Play clip")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        contentTintColor = playing ? .black : .white
        layer?.backgroundColor = (playing ? NSColor.white : NotchIslandPalette.buttonPlain).cgColor
        setAccessibilityLabel(playing ? "Pause clip" : "Play clip")
        track.isHidden = !playing
        progressRing.isHidden = !playing
        pollTimer?.invalidate()
        pollTimer = nil
        if playing {
            updateProgress()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateProgress() }
            }
        }
    }

    private func updateProgress() {
        guard let progress = SpeakerClipPlayback.progress(of: clipURL) else {
            if !SpeakerClipPlayback.isPlaying(clipURL) { sync() }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressRing.strokeEnd = CGFloat(progress)
        CATransaction.commit()
    }
}

/// A name box on the island's black surface. Clicking it asks for the
/// keyboard, since the island never has it otherwise.
@MainActor
final class NotchIslandNameField: NSTextField {
    var onFocusRequest: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBezeled = false
        drawsBackground = true
        backgroundColor = NotchIslandPalette.buttonSubtle
        textColor = NotchIslandPalette.primaryText
        font = .systemFont(ofSize: 14, weight: .semibold)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        placeholderAttributedString = NSAttributedString(
            string: "Type a name…",
            attributes: [
                .foregroundColor: NotchIslandPalette.secondaryText,
                .font: NSFont.systemFont(ofSize: 14),
            ]
        )
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("Name for this voice")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onFocusRequest?()
        return super.becomeFirstResponder()
    }
}

/// One autocomplete row under the name box.
@MainActor
final class NotchIslandSuggestionButton: NSButton {
    var onPress: (() -> Void)?
    var isHighlightedRow = false {
        didSet { layer?.backgroundColor = (isHighlightedRow ? NotchIslandPalette.buttonPlain : .clear).cgColor }
    }

    init(title: String, detail: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        self.title = ""
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        let name = NotchIslandPalette.label(title, font: .systemFont(ofSize: 13, weight: .semibold), color: NotchIslandPalette.primaryText)
        let note = NotchIslandPalette.label(detail, font: .systemFont(ofSize: 11), color: NotchIslandPalette.secondaryText)
        let row = NSStackView(views: [name, NSView(), note])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("\(title), \(detail)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func pressed() { onPress?() }
}
