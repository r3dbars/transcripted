// NotchIslandSpeakerReviewView.swift
// "Who was on this call?" inside the notch island, in place of the speaker
// review window. It opens by itself after every saved meeting with a remote
// voice:
//
//   - voices Transcripted named on its own show as "recognized"; hovering
//     one offers "Not Taylor?", which opens a name box to correct it
//   - when every voice was recognized nothing is asked: the island lists
//     who was on the call and closes itself (Done, or its ring running out)
//   - a likely match asks "Is this Maya?" with Yes and No
//   - No, or a voice with no guess, opens a name box with the calendar
//     invitees as one-tap names (an arrow shows more than three) and
//     autocomplete from people already saved in Speakers
//   - each voice has a clip to play; while it plays the button is Pause
//     and a ring fills around it until the clip ends
//   - a calendar 1:1 with one unnamed remote voice fills that voice's name
//     box with the other invitee; it saves on Done like a typed name
//   - local mic voices sit under an "All me" toggle; an open name box
//     offers "Not a person" for a voice that isn't one
//
// Done saves the answers through the same `SpeakerNameUpdate`s the review
// window builds, then shows "Everyone's named" with Open. Later (or its 20 s
// ring running out) saves whatever was answered and leaves the rest for
// Speakers. A name typed but not submitted counts on both. The ring only runs
// while the review is on screen. The rules live in NotchIslandSpeakerReviewPolicy.

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
    /// Voices the review asks about.
    private var rows: [NotchIslandVoiceRowView] = []
    /// Voices named on their own, listed with a hover correction.
    private var recognizedRows: [NotchIslandVoiceRowView] = []
    /// Recognized names with no clip to correct from (shown, not editable).
    private var plainRecognizedNames: [String] = []
    /// Everyone was recognized: nothing to ask, just who was on the call.
    let isRecognizedOnly: Bool
    private var meetingTitle: String?
    private var invitees: [String] = []
    /// The calendar 1:1 name has been offered (it is offered once).
    private var didOfferOneOnOnePrefill = false
    /// "All me" is on: every asked local mic voice saves as You.
    private var keepMicAsYou = false
    /// The button carrying the countdown ring: Later, or Done when nothing is asked.
    private var countdownButton: NotchIslandButton?
    private var laterTask: Task<Void, Never>?
    private var laterDeadline: Date?
    /// Time left on the ring while it isn't running.
    private var laterRemaining: TimeInterval = NotchIslandSpeakerReviewPolicy.laterSeconds
    private var laterStopped = false
    private var lingerTask: Task<Void, Never>?
    /// Closes a list with nobody to ask after `recognizedOnlyHardCapSeconds`,
    /// on screen or not, so it can't hold the review forever.
    private var hardCapTask: Task<Void, Never>?
    private var hardCapReached = false
    private var isHovered = false
    /// The island is showing this review (not waiting behind a dictation or
    /// a busy meeting). The controller reports it; until then it waits.
    private var isOnScreen = false
    private(set) var isFinished = false

    init(request: SpeakerNamingRequest) {
        self.request = request
        self.requestID = request.id
        self.isRecognizedOnly = request.speakers.isEmpty
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
        rows = ranked.map { makeRow(for: $0, recognized: false) }
        recognizedRows = request.recognizedSpeakers.map { makeRow(for: $0, recognized: true) }
        let correctable = Set(request.recognizedSpeakers.compactMap {
            $0.currentName.map(SpeakerNameSelectionPolicy.normalizedSearchText)
        })
        plainRecognizedNames = request.recognizedSpeakerNames.filter {
            !correctable.contains(SpeakerNameSelectionPolicy.normalizedSearchText($0))
        }
        rebuild()
        // The ring waits until the island reports the review on screen.
        if !isRecognizedOnly { trackShown() }
        scheduleHardCap()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(headerTitle)
    }

    private func makeRow(for entry: SpeakerNamingEntry, recognized: Bool) -> NotchIslandVoiceRowView {
        let row = NotchIslandVoiceRowView(entry: entry, knownPeople: request.knownPeople, recognized: recognized)
        row.onChange = { [weak self] in self?.rowChanged() }
        row.onInteract = { [weak self] in self?.stopLaterCountdown() }
        row.onWantsKeyboard = { [weak self] in self?.onWantsKeyboard?() }
        row.onSubmit = { [weak self, weak row] in self?.focusNextOpenRow(after: row) }
        return row
    }

    private var headerTitle: String {
        NotchIslandSpeakerReviewPolicy.headerTitle(meetingTitle: meetingTitle, recognizedOnly: isRecognizedOnly)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        laterTask?.cancel()
        lingerTask?.cancel()
        hardCapTask?.cancel()
    }

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat { ceil(fittingSize.height) }

    // MARK: Inputs

    func setMeetingTitle(_ title: String?) {
        meetingTitle = title
        guard !isFinished else { return }
        setAccessibilityLabel(headerTitle)
        rebuild()
    }

    /// The calendar invitees, and how many remote voices the whole meeting
    /// heard (nil when unknown). In a 1:1 with one unnamed remote voice, that
    /// voice's name box is filled in with the other invitee, the same rule
    /// the review window used; it is still only saved on Done.
    func setInvitees(_ names: [String], remoteVoicesInMeeting: Int?) {
        invitees = names
        refreshInvitees()
        guard !didOfferOneOnOnePrefill, !isFinished else { return }
        didOfferOneOnOnePrefill = true
        let askedRemote = rows.filter { !$0.isMic }
        guard let name = NotchIslandSpeakerReviewPolicy.oneOnOnePrefill(
            invitees: names,
            remoteVoicesInMeeting: remoteVoicesInMeeting,
            askedRemoteVoicesHaveSuggestion: askedRemote.map { $0.hasSuggestedName }
        ), let row = askedRemote.first, row.prefill(name) else { return }
        refreshInvitees()
        onLayoutChange?()
    }

    /// The island is (or stopped) showing this review. The Later ring only
    /// runs while it is on screen, so a review hidden behind a dictation or
    /// the next meeting never closes unseen.
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        updateLaterClock()
    }

    /// The pointer is over the island: hold the Later ring and the
    /// "Everyone's named" linger.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateLaterClock()
        if isFinished {
            if hovered {
                lingerTask?.cancel()
                lingerTask = nil
            } else {
                scheduleLingerEnd()
            }
        }
        closeAtHardCapIfDue()
    }

    // MARK: Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isFinished { return }

        let header = NotchIslandPalette.label(
            headerTitle,
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: NotchIslandPalette.primaryText
        )
        header.lineBreakMode = .byTruncatingTail
        header.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(10, after: header)

        var lastRow: NSView = header
        for row in recognizedRows {
            stack.addArrangedSubview(row)
            lastRow = row
        }
        for name in plainRecognizedNames {
            let row = recognizedRow(name)
            stack.addArrangedSubview(row)
            lastRow = row
        }
        let firstMicRow = rows.first(where: { $0.isMic })
        for row in rows {
            if row === firstMicRow {
                // The local mic voices get their own small header with the
                // review window's "Keep Local Mic as You" escape hatch.
                let micHeader = micSectionHeader()
                stack.addArrangedSubview(micHeader)
                stack.setCustomSpacing(4, after: micHeader)
            }
            stack.addArrangedSubview(row)
            lastRow = row
        }
        refreshInvitees()

        let done = NotchIslandButton(title: "Done", style: .accent, height: 30)
        done.onPress = { [weak self] in self?.finishDone() }
        let buttons: NSStackView
        if isRecognizedOnly {
            // Nothing to put off: Done carries the ring and closes the list.
            done.setAccessibilityHelp("Close. Names are already saved.")
            buttons = NSStackView(views: [done])
            startCountdownRing(on: done)
        } else {
            let later = NotchIslandButton(title: "Later", style: .plain, height: 30)
            later.onPress = { [weak self] in self?.finishLater() }
            later.setAccessibilityHelp("Save what you answered and name the rest later in Speakers.")
            startCountdownRing(on: later)
            buttons = NSStackView(views: [later, done])
        }
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let footer = NSStackView(views: [NSView(), buttons])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        stack.setCustomSpacing(12, after: lastRow)
        stack.addArrangedSubview(footer)
    }

    private func startCountdownRing(on button: NotchIslandButton) {
        countdownButton = button
        guard !laterStopped else { return }
        button.startCountdown(seconds: max(1, laterDeadline.map { $0.timeIntervalSinceNow } ?? laterRemaining))
        button.setCountdownPaused(!laterRuns)
    }

    private func micSectionHeader() -> NSView {
        let label = NotchIslandPalette.label(
            "Local mic voices",
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: NotchIslandPalette.secondaryText
        )
        let keep = NotchIslandButton(
            title: NotchIslandSpeakerReviewPolicy.keepAsYouTitle(keepMicAsYou: keepMicAsYou),
            style: .subtle,
            height: 24,
            fontSize: 12
        )
        keep.onPress = { [weak self] in self?.toggleKeepMicAsYou() }
        keep.setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.keepAsYouAccessibilityLabel(keepMicAsYou: keepMicAsYou))
        keep.setAccessibilityHelp(NotchIslandSpeakerReviewPolicy.keepAsYouHelp(keepMicAsYou: keepMicAsYou))
        keep.setContentHuggingPriority(.required, for: .horizontal)
        keep.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = NSStackView(views: [label, NSView(), keep])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 0, right: 0)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return line
    }

    /// "All me": every asked local mic voice saves as You (`.collapsedToMe`),
    /// whatever was typed for it. Pressing it again ("Undo") lifts that.
    private func toggleKeepMicAsYou() {
        stopLaterCountdown()
        keepMicAsYou.toggle()
        for row in rows where row.isMic {
            row.setKeptAsYou(keepMicAsYou)
        }
        rebuild()
        onLayoutChange?()
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
        let used = Set((recognizedRows + rows).compactMap(\.chosenName) + plainRecognizedNames)
        for row in recognizedRows + rows {
            row.setInvitees(invitees, alreadyUsed: used)
        }
    }

    private func rowChanged() {
        refreshInvitees()
        onLayoutChange?()
        closeAtHardCapIfDue()
    }

    private func focusNextOpenRow(after row: NotchIslandVoiceRowView?) {
        guard let row, let index = rows.firstIndex(where: { $0 === row }) else { return }
        if let next = rows[(index + 1)...].first(where: { !$0.isAnswered }) {
            next.beginNamingIfNeeded()
        }
    }

    // MARK: Later ring

    private var laterRuns: Bool {
        NotchIslandSpeakerReviewPolicy.laterCountdownRuns(visible: isOnScreen, hovered: isHovered)
    }

    /// Runs or holds the ring to match `laterRuns`, keeping the time left.
    private func updateLaterClock() {
        guard !laterStopped, !isFinished else { return }
        let runs = laterRuns
        countdownButton?.setCountdownPaused(!runs)
        if runs {
            if laterTask == nil { scheduleLater(after: laterRemaining) }
        } else if laterTask != nil {
            if let laterDeadline {
                laterRemaining = max(1, laterDeadline.timeIntervalSinceNow)
            }
            laterTask?.cancel()
            laterTask = nil
            laterDeadline = nil
        }
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

    // MARK: Hard cap

    private func scheduleHardCap() {
        guard let seconds = NotchIslandSpeakerReviewPolicy.hardCapSeconds(recognizedOnly: isRecognizedOnly) else {
            return
        }
        hardCapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isFinished else { return }
            self.hardCapReached = true
            self.closeAtHardCapIfDue()
        }
    }

    private func closeAtHardCapIfDue() { // also re-checked when an answer finishes (rowChanged)
        guard hardCapReached, !isFinished, NotchIslandSpeakerReviewPolicy.hardCapClosesNow(hovered: isHovered, answering: recognizedRows.contains { !$0.isAnswered }) else { return }
        finishLater()
    }

    /// Someone started answering: the review waits for them now.
    private func stopLaterCountdown() {
        guard !laterStopped else { return }
        laterStopped = true
        laterTask?.cancel()
        laterTask = nil
        laterDeadline = nil
        countdownButton?.stopCountdown()
    }

    // MARK: Finishing

    /// Every answer, including a name left typed in an open box. Recognized
    /// voices only add an update when they were corrected; `unanswered`
    /// counts the asked voices still unnamed.
    private func collectUpdates(
        finish: NotchIslandSpeakerReviewPolicy.Finish
    ) -> (updates: [SpeakerNameUpdate], unanswered: Int) {
        var updates = recognizedRows.compactMap { $0.buildUpdate(finish: finish) }
        var unanswered = 0
        for row in rows {
            if let update = row.buildUpdate(finish: finish) {
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
        let updates = collectUpdates(finish: .later).updates
        if isRecognizedOnly {
            trackMatchOutcomes(updates)
        } else {
            trackSubmitted(completionKind: "review_later", updates: updates)
        }
        onLater?(updates)
    }

    private func finishDone() {
        guard !isFinished else { return }
        let result = collectUpdates(finish: .done)
        guard NotchIslandSpeakerReviewPolicy.doneShowsSummary(
            recognizedOnly: isRecognizedOnly,
            updates: result.updates.count
        ) else {
            // Everyone was recognized and nothing changed: just close.
            finishLater()
            return
        }
        isFinished = true
        laterTask?.cancel()
        SpeakerClipPlayback.stop()
        if isRecognizedOnly {
            trackMatchOutcomes(result.updates)
        } else {
            trackSubmitted(completionKind: "save", updates: result.updates)
        }
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
        let open = NotchIslandButton(title: "Open", style: .accent, height: 30)
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
        // Recognized voices too, so a "Not Taylor?" correction reports the
        // match it overrode instead of an empty bucket.
        let entriesByKey = NotchIslandSpeakerReviewPolicy.entriesByKey(
            asked: request.speakers,
            recognized: request.recognizedSpeakers,
            key: { $0.channel.speakerKey(diarizerSpeakerId: $0.diarizerSpeakerId) }
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
    private let knownPeopleByLabel: [String: SpeakerIdentityOption]
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

    init(entry: SpeakerNamingEntry, knownPeople: [SpeakerIdentityOption], recognized: Bool = false) {
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

    /// The same `SpeakerNameUpdate` the review window would build for this
    /// row, or nil when the voice was left unnamed (or, for a recognized
    /// voice, left as it was). A name still sitting in an open box counts,
    /// read the way Return would read it, except an untouched calendar name
    /// on Later. All me and Not a person win over any name, and build
    /// the window's `.collapsedToMe` and `.discardedFromDatabase` updates.
    func buildUpdate(finish: NotchIslandSpeakerReviewPolicy.Finish) -> SpeakerNameUpdate? {
        if let lock {
            switch lock {
            case .keptAsYou:
                return SpeakerNameUpdate(
                    persistentSpeakerId: entry.id,
                    diarizerSpeakerId: entry.diarizerSpeakerId,
                    channel: entry.channel,
                    newName: "You",
                    previousName: entry.currentName,
                    action: .collapsedToMe
                )
            case .discarded:
                return SpeakerNameUpdate(
                    persistentSpeakerId: entry.id,
                    diarizerSpeakerId: entry.diarizerSpeakerId,
                    channel: entry.channel,
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

    private func confirmedUpdate() -> SpeakerNameUpdate? {
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
    }

    /// A typed or picked name. On a recognized voice this is a correction:
    /// a new name saves as `.corrected`, and a saved person as a merge that
    /// the naming coordinator turns into a correction of the recognized
    /// person (their match is undone and disputed, the pick learns the voice).
    private func namedUpdate(_ label: String) -> SpeakerNameUpdate? {
        SpeakerNamingPolicy.typedNameUpdate(
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
