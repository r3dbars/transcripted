// SpeakerNamingSheet.swift
// Modal window prompted by TranscriptionTaskManager.$speakerNamingRequest.
// Lets the user name unknown speakers and confirm suggestions after a meeting
// transcript finishes. On close, calls `request.onComplete(updates)` so Core's
// SpeakerNamingCoordinator can write the names back into the transcript.
//
// Pure AppKit — modal sheet over a borderless window. One text field per
// speaker, with a "Save" button that builds `[SpeakerNameUpdate]` and fires
// the completion handler. "Review Later" sends an empty array; Core keeps the
// transcript generic and preserves local review state for Settings > People.

import AppKit
import Combine
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class SpeakerNamingSheet {

    /// One-shot presenter that watches the task manager's `speakerNamingRequest`
    /// and shows a sheet whenever a new request arrives. Created once at app
    /// launch by `TranscriptedApp` and kept alive for the app lifetime.
    static let shared = SpeakerNamingSheet()

    private var subscription: AnyCancellable?
    private var currentWindowController: NamingWindowController?

    /// Wire the presenter to a task manager. Idempotent — later calls replace
    /// the subscription.
    func observe(taskManager: TranscriptionTaskManager) {
        subscription = taskManager.$speakerNamingRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let self else { return }
                guard let request else {
                    self.dismissCurrentWindowBecauseRequestCleared()
                    return
                }
                self.present(request: request)
            }
    }

    private func present(request: SpeakerNamingRequest) {
        // Avoid stacking — if a previous sheet is still open, close it first.
        currentWindowController?.close()

        let controller = NamingWindowController(request: request) { [weak self] in
            self?.currentWindowController = nil
        }
        currentWindowController = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        window.title = "Name speakers"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.level = .modalPanel

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

    private let titleLabel = NSTextField(labelWithString: "Name the speakers from this meeting")
    private let subtitleLabel = NSTextField(labelWithString: "Transcript saved. Name speakers now, or review them later in Settings > People.")
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let saveButton = NSButton(title: "Save names", target: nil, action: nil)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true

        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        addSubview(subtitleLabel)

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
        cancelButton.toolTip = "Keep the transcript generic and finish speaker names later in Settings > People"
        addSubview(cancelButton)

        // Section headers live inside the document view so they scroll with rows.
        localSectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        localSectionLabel.textColor = NSColor.labelColor
        remoteSectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        remoteSectionLabel.textColor = NSColor.labelColor

        keepAsYouButton.bezelStyle = .rounded
        keepAsYouButton.controlSize = .small
        keepAsYouButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        keepAsYouButton.target = self
        keepAsYouButton.action = #selector(handleKeepAsYouToggle)
    }

    private func buildRows() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        micRows.removeAll()
        systemRows.removeAll()
        localCollapsedToMe = false

        let micEntries = request.speakers.filter { $0.channel == .mic }
        let systemEntries = request.speakers.filter { $0.channel == .system }
        hasMicSection = !micEntries.isEmpty
        hasSystemSection = !systemEntries.isEmpty

        // Mic section: header with "Keep as You" toggle + mic rows
        if hasMicSection {
            documentView.addSubview(localSectionLabel)
            documentView.addSubview(keepAsYouButton)
            keepAsYouButton.title = "Keep mic as You"
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
        let btnH: CGFloat = 28
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
        let rowHeight: CGFloat = 104
        let rowSpacing: CGFloat = 12
        let headerHeight: CGFloat = 24
        let headerGap: CGFloat = 10

        let micCount = micRows.count
        let systemCount = systemRows.count
        var docHeight: CGFloat = 0
        if hasMicSection {
            docHeight += headerHeight + headerGap
            docHeight += CGFloat(micCount) * (rowHeight + rowSpacing)
        }
        if hasSystemSection {
            if hasMicSection {
                docHeight += headerHeight + headerGap
            }
            docHeight += CGFloat(systemCount) * (rowHeight + rowSpacing)
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
                y: y + 2,
                width: docInnerWidth - btnW - 8,
                height: headerHeight - 2
            )
            keepAsYouButton.frame = NSRect(
                x: docInnerWidth - btnW,
                y: y + 1,
                width: btnW,
                height: headerHeight
            )
            y -= headerGap

            for row in micRows {
                y -= rowHeight
                row.frame = NSRect(x: 0, y: y, width: docInnerWidth, height: rowHeight)
                y -= rowSpacing
            }
        }

        // System section
        if hasSystemSection {
            if hasMicSection {
                y -= headerHeight
                remoteSectionLabel.frame = NSRect(x: 0, y: y + 2, width: docInnerWidth, height: headerHeight - 2)
                y -= headerGap
            }
            for row in systemRows {
                y -= rowHeight
                row.frame = NSRect(x: 0, y: y, width: docInnerWidth, height: rowHeight)
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
        onSave?(updates)
    }

    @objc private func handleCancel() {
        onCancel?()
    }

    @objc private func handleKeepAsYouToggle() {
        localCollapsedToMe.toggle()
        keepAsYouButton.title = localCollapsedToMe ? "Split mic speakers" : "Keep mic as You"
        for row in micRows {
            row.setCollapsedToMe(localCollapsedToMe)
        }
    }
}

// MARK: - Name field

@available(macOS 14.0, *)
private final class SpeakerNameComboBox: NSComboBox {
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
    private let knownPeopleLabels: [String]
    private let labelField = NSTextField(labelWithString: "")
    private let evidenceField = NSTextField(labelWithString: "")
    private let sampleField = NSTextField(wrappingLabelWithString: "")
    private let nameField = SpeakerNameComboBox(frame: .zero)
    private let playButton = NSButton(title: "Play sample", target: nil, action: nil)
    private let confirmButton = NSButton(title: "Use Suggested", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)

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

        if let current = entry.currentName, !current.isEmpty {
            labelField.stringValue = "Suggested match: \(current)"
        } else {
            labelField.stringValue = "Speaker \(entry.diarizerSpeakerId)"
        }
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
        nameField.usesDataSource = true
        nameField.dataSource = self
        nameField.delegate = self
        nameField.completes = true
        nameField.numberOfVisibleItems = min(max(knownPeopleLabels.count, 4), 8)
        nameField.font = NSFont.systemFont(ofSize: 12)
        if entry.currentName != nil {
            nameField.placeholderString = "Use the suggestion or choose a different person"
        } else {
            nameField.placeholderString = "Type a new name or choose an existing person"
        }
        nameField.onTextAreaClick = { [weak self] in
            self?.openNameTray()
        }
        addSubview(nameField)

        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(handlePlaySample)
        addSubview(playButton)

        confirmButton.bezelStyle = .inline
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirm)
        confirmButton.isHidden = !(entry.needsConfirmation && entry.currentName != nil)
        if let current = entry.currentName, !current.isEmpty {
            confirmButton.title = "Confirm \(current)"
        }
        addSubview(confirmButton)

        discardButton.bezelStyle = .inline
        discardButton.target = self
        discardButton.action = #selector(handleDiscardToggle)
        discardButton.toolTip = "Leave this voice out of the speaker database"
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
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
        playButton.frame = NSRect(
            x: bounds.width - pad - max(92, playSize.width),
            y: bounds.height - pad - 22,
            width: max(92, playSize.width),
            height: 22
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

        let fieldH: CGFloat = 22
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
    }

    @objc private func handlePlaySample() {
        SpeakerClipPlayback.play(entry.clipURL)
        syncPlayButtonState()
        updatePlaybackPolling()
    }

    @objc private func handleConfirm() {
        userConfirmed = true
        isDiscarded = false
        if let current = entry.currentName {
            nameField.stringValue = current
        }
        confirmButton.title = "Confirmed"
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
            statusOverlay.stringValue = "Will be saved as \u{201C}You\u{201D}"
        } else if isDiscarded {
            statusOverlay.stringValue = "Will be left out of the speaker database"
        }

        confirmButton.isEnabled = !locked
        discardButton.isEnabled = !isCollapsedToMe
        discardButton.title = isDiscarded ? "Undo discard" : "Discard"
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

    private func visibleKnownPeopleLabels() -> [String] {
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

    private func knownPeopleOption(matching input: String) -> SpeakerIdentityOption? {
        SpeakerNameSelectionPolicy.option(
            matching: input,
            optionsByLabel: knownPeopleByLabel,
            displayName: { $0.displayName }
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

        layer.backgroundColor = background.cgColor
        layer.borderColor = border.cgColor
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
        var parts: [String] = []
        if let similarity = entry.matchSimilarity {
            parts.append("\(Int((similarity * 100).rounded()))% match")
        }
        if entry.callCount > 0 {
            let calls = entry.callCount == 1 ? "1 call" : "\(entry.callCount) calls"
            parts.append("seen in \(calls)")
        }
        if parts.isEmpty {
            return entry.needsNaming ? "New speaker" : "Review this match"
        }
        return parts.joined(separator: " • ")
    }
}

@available(macOS 14.0, *)
extension SpeakerRowView: NSComboBoxDataSource, NSComboBoxDelegate {
    func numberOfItems(in comboBox: NSComboBox) -> Int {
        visibleKnownPeopleLabels().count
    }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        let labels = visibleKnownPeopleLabels()
        guard labels.indices.contains(index) else { return nil }
        return labels[index]
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        SpeakerNameSelectionPolicy.completedLabel(
            for: string,
            labels: knownPeopleLabels,
            optionsByLabel: knownPeopleByLabel,
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        visibleKnownPeopleLabels().firstIndex(of: string) ?? NSNotFound
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as AnyObject? === nameField else { return }
        openNameTray()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as AnyObject? === nameField else { return }
        nameField.reloadData()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return true
        }
        return false
    }
}
