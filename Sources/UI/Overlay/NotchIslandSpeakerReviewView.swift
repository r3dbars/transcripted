// NotchIslandSpeakerReviewView.swift
// "Who spoke?" inside the notch island (Prints.dc.html), in place of the
// speaker review window. It opens by itself after every saved meeting with a
// remote voice. Each voice is a row with the person's voice print on the left
// (play in its middle; one ring lit per confirmed meeting, in the person's
// color; a full print glows):
//
//   - voices Transcripted named on its own show just the name; hovering one
//     offers "Not Taylor?", which turns the title into a name field
//   - when every voice was recognized nothing is asked: the island lists who
//     was on the call and closes itself (Done, or its ring running out)
//   - a likely match reads "Marcus Reed?" with a round ✕ and ✓; ✓ plays the
//     match animation and earns the next ring, Undo takes it back
//   - ✕, or a voice with no guess, makes the title itself the name field
//     ("Who's this?"); with the keyboard the calendar invitees fade in under
//     it as one-tap names (an arrow shows more than three), and typing offers
//     people already saved in Speakers
//   - a calendar 1:1 with one unnamed remote voice fills that voice's field
//     with the other invitee; it saves on Done like a typed name
//   - local mic voices sit under an "All me" toggle; an open name field
//     offers "Not a person" for a voice that isn't one
//
// The footer lists, with glowing dots, the people named automatically on this
// call, then Later and Done. Done saves the answers through the same
// `SpeakerReviewUpdate`s the review window builds, then shows "Everyone's
// named" with Open. Later (or its 20 s ring running out) saves whatever was
// answered and leaves the rest for Speakers. A name typed but not submitted
// counts on both. The ring only runs while the review is on screen. The rules
// live in NotchIslandSpeakerReviewPolicy; rows are NotchIslandVoiceRowView.

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
    var onDone: ((_ updates: [SpeakerReviewUpdate], _ leftForLater: Int) -> Void)?
    /// Later, or the ring ran out: save what was answered, leave the rest.
    var onLater: ((_ updates: [SpeakerReviewUpdate]) -> Void)?
    var onOpenTranscript: (() -> Void)?
    /// "Everyone's named" has been up long enough.
    var onDoneLingerEnded: (() -> Void)?

    let requestID: UUID
    private let request: SpeakerNamingRequest
    let knownPeople: [SpeakerNameChoice]
    private let stack = NSStackView()
    /// The footer's dots and "N people named automatically", refreshed in place.
    let footerSummary = NSStackView()
    /// The dots on screen, by who they stand for, in footer order.
    var footerDots: [(key: String, view: NotchIslandGlowDot)] = []
    /// Dots waiting for their print to re-form before they join.
    var footerLandings: [String: Task<Void, Never>] = [:]
    /// "N people named automatically", the number on its own so it can tick.
    let footerCount = NotchIslandFooterCount()
    let footerSpacer = NSView()
    /// The light tip under a hovered print (one, moved to the print).
    let printTip = NotchIslandPrintTip()
    var tipTop: NSLayoutConstraint?
    var tipLeading: NSLayoutConstraint?
    var tipTask: Task<Void, Never>?
    /// Palette index per claimed person, in row order, so nobody on the call
    /// shares a color.
    var colorIndices: [UUID: Int] = [:]
    /// Everyone who has had a color on this review, in the order they got it
    /// (NotchIslandSpeakerReviewPolicy.colorOrder), so colors stay put.
    var colorOrder: [UUID] = []
    /// Voices the review asks about.
    private(set) var rows: [NotchIslandVoiceRowView] = []
    /// Voices named on their own, listed with a hover correction.
    private(set) var recognizedRows: [NotchIslandVoiceRowView] = []
    /// Recognized names with no clip to correct from (shown, not editable).
    private(set) var plainRecognizedNames: [String] = []
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
        self.knownPeople = request.knownPeople.map {
            SpeakerNameChoice(id: $0.id, displayName: $0.displayName, callCount: $0.callCount, confirmedMeetings: $0.confirmedMeetings, isTrusted: $0.isTrusted, earnsConfirmation: $0.earnsConfirmation)
        }
        self.requestID = request.id
        self.isRecognizedOnly = request.speakers.isEmpty
        super.init(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 10))
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
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
        let ranked = SpeakerReviewBridge.ranked(request.speakers.filter { $0.channel == .system })
            + SpeakerReviewBridge.ranked(request.speakers.filter { $0.channel == .mic })
        rows = ranked.map { makeRow(for: $0, recognized: false) }
        recognizedRows = request.recognizedSpeakers.map { makeRow(for: $0, recognized: true) }
        let correctable = Set(request.recognizedSpeakers.compactMap {
            $0.currentName.map(SpeakerNameSelectionPolicy.normalizedSearchText)
        })
        plainRecognizedNames = request.recognizedSpeakerNames.filter {
            !correctable.contains(SpeakerNameSelectionPolicy.normalizedSearchText($0))
        }
        printTip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(printTip)
        tipTop = printTip.topAnchor.constraint(equalTo: topAnchor)
        tipLeading = printTip.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([tipTop, tipLeading].compactMap { $0 })
        assignColors()
        rebuild()
        // The ring waits until the island reports the review on screen.
        if !isRecognizedOnly { trackShown() }
        scheduleHardCap()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityTitle)
    }

    private func makeRow(for entry: SpeakerNamingEntry, recognized: Bool) -> NotchIslandVoiceRowView {
        let row = NotchIslandVoiceRowView(entry: entry, knownPeople: knownPeople, recognized: recognized)
        row.onChange = { [weak self] in self?.rowChanged() }
        row.onInteract = { [weak self] in self?.stopLaterCountdown() }
        row.onWantsKeyboard = { [weak self] in self?.onWantsKeyboard?() }
        row.onSubmit = { [weak self, weak row] in self?.focusNextOpenRow(after: row) }
        row.onPrintTip = { [weak self] text, anchor in self?.showPrintTip(text, under: anchor) }
        return row
    }

    private var accessibilityTitle: String {
        NotchIslandSpeakerReviewPolicy.accessibilityTitle(meetingTitle: meetingTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        laterTask?.cancel()
        lingerTask?.cancel()
        hardCapTask?.cancel()
        tipTask?.cancel()
        footerLandings.values.forEach { $0.cancel() }
    }

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat { ceil(fittingSize.height) }

    // MARK: Inputs

    func setMeetingTitle(_ title: String?) {
        meetingTitle = title
        guard !isFinished else { return }
        setAccessibilityLabel(accessibilityTitle)
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
        hidePrintTip()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isFinished { return }

        let header = headerLine()
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(14, after: header)

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
                stack.setCustomSpacing(0, after: micHeader)
            }
            stack.addArrangedSubview(row)
            lastRow = row
        }
        refreshInvitees()

        let done = NotchIslandButton(title: "Done", style: .white, height: 34)
        done.onPress = { [weak self] in self?.finishDone() }
        let buttons: NSStackView
        if isRecognizedOnly {
            // Nothing to put off: Done carries the ring and closes the list.
            done.setAccessibilityHelp("Close. Names are already saved.")
            buttons = NSStackView(views: [done])
            startCountdownRing(on: done)
        } else {
            let later = NotchIslandButton(title: "Later", style: .link, height: 30, fontSize: 13)
            later.onPress = { [weak self] in self?.finishLater() }
            later.setAccessibilityHelp("Save what you answered and name the rest later in Speakers.")
            startCountdownRing(on: later)
            buttons = NSStackView(views: [later, done])
        }
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 16
        buttons.setHuggingPriority(.required, for: .horizontal)
        footerSummary.orientation = .horizontal
        footerSummary.alignment = .centerY
        footerSummary.spacing = 8
        footerSummary.setHuggingPriority(.defaultLow, for: .horizontal)
        footerSummary.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerSummary, buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 16
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        stack.setCustomSpacing(18, after: lastRow)
        stack.addArrangedSubview(footer)
        refreshFooterSummary(animated: false)
    }

    /// "Who spoke?" with the meeting's name small and grey on the right.
    private func headerLine() -> NSView {
        let title = NotchIslandPalette.label(
            NotchIslandSpeakerReviewPolicy.headerTitle,
            font: .systemFont(ofSize: 19, weight: .semibold),
            color: NotchIslandPalette.primaryText
        )
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = [title, NSView()]
        if let detail = NotchIslandSpeakerReviewPolicy.headerDetail(meetingTitle: meetingTitle) {
            let meeting = NotchIslandPalette.label(detail, font: .systemFont(ofSize: 12), color: NSColor(white: 1, alpha: 0.4))
            meeting.lineBreakMode = .byTruncatingTail
            meeting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(meeting)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        // VoiceOver reads the review's own label instead.
        line.setAccessibilityElement(false)
        return line
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
            color: NSColor(white: 1, alpha: 0.42)
        )
        let keep = NotchIslandTextButton(
            title: NotchIslandSpeakerReviewPolicy.keepAsYouTitle(keepMicAsYou: keepMicAsYou),
            restAlpha: 0.6
        )
        keep.onPress = { [weak self] in self?.toggleKeepMicAsYou() }
        keep.setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.keepAsYouAccessibilityLabel(keepMicAsYou: keepMicAsYou))
        keep.setAccessibilityHelp(NotchIslandSpeakerReviewPolicy.keepAsYouHelp(keepMicAsYou: keepMicAsYou))
        let line = NSStackView(views: [label, NSView(), keep])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
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
        assignColors()
        rebuild()
        onLayoutChange?()
    }

    private func refreshInvitees() {
        let used = Set((recognizedRows + rows).compactMap(\.chosenName) + plainRecognizedNames)
        for row in recognizedRows + rows {
            row.setInvitees(invitees, alreadyUsed: used)
        }
    }

    private func rowChanged() {
        hidePrintTip()
        refreshInvitees()
        assignColors()
        refreshFooterSummary(animated: true)
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
    ) -> (updates: [SpeakerReviewUpdate], unanswered: Int) {
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
        hidePrintTip()
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
        let open = NotchIslandButton(title: "Open", style: .white, height: 34)
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

    private func trackSubmitted(completionKind: String, updates: [SpeakerReviewUpdate]) {
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
    private func trackMatchOutcomes(_ updates: [SpeakerReviewUpdate]) {
        // Recognized voices too, so a "Not Taylor?" correction reports the
        // match it overrode instead of an empty bucket.
        let key: (SpeakerNamingEntry) -> String = { $0.channel.speakerKey(diarizerSpeakerId: $0.diarizerSpeakerId) }
        let entriesByKey = NotchIslandSpeakerReviewPolicy.entriesByKey(asked: request.speakers, recognized: request.recognizedSpeakers, key: key)
        // Named silently: a correction on one of these is a wrong silent name.
        let autoKeys = NotchIslandSpeakerReviewPolicy.autoRecognizedKeys(asked: request.speakers, recognized: request.recognizedSpeakers, key: key)
        for update in updates {
            guard let kind = SpeakerReviewBridge.matchOutcome(for: update) else { continue }
            let updateKey = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            let entry = entriesByKey[updateKey]
            AnalyticsReporter.track(
                "meeting_speaker_match_reviewed",
                properties: [
                    "auto_recognized": NotchIslandSpeakerReviewPolicy.autoRecognizedProperty(updateKey: updateKey, autoRecognizedKeys: autoKeys),
                    "review_action": kind,
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
