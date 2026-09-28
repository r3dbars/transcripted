// SpeakerNamingSheet.swift
// Modal window prompted by TranscriptionTaskManager.$speakerNamingRequest.
// Lets the user name unknown speakers and confirm suggestions after a meeting
// transcript finishes. On close, calls `request.onComplete(updates)` so Core's
// SpeakerNamingCoordinator can write the names back into the transcript.
//
// Pure AppKit — modal sheet over a borderless window. One text field per
// speaker, with a "Save" button that builds `[SpeakerNameUpdate]` and fires
// the completion handler. "Review Later" sends an empty array; Core keeps the
// transcript generic and preserves local review state for the Speakers page.
// A review that arrives while a meeting records waits until that recording
// stops (`SpeakerReviewPresentationGate`), so it never lands mid-call.
// When the meeting started with a calendar event, its invitees show up as
// one-click name buttons on each row (`MeetingInviteeSuggestionPolicy`).
// They are suggestions only and never name anyone on their own.

import AppKit
import Combine
import TranscriptedCore

enum SpeakerNamingHitTargets {
    static let minimum: CGFloat = 40
    static let rowHeight: CGFloat = 136
    static let rowSpacing: CGFloat = 12
    static let sectionHeaderHeight: CGFloat = 40
    static let sectionHeaderGap: CGFloat = 10
    /// Extra row height for the invitee name buttons: one 40pt line plus a gap.
    static let inviteeLineHeight: CGFloat = 48
}

@available(macOS 14.0, *)
@MainActor
final class SpeakerNamingSheet {

    /// One-shot presenter that watches the task manager's `speakerNamingRequest`
    /// and shows a sheet whenever a new request arrives. Created once at app
    /// launch by `TranscriptedApp` and kept alive for the app lifetime.
    static let shared = SpeakerNamingSheet()

    private var subscription: AnyCancellable?
    private var captureSubscription: AnyCancellable?
    private var currentWindowController: NamingWindowController?
    private var latestRequest: SpeakerNamingRequest?
    private var gate = SpeakerReviewPresentationGate()

    /// Wire the presenter to a task manager and to whether a meeting is being
    /// captured. Idempotent — later calls replace the subscriptions.
    func observe(
        taskManager: TranscriptionTaskManager,
        meetingCaptureActive: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher()
    ) {
        subscription = taskManager.$speakerNamingRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let self else { return }
                self.latestRequest = request
                self.apply(self.gate.requestChanged(to: request?.id))
            }
        captureSubscription = meetingCaptureActive
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isActive in
                guard let self else { return }
                self.apply(self.gate.meetingCaptureChanged(isActive: isActive))
            }
    }

    private func apply(_ action: SpeakerReviewPresentationGate.Action) {
        switch action {
        case .keep:
            break
        case .present(let requestID):
            guard let request = latestRequest, request.id == requestID else { return }
            present(request: request)
        case .dismiss:
            dismissCurrentWindowBecauseRequestCleared()
        }
    }

    private func present(request: SpeakerNamingRequest) {
        // Avoid stacking — if a previous sheet is still open, close it first.
        currentWindowController?.close()

        let requestID = request.id
        let controller = NamingWindowController(request: request) { [weak self] in
            guard let self else { return }
            self.gate.windowClosed(requestID: requestID)
            if self.currentWindowController?.requestID == requestID {
                self.currentWindowController = nil
            }
        }
        currentWindowController = controller
        resolveMeetingTitle(for: request, in: controller)
        resolveInvitees(for: request, in: controller)
        controller.window?.center()
        if NSApp.isActive {
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            controller.window?.orderFrontRegardless()
        }
    }

    /// Reads the meeting's name off the main thread and puts it in the
    /// header. The background restyle renames the file (Call_<time>.md →
    /// "<date> <title>.md"), so a missing file is found again by its
    /// transcript id.
    private func resolveMeetingTitle(for request: SpeakerNamingRequest, in controller: NamingWindowController) {
        let requestID = request.id
        let url = request.transcriptURL
        let transcriptID = request.transcriptId
        Task { [weak controller] in
            let title = await Task.detached(priority: .utility) { () -> String? in
                var transcriptURL: URL? = url
                if !FileManager.default.fileExists(atPath: url.path) {
                    transcriptURL = TranscriptSaver.existingTranscriptURL(
                        in: url.deletingLastPathComponent(),
                        transcriptId: transcriptID
                    )
                }
                return transcriptURL.flatMap { MeetingTranscriptStyler.displayTranscriptPreview(at: $0)?.title }
            }.value
            guard let controller, controller.requestID == requestID else { return }
            controller.showMeetingTitle(title)
        }
    }

    /// Looks up who was invited to the calendar event this meeting started
    /// with and offers them as names. Imported recordings are skipped: their
    /// saved time is when the file was made, not a calendar slot.
    private func resolveInvitees(for request: SpeakerNamingRequest, in controller: NamingWindowController) {
        let requestID = request.id
        let url = request.transcriptURL
        let transcriptID = request.transcriptId
        Task { [weak controller] in
            let recording = await Task.detached(priority: .utility) { () -> (start: Date, remoteVoices: Int?)? in
                var transcriptURL: URL? = url
                if !FileManager.default.fileExists(atPath: url.path) {
                    transcriptURL = TranscriptSaver.existingTranscriptURL(
                        in: url.deletingLastPathComponent(),
                        transcriptId: transcriptID
                    )
                }
                guard let transcriptURL,
                      let values = try? TranscriptFrontmatter.readValues(from: transcriptURL),
                      values["imported_at"] == nil,
                      let start = TranscriptFrontmatter.recordedAt(values: values) else { return nil }
                return (start, values["system_speakers"].flatMap { Int($0) })
            }.value
            guard let recording else { return }
            let names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: recording.start)
            guard !names.isEmpty, let controller, controller.requestID == requestID else { return }
            controller.showInvitees(names, remoteVoicesInMeeting: recording.remoteVoices)
        }
    }

    private func dismissCurrentWindowBecauseRequestCleared() {
        currentWindowController?.closeWithoutCompleting()
        currentWindowController = nil
    }
}

// MARK: - Window controller

@available(macOS 14.0, *)
@MainActor
final class NamingWindowController: NSWindowController, NSWindowDelegate {

    private let request: SpeakerNamingRequest
    private let onClose: () -> Void
    private let contentView: SpeakerNamingContentView
    private var didComplete = false

    var requestID: UUID { request.id }

    init(request: SpeakerNamingRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose

        let frame = NSRect(x: 0, y: 0, width: 620, height: 520)
        self.contentView = SpeakerNamingContentView(frame: frame, request: request)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Review speakers"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        // Speaker review can contain transcript excerpts and real names.
        window.sharingType = .none

        super.init(window: window)
        window.delegate = self

        contentView.onSave = { [weak self] updates in
            self?.finish(with: updates)
        }
        contentView.onCancel = { [weak self] in
            self?.finish(with: [])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if !didComplete {
            request.onComplete([])
            didComplete = true
        }
        SpeakerClipPlayback.stop()
        onClose()
    }

    func closeWithoutCompleting() {
        didComplete = true
        close()
    }

    func showMeetingTitle(_ meetingTitle: String?) {
        contentView.showMeetingTitle(meetingTitle)
    }

    func showInvitees(_ inviteeNames: [String], remoteVoicesInMeeting: Int?) {
        contentView.showInvitees(inviteeNames, remoteVoicesInMeeting: remoteVoicesInMeeting)
    }

    private func finish(with updates: [SpeakerNameUpdate]) {
        guard !didComplete else { return }
        didComplete = true
        request.onComplete(updates)
        close()
    }
}

// MARK: - Content view

@available(macOS 14.0, *)
@MainActor
final class SpeakerNamingContentView: NSView {

    private let titleLabel = NSTextField(labelWithString: "Review meeting speakers")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let payoffLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let saveButton = NSButton(title: "Save Names", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Review Later", target: nil, action: nil)

    // Local (mic) section header + "Keep as You" batch toggle
    private let localSectionLabel = NSTextField(labelWithString: "People in the room")
    private let keepAsYouButton = NSButton(title: "Keep as You", target: nil, action: nil)
    // Remote (system) section header
    private let remoteSectionLabel = NSTextField(labelWithString: "Remote participants")

    private let request: SpeakerNamingRequest
    private var micRows: [SpeakerRowView] = []
    private var systemRows: [SpeakerRowView] = []
    private var hasMicSection: Bool = false
    private var hasSystemSection: Bool = false
    private var localCollapsedToMe: Bool = false

    var onSave: (([SpeakerNameUpdate]) -> Void)?
    var onCancel: (() -> Void)?

    init(frame: NSRect, request: SpeakerNamingRequest) {
        self.request = request
        super.init(frame: frame)
        setupViews()
        buildRows()
        trackReviewShown()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showMeetingTitle(_ meetingTitle: String?) {
        titleLabel.stringValue = SpeakerReviewPresentationCopy.title(meetingTitle: meetingTitle)
    }

    /// Adds the calendar invitees to every row. In a 1:1 where the meeting
    /// heard a single unnamed remote voice, that voice gets the other
    /// invitee's name filled in; the user still presses Save.
    func showInvitees(_ inviteeNames: [String], remoteVoicesInMeeting: Int?) {
        guard !inviteeNames.isEmpty else { return }
        let prefill = MeetingInviteeSuggestionPolicy.oneOnOnePrefill(
            inviteeNames: inviteeNames,
            remoteVoicesInMeeting: remoteVoicesInMeeting,
            remoteRowsInReview: systemRows.count,
            remoteRowHasSuggestion: systemRows.first?.hasSuggestedName ?? false
        )
        for row in micRows + systemRows {
            row.showInvitees(inviteeNames, prefillName: systemRows.first === row ? prefill : nil)
        }
        needsLayout = true
    }

    private func setupViews() {
        wantsLayer = true

        assignAutomationIdentifier("transcripted.speaker-review.save-names", to: saveButton)
        assignAutomationIdentifier("transcripted.speaker-review.review-later", to: cancelButton)
        assignAutomationIdentifier("transcripted.speaker-review.keep-local-mic-as-you", to: keepAsYouButton)

        // Name the meeting: with back-to-back calls several reviews can queue
        // up, and "Review meeting speakers" alone doesn't say which one.
        // The meeting's name is filled in by `showMeetingTitle` once it has
        // been read off the main thread.
        titleLabel.stringValue = SpeakerReviewPresentationCopy.title(meetingTitle: nil)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.stringValue = SpeakerReviewPresentationCopy.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        payoffLabel.stringValue = payoffText
        payoffLabel.font = NSFont.systemFont(ofSize: 11)
        payoffLabel.textColor = NSColor.secondaryLabelColor
        payoffLabel.isHidden = payoffText.isEmpty
        addSubview(payoffLabel)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        addSubview(saveButton)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.toolTip = "Keep unresolved speaker labels for now and finish them later on the Speakers page"
        addSubview(cancelButton)

        // Section headers live inside the document view so they scroll with rows.
        localSectionLabel.stringValue = "Local mic voices"
        localSectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        localSectionLabel.textColor = NSColor.labelColor
        remoteSectionLabel.stringValue = "Remote participants"
        remoteSectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        remoteSectionLabel.textColor = NSColor.labelColor

        keepAsYouButton.bezelStyle = .rounded
        keepAsYouButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        keepAsYouButton.toolTip = "Use one \"You\" label for everyone picked up by the local microphone"
        keepAsYouButton.target = self
        keepAsYouButton.action = #selector(handleKeepAsYouToggle)
    }

    private func assignAutomationIdentifier(_ rawValue: String, to view: NSView) {
        view.identifier = NSUserInterfaceItemIdentifier(rawValue)
        view.setAccessibilityIdentifier(rawValue)
    }

    private func buildRows() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        micRows.removeAll()
        systemRows.removeAll()
        localCollapsedToMe = false

        // Most informative question first: doubtful suggestions lead, so the
        // user's first tap is the one that teaches the matcher the most.
        let micEntries = SpeakerReviewPrioritizer.ranked(request.speakers.filter { $0.channel == .mic })
        let systemEntries = SpeakerReviewPrioritizer.ranked(request.speakers.filter { $0.channel == .system })
        hasMicSection = !micEntries.isEmpty
        hasSystemSection = !systemEntries.isEmpty

        // Mic section: header with "Keep as You" toggle + mic rows
        if hasMicSection {
            documentView.addSubview(localSectionLabel)
            documentView.addSubview(keepAsYouButton)
            keepAsYouButton.title = "Keep Local Mic as You"
            for entry in micEntries {
                let row = SpeakerRowView(entry: entry, knownPeople: request.knownPeople)
                documentView.addSubview(row)
                micRows.append(row)
            }
        }

        // System section: header (only if BOTH sections shown) + system rows
        if hasSystemSection {
            if hasMicSection {
                documentView.addSubview(remoteSectionLabel)
            }
            for entry in systemEntries {
                let row = SpeakerRowView(entry: entry, knownPeople: request.knownPeople)
                documentView.addSubview(row)
                systemRows.append(row)
            }
        }
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let contentWidth = bounds.width - pad * 2

        titleLabel.frame = NSRect(
            x: pad,
            y: bounds.height - pad - 24,
            width: contentWidth,
            height: 24
        )
        subtitleLabel.frame = NSRect(
            x: pad,
            y: titleLabel.frame.minY - 18,
            width: contentWidth,
            height: 16
        )

        // Buttons at bottom-right.
        let btnH = SpeakerNamingHitTargets.minimum
        let saveSize = saveButton.fittingSize
        let cancelSize = cancelButton.fittingSize
        saveButton.frame = NSRect(
            x: bounds.width - pad - saveSize.width,
            y: pad,
            width: saveSize.width,
            height: btnH
        )
        cancelButton.frame = NSRect(
            x: saveButton.frame.minX - 8 - cancelSize.width,
            y: pad,
            width: cancelSize.width,
            height: btnH
        )

        // Payoff line sits bottom-left, vertically centered against the buttons.
        payoffLabel.frame = NSRect(
            x: pad,
            y: pad + (btnH - 16) / 2,
            width: max(0, cancelButton.frame.minX - 12 - pad),
            height: 16
        )

        // Scroll view fills the middle.
        let scrollTop = subtitleLabel.frame.minY - 12
        let scrollBottom = saveButton.frame.maxY + 12
        let scrollHeight = max(0, scrollTop - scrollBottom)
        scrollView.frame = NSRect(
            x: pad,
            y: scrollBottom,
            width: contentWidth,
            height: scrollHeight
        )

        // Layout rows + section headers inside the document view. Flipped coordinates:
        // rows stack top-down visually, laid out with bottom-up math.
        let rowHeight = SpeakerNamingHitTargets.rowHeight
        let rowSpacing = SpeakerNamingHitTargets.rowSpacing
        let headerHeight = SpeakerNamingHitTargets.sectionHeaderHeight
        let headerGap = SpeakerNamingHitTargets.sectionHeaderGap

        var docHeight: CGFloat = 0
        if hasMicSection {
            docHeight += headerHeight + headerGap
            docHeight += micRows.reduce(CGFloat(0)) { $0 + rowHeight + $1.extraHeight + rowSpacing }
        }
        if hasSystemSection {
            if hasMicSection {
                docHeight += headerHeight + headerGap
            }
            docHeight += systemRows.reduce(CGFloat(0)) { $0 + rowHeight + $1.extraHeight + rowSpacing }
        }
        docHeight = max(scrollView.frame.height, docHeight)

        documentView.frame = NSRect(
            x: 0, y: 0,
            width: scrollView.frame.width,
            height: docHeight
        )

        var y = docHeight
        let docInnerWidth = documentView.frame.width

        // Mic section
        if hasMicSection {
            y -= headerHeight
            let btnSize = keepAsYouButton.fittingSize
            let btnW = max(110, btnSize.width + 12)
            localSectionLabel.frame = NSRect(
                x: 0,
                y: y + 10,
                width: docInnerWidth - btnW - 8,
                height: 20
            )
            keepAsYouButton.frame = NSRect(
                x: docInnerWidth - btnW,
                y: y,
                width: btnW,
                height: headerHeight
            )
            y -= headerGap

            for row in micRows {
                y -= rowHeight + row.extraHeight
                row.frame = NSRect(x: 0, y: y, width: docInnerWidth, height: rowHeight + row.extraHeight)
                y -= rowSpacing
            }
        }

        // System section
        if hasSystemSection {
            if hasMicSection {
                y -= headerHeight
                remoteSectionLabel.frame = NSRect(x: 0, y: y + 10, width: docInnerWidth, height: 20)
                y -= headerGap
            }
            for row in systemRows {
                y -= rowHeight + row.extraHeight
                row.frame = NSRect(x: 0, y: y, width: docInnerWidth, height: rowHeight + row.extraHeight)
                y -= rowSpacing
            }
        }
    }

    // MARK: - Actions

    @objc private func handleSave() {
        var updates: [SpeakerNameUpdate] = []
        if localCollapsedToMe {
            // Emit a .collapsedToMe update for every mic row, regardless of whether
            // the user typed a name. The coordinator treats this as "don't rename,
            // delete newly-created profiles instead."
            for row in micRows {
                updates.append(row.buildCollapsedToMeUpdate())
            }
        } else {
            for row in micRows {
                guard let update = row.buildUpdate() else { continue }
                updates.append(update)
            }
        }
        for row in systemRows {
            guard let update = row.buildUpdate() else { continue }
            updates.append(update)
        }
        trackReviewSubmitted(completionKind: "save", updateCount: updates.count)
        trackMatchReviewOutcomes(updates)
        onSave?(updates)
    }

    @objc private func handleCancel() {
        trackReviewSubmitted(completionKind: "review_later", updateCount: 0)
        onCancel?()
    }

    @objc private func handleKeepAsYouToggle() {
        localCollapsedToMe.toggle()
        keepAsYouButton.title = localCollapsedToMe ? "Review Local Mic Voices" : "Keep Local Mic as You"
        for row in micRows {
            row.setCollapsedToMe(localCollapsedToMe)
        }
    }

    private func trackReviewShown() {
        AnalyticsReporter.track(
            "meeting_speaker_review_shown",
            properties: speakerReviewAnalyticsProperties()
        )
    }

    private func trackReviewSubmitted(completionKind: String, updateCount: Int) {
        var properties = speakerReviewAnalyticsProperties()
        properties["completion_kind"] = completionKind
        properties["result"] = updateCount > 0 ? "updates_submitted" : "no_updates"
        properties["updates_submitted_bucket"] = AnalyticsReporter.countBucket(updateCount)
        AnalyticsReporter.track(
            "meeting_speaker_review_submitted",
            properties: properties
        )
    }

    private func speakerReviewAnalyticsProperties() -> [String: String] {
        [
            "known_people_bucket": AnalyticsReporter.countBucket(request.knownPeople.count),
            "local_voice_bucket": AnalyticsReporter.countBucket(micRows.count),
            "match_suggestion_bucket": AnalyticsReporter.countBucket(suggestedMatchCount),
            "remote_voice_bucket": AnalyticsReporter.countBucket(systemRows.count),
            "review_item_bucket": AnalyticsReporter.countBucket(micRows.count + systemRows.count),
            "review_reason": reviewReason,
            "surface": "speaker_review_sheet",
        ]
    }

    /// One bucketed event per verdict, joining the matcher's confidence to the
    /// user's answer. This is the fleet-wide accuracy signal: correction rate
    /// by similarity/margin bucket is what retunes the auto-accept gates.
    /// Only enum buckets are sent — no names, ids, or raw scores.
    private func trackMatchReviewOutcomes(_ updates: [SpeakerNameUpdate]) {
        let entriesByKey = Dictionary(
            request.speakers.map { ($0.channel.speakerKey(diarizerSpeakerId: $0.diarizerSpeakerId), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for update in updates {
            // Shared Core mapping — the same one the coordinator uses for the
            // local lifeline store — so PostHog and speaker-stats can never
            // classify one verdict differently.
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
                    "surface": "speaker_review_sheet",
                ]
            )
        }
    }

    private var payoffText: String {
        let count = request.recognizedPeopleCount
        guard count > 0 else { return "" }
        let people = count == 1 ? "1 person" : "\(count) people"
        return "Transcripted recognizes \(people) automatically — confirming teaches it new voices."
    }

    private var suggestedMatchCount: Int {
        request.speakers.filter { $0.suggestedProfileId != nil }.count
    }

    private var reviewReason: String {
        let needsNaming = request.speakers.contains { $0.needsNaming }
        let needsConfirmation = request.speakers.contains { $0.needsConfirmation }
        switch (needsNaming, needsConfirmation) {
        case (true, true):
            return "mixed"
        case (true, false):
            return "needs_naming"
        case (false, true):
            return "needs_confirmation"
        case (false, false):
            return "unknown"
        }
    }
}

// MARK: - Name field

@available(macOS 14.0, *)
private final class SpeakerNameComboBox: RetainedDataSourceComboBox {
    var onTextAreaClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedTextArea = point.x < bounds.maxX - 24
        super.mouseDown(with: event)

        guard clickedTextArea else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onTextAreaClick?()
        }
    }
}

@available(macOS 14.0, *)
private final class NonExpandingTextFieldCell: NSTextFieldCell {
    override func expansionFrame(withFrame cellFrame: NSRect, in view: NSView) -> NSRect {
        .zero
    }
}

// MARK: - One speaker row

@available(macOS 14.0, *)
@MainActor
final class SpeakerRowView: NSView {

    private let entry: SpeakerNamingEntry
    private let knownPeopleByLabel: [String: SpeakerIdentityOption]
    private var knownPeopleLabels: [String]
    private let labelField = NSTextField(labelWithString: "")
    private let evidenceField = NSTextField(labelWithString: "")
    private let sampleField = NSTextField(wrappingLabelWithString: "")
    private let nameField = SpeakerNameComboBox(frame: .zero)
    private let playButton = NSButton(title: "Play sample", target: nil, action: nil)
    private let confirmButton = NSButton(title: "Confirm Match", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard Voice", target: nil, action: nil)
    private let inviteeLabel = NSTextField(labelWithString: "Invited:")
    private var inviteeButtons: [NSButton] = []
    private var inviteeLabels: [String] = []
    private var prefilledFromInvite = false

    private var userConfirmed: Bool = false
    private var isDiscarded: Bool = false
    private var isCollapsedToMe: Bool = false
    private let statusOverlay = NSTextField(labelWithString: "")
    private var playbackObserver: NSObjectProtocol?
    private var playbackTimer: Timer?
    private var isOpeningNameTray = false

    init(entry: SpeakerNamingEntry, knownPeople: [SpeakerIdentityOption]) {
        self.entry = entry
        let optionLabels = SpeakerNameSelectionPolicy.makeIdentityLabels(
            for: knownPeople.filter { $0.id != entry.id },
            id: { $0.id },
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        self.knownPeopleByLabel = optionLabels.lookup
        if entry.channel == .mic,
           !optionLabels.labels.contains(where: { SpeakerNameSelectionPolicy.isOwnerLabel($0) }) {
            self.knownPeopleLabels = [SpeakerNameSelectionPolicy.ownerLabel] + optionLabels.labels
        } else {
            self.knownPeopleLabels = optionLabels.labels
        }
        super.init(frame: .zero)
        setupViews()
    }

    deinit {
        if let playbackObserver {
            NotificationCenter.default.removeObserver(playbackObserver)
        }
        playbackTimer?.invalidate()
    }

    /// Height this row needs beyond `SpeakerNamingHitTargets.rowHeight`.
    var extraHeight: CGFloat {
        inviteeButtons.isEmpty ? 0 : SpeakerNamingHitTargets.inviteeLineHeight
    }

    var hasSuggestedName: Bool { currentName != nil }

    /// Shows the calendar invitees as one-click name buttons, moves them to
    /// the top of the name list, and fills in `prefillName` when the row is
    /// still untouched.
    func showInvitees(_ inviteeNames: [String], prefillName: String?) {
        inviteeLabels = MeetingInviteeSuggestionPolicy.suggestionLabels(
            inviteeNames: inviteeNames,
            labels: knownPeopleLabels,
            optionsByLabel: knownPeopleByLabel,
            displayName: { $0.displayName }
        )
        knownPeopleLabels = MeetingInviteeSuggestionPolicy.labelsWithInviteesFirst(
            labels: knownPeopleLabels,
            inviteeLabels: inviteeLabels
        )
        nameField.numberOfVisibleItems = min(max(knownPeopleLabels.count, 4), 8)
        nameField.reloadData()

        inviteeButtons.forEach { $0.removeFromSuperview() }
        inviteeButtons = inviteeLabels.enumerated().map { index, label in
            let button = NSButton(title: label, target: self, action: #selector(handleInviteePick(_:)))
            button.bezelStyle = .inline
            button.tag = index
            button.toolTip = "Use \(label) for this voice. They were on the calendar invite."
            assignAutomationIdentifier("transcripted.speaker-review.row.invitee.\(index)", to: button)
            addSubview(button)
            return button
        }
        if inviteeLabel.superview == nil, !inviteeButtons.isEmpty {
            inviteeLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            inviteeLabel.textColor = NSColor.secondaryLabelColor
            Self.disableExpansionFrame(for: inviteeLabel)
            addSubview(inviteeLabel)
        }

        if let prefillName,
           nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !userConfirmed, !isDiscarded, !isCollapsedToMe {
            let label = MeetingInviteeSuggestionPolicy.suggestionLabels(
                inviteeNames: [prefillName],
                labels: knownPeopleLabels,
                optionsByLabel: knownPeopleByLabel,
                displayName: { $0.displayName }
            ).first ?? prefillName
            nameField.stringValue = label
            prefilledFromInvite = true
            evidenceField.stringValue = evidenceDescription()
        }
        updateStatePresentation()
    }

    /// Apply or lift the "Keep as You" visual state. Called by the content view when
    /// the batch toggle is clicked.
    func setCollapsedToMe(_ collapsed: Bool) {
        isCollapsedToMe = collapsed
        updateStatePresentation()
    }

    /// Emit a SpeakerNameUpdate with `.collapsedToMe` for this row. Always used when
    /// the batch "Keep as You" toggle is on; the coordinator treats this as "delete
    /// newly-created mic profile, rewrite transcript back to 'You'."
    func buildCollapsedToMeUpdate() -> SpeakerNameUpdate {
        return SpeakerNameUpdate(
            persistentSpeakerId: entry.id,
            diarizerSpeakerId: entry.diarizerSpeakerId,
            channel: entry.channel,
            newName: "You",
            previousName: entry.currentName,
            action: .collapsedToMe
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        updateSurfaceColors()

        labelField.stringValue = reviewTitle
        labelField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        labelField.textColor = NSColor.labelColor
        Self.disableExpansionFrame(for: labelField)
        addSubview(labelField)

        evidenceField.stringValue = evidenceDescription()
        evidenceField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        evidenceField.textColor = NSColor.secondaryLabelColor
        Self.disableExpansionFrame(for: evidenceField)
        addSubview(evidenceField)

        sampleField.stringValue = "\u{201C}\(entry.sampleText)\u{201D}"
        sampleField.font = NSFont.systemFont(ofSize: 11)
        sampleField.textColor = NSColor.secondaryLabelColor
        sampleField.maximumNumberOfLines = 2
        sampleField.lineBreakMode = .byWordWrapping
        Self.disableExpansionFrame(for: sampleField)
        addSubview(sampleField)

        nameField.isEditable = true
        // The box owns a small forwarding source that only weakly points back
        // at this row, so AppKit's unretained data source pointer never dangles.
        nameField.setRetainedDataSource(SpeakerRowNameDataSource(row: self))
        nameField.delegate = self
        nameField.completes = true
        nameField.numberOfVisibleItems = min(max(knownPeopleLabels.count, 4), 8)
        nameField.font = NSFont.systemFont(ofSize: 12)
        nameField.placeholderString = namePlaceholder
        nameField.toolTip = "Type a new name, choose an existing person, or leave it blank to skip this row"
        assignAutomationIdentifier("transcripted.speaker-review.row.name", to: nameField)
        nameField.onTextAreaClick = { [weak self] in
            self?.openNameTray()
        }
        addSubview(nameField)

        playButton.bezelStyle = .rounded
        playButton.toolTip = "Play this short speaker sample"
        assignAutomationIdentifier("transcripted.speaker-review.row.play-sample", to: playButton)
        playButton.target = self
        playButton.action = #selector(handlePlaySample)
        addSubview(playButton)

        confirmButton.bezelStyle = .inline
        assignAutomationIdentifier("transcripted.speaker-review.row.confirm-match", to: confirmButton)
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirm)
        confirmButton.isHidden = !(entry.needsConfirmation && entry.currentName != nil)
        if let current = entry.currentName, !current.isEmpty {
            confirmButton.title = "Confirm Match"
            confirmButton.toolTip = "Use \(current) as the speaker for this row"
        }
        addSubview(confirmButton)

        discardButton.bezelStyle = .inline
        assignAutomationIdentifier("transcripted.speaker-review.row.discard-voice", to: discardButton)
        discardButton.target = self
        discardButton.action = #selector(handleDiscardToggle)
        discardButton.toolTip = "Do not save this voice to People. The transcript stays saved."
        addSubview(discardButton)

        statusOverlay.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusOverlay.textColor = NSColor.secondaryLabelColor
        Self.disableExpansionFrame(for: statusOverlay)
        statusOverlay.isHidden = true
        addSubview(statusOverlay)

        playbackObserver = NotificationCenter.default.addObserver(
            forName: SpeakerClipPlayback.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncPlayButtonState()
            }
        }
    }

    private func assignAutomationIdentifier(_ rawValue: String, to view: NSView) {
        view.identifier = NSUserInterfaceItemIdentifier(rawValue)
        view.setAccessibilityIdentifier(rawValue)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSurfaceColors()
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let w = bounds.width - pad * 2

        let playSize = playButton.fittingSize
        labelField.frame = NSRect(
            x: pad,
            y: bounds.height - pad - 18,
            width: max(120, w - playSize.width - 8),
            height: 18
        )
        let hitTarget = SpeakerNamingHitTargets.minimum
        playButton.frame = NSRect(
            x: bounds.width - pad - max(92, playSize.width),
            y: bounds.height - pad - hitTarget,
            width: max(92, playSize.width),
            height: hitTarget
        )
        evidenceField.frame = NSRect(
            x: pad,
            y: labelField.frame.minY - 18,
            width: w,
            height: 16
        )
        sampleField.frame = NSRect(
            x: pad,
            y: evidenceField.frame.minY - 30,
            width: w,
            height: 26
        )

        let fieldH = SpeakerNamingHitTargets.minimum
        let discardSize = discardButton.fittingSize
        let discardW = max(72, discardSize.width + 8)
        discardButton.frame = NSRect(
            x: bounds.width - pad - discardW,
            y: pad,
            width: discardW,
            height: fieldH
        )

        var fieldRightEdge = discardButton.frame.minX - 8
        if !confirmButton.isHidden {
            let btnSize = confirmButton.fittingSize
            let btnW = max(102, btnSize.width + 4)
            confirmButton.frame = NSRect(
                x: fieldRightEdge - btnW,
                y: pad,
                width: btnW,
                height: fieldH
            )
            fieldRightEdge = confirmButton.frame.minX - 8
        }

        nameField.frame = NSRect(
            x: pad,
            y: pad,
            width: max(120, fieldRightEdge - pad),
            height: fieldH
        )
        statusOverlay.frame = NSRect(
            x: nameField.frame.minX,
            y: nameField.frame.minY + 1,
            width: nameField.frame.width,
            height: fieldH
        )
        layoutInviteeButtons(y: nameField.frame.maxY + 8, height: fieldH)
    }

    /// One line of invitee name buttons above the name box. Buttons that
    /// don't fit are left off; the names are still first in the name list.
    private func layoutInviteeButtons(y: CGFloat, height: CGFloat) {
        guard !inviteeButtons.isEmpty else { return }
        let pad: CGFloat = 12
        let labelWidth = inviteeLabel.fittingSize.width
        inviteeLabel.frame = NSRect(x: pad, y: y + (height - 16) / 2, width: labelWidth, height: 16)
        var x = inviteeLabel.frame.maxX + 6
        for button in inviteeButtons {
            let width = min(button.fittingSize.width + 12, 180)
            let fits = x + width <= bounds.width - pad
            button.isHidden = !fits
            if fits {
                button.frame = NSRect(x: x, y: y, width: width, height: height)
                x += width + 6
            }
        }
    }

    @objc private func handlePlaySample() {
        SpeakerClipPlayback.play(entry.clipURL)
        syncPlayButtonState()
        updatePlaybackPolling()
    }

    @objc private func handleInviteePick(_ sender: NSButton) {
        guard inviteeLabels.indices.contains(sender.tag),
              !isDiscarded, !isCollapsedToMe else { return }
        let label = inviteeLabels[sender.tag]
        nameField.stringValue = label
        // A picked name wins over an earlier Confirm Match, same as typing.
        if userConfirmed, SpeakerNameSelectionPolicy.normalizedSearchText(label)
            != SpeakerNameSelectionPolicy.normalizedSearchText(currentName ?? "") {
            userConfirmed = false
            confirmButton.title = "Confirm Match"
        }
        prefilledFromInvite = false
        evidenceField.stringValue = evidenceDescription()
    }

    fileprivate func clearInvitePrefillNote() {
        guard prefilledFromInvite else { return }
        prefilledFromInvite = false
        evidenceField.stringValue = evidenceDescription()
    }

    @objc private func handleConfirm() {
        userConfirmed = true
        isDiscarded = false
        if let current = entry.currentName {
            nameField.stringValue = current
        }
        confirmButton.title = "Match Confirmed"
        updateStatePresentation()
    }

    @objc private func handleDiscardToggle() {
        guard !isCollapsedToMe else { return }
        isDiscarded.toggle()
        if isDiscarded {
            userConfirmed = false
            SpeakerClipPlayback.stop()
        }
        updateStatePresentation()
    }

    /// Build a `SpeakerNameUpdate` reflecting the user's input for this row.
    /// Returns nil if the row has nothing to save (empty name, no confirmation).
    func buildUpdate() -> SpeakerNameUpdate? {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if isDiscarded {
            return SpeakerNameUpdate(
                persistentSpeakerId: entry.id,
                diarizerSpeakerId: entry.diarizerSpeakerId,
                channel: entry.channel,
                newName: entry.currentName ?? "Speaker \(entry.diarizerSpeakerId)",
                previousName: entry.currentName,
                action: .discardedFromDatabase
            )
        }

        if userConfirmed, let current = entry.currentName, !current.isEmpty {
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

        guard !typed.isEmpty else { return nil }
        return SpeakerNamingPolicy.typedNameUpdate(
            entry: entry,
            typedName: typed,
            optionsByLabel: knownPeopleByLabel
        )
    }

    private func updateStatePresentation() {
        let locked = isCollapsedToMe || isDiscarded
        nameField.isHidden = locked
        nameField.isEnabled = !locked
        statusOverlay.isHidden = !locked

        if isCollapsedToMe {
            statusOverlay.stringValue = "Will be saved as \"You\""
        } else if isDiscarded {
            statusOverlay.stringValue = "Will not be saved to People"
        }

        confirmButton.isEnabled = !locked
        inviteeButtons.forEach { $0.isEnabled = !locked }
        discardButton.isEnabled = !isCollapsedToMe
        discardButton.title = isDiscarded ? "Undo Discard" : "Discard Voice"
        alphaValue = locked ? 0.62 : 1.0
        needsLayout = true
    }

    private func syncPlayButtonState() {
        let isPlaying = SpeakerClipPlayback.isPlaying(entry.clipURL)
        playButton.title = isPlaying ? "Stop sample" : "Play sample"
    }

    private func updatePlaybackPolling() {
        playbackTimer?.invalidate()
        guard SpeakerClipPlayback.isPlaying(entry.clipURL) else {
            playbackTimer = nil
            return
        }

        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.syncPlayButtonState()
                if !SpeakerClipPlayback.isPlaying(self.entry.clipURL) {
                    timer.invalidate()
                    self.playbackTimer = nil
                }
            }
        }
    }

    private func openNameTray() {
        guard nameField.isEnabled, !knownPeopleLabels.isEmpty, !isOpeningNameTray else { return }
        isOpeningNameTray = true
        nameField.reloadData()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isOpeningNameTray = false }
            guard self.nameField.isEnabled else { return }
            self.nameField.performClick(nil)
        }
    }

    fileprivate func completedKnownPersonLabel(for string: String) -> String? {
        SpeakerNameSelectionPolicy.completedLabel(
            for: string,
            labels: knownPeopleLabels,
            optionsByLabel: knownPeopleByLabel,
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
    }

    fileprivate func visibleKnownPeopleLabels() -> [String] {
        let query = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return knownPeopleLabels }
        return SpeakerNameSelectionPolicy.sortedLabels(
            matching: query,
            labels: knownPeopleLabels,
            optionsByLabel: knownPeopleByLabel,
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
    }

    private func updateSurfaceColors() {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.055)
            : NSColor.controlBackgroundColor
        let border = dark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.08)

        // Dynamic NSColors otherwise resolve against the calling thread's
        // appearance, which can be dark even while this sheet is light.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = background.cgColor
            layer.borderColor = border.cgColor
        }
    }

    private static func disableExpansionFrame(for field: NSTextField) {
        let font = field.font
        let textColor = field.textColor
        let alignment = field.alignment
        let lineBreakMode = field.lineBreakMode
        let wraps = field.cell?.wraps ?? false
        let cell = NonExpandingTextFieldCell(textCell: field.stringValue)
        cell.wraps = wraps
        cell.lineBreakMode = lineBreakMode
        field.cell = cell
        field.font = font
        field.textColor = textColor
        field.alignment = alignment
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
    }

    private func evidenceDescription() -> String {
        if prefilledFromInvite {
            return "Filled in from your calendar invite. Check it, then save."
        }
        var parts: [String] = []
        if let similarity = entry.matchSimilarity {
            parts.append("\(Int((similarity * 100).rounded()))% match")
        }
        if entry.callCount > 0 {
            let calls = entry.callCount == 1 ? "1 call" : "\(entry.callCount) calls"
            parts.append("seen in \(calls)")
        }
        let evidence = parts.joined(separator: " • ")
        if evidence.isEmpty { return reviewInstruction }
        return "\(reviewInstruction) \(evidence)."
    }

    private var reviewTitle: String {
        let voiceLabel = entry.channel == .mic ? "local mic speaker" : "remote speaker"
        guard let currentName else {
            return "Unknown \(voiceLabel) \(entry.diarizerSpeakerId)"
        }
        return "Suggested \(voiceLabel): \(currentName)"
    }

    private var reviewInstruction: String {
        if let currentName {
            return "Confirm this is \(currentName), or type the correct person."
        }
        if entry.channel == .mic {
            return "Name this local voice, choose You, or discard it."
        }
        return "Name this remote voice, choose a saved person, or discard it."
    }

    private var namePlaceholder: String {
        if entry.channel == .mic, currentName == nil {
            return "Type a name, choose You, or pick a saved person"
        }
        if currentName != nil {
            return "Wrong match? Type the correct person"
        }
        return "Type a name or choose a saved person"
    }

    private var currentName: String? {
        let trimmed = entry.currentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Name-box data source for one review row. The box keeps this alive; it only
/// weakly points back at the row, so a row that is gone answers with no items.
@available(macOS 14.0, *)
@MainActor
private final class SpeakerRowNameDataSource: NSObject, NSComboBoxDataSource {
    private weak var row: SpeakerRowView?

    init(row: SpeakerRowView) {
        self.row = row
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int {
        row?.visibleKnownPeopleLabels().count ?? 0
    }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        guard let labels = row?.visibleKnownPeopleLabels(),
              labels.indices.contains(index) else { return nil }
        return labels[index]
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        row?.completedKnownPersonLabel(for: string)
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        row?.visibleKnownPeopleLabels().firstIndex(of: string) ?? NSNotFound
    }
}

@available(macOS 14.0, *)
extension SpeakerRowView: NSComboBoxDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as AnyObject? === nameField else { return }
        openNameTray()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as AnyObject? === nameField else { return }
        nameField.reloadData()
        clearInvitePrefillNote()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return true
        }
        return false
    }
}
