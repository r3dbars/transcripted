// SpeakerNamingSheet.swift
// Modal window prompted by TranscriptionTaskManager.$speakerNamingRequest.
// Lets the user name unknown speakers and confirm suggestions after a meeting
// transcript finishes. On close, calls `request.onComplete(updates)` so Core's
// SpeakerNamingCoordinator can write the names back into the transcript.
//
// Pure AppKit — modal sheet over a borderless window. One text field per
// speaker, with a "Save" button that builds `[SpeakerNameUpdate]` and fires
// the completion handler. Cancel sends an empty array (Core treats that as
// "keep the generic Speaker N labels").

import AppKit
import AVFoundation
import Combine
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class SpeakerNamingSheet {

    /// One-shot presenter that watches the task manager's `speakerNamingRequest`
    /// and shows a sheet whenever a new request arrives. Created once at app
    /// launch by `DraftAppDelegate` and kept alive for the app lifetime.
    static let shared = SpeakerNamingSheet()

    private var subscription: AnyCancellable?
    private var currentWindowController: NamingWindowController?

    /// Wire the presenter to a task manager. Idempotent — later calls replace
    /// the subscription.
    func observe(taskManager: TranscriptionTaskManager) {
        subscription = taskManager.$speakerNamingRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let self, let request else { return }
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
}

// MARK: - Window controller

@available(macOS 14.0, *)
@MainActor
final class NamingWindowController: NSWindowController, NSWindowDelegate {

    private let request: SpeakerNamingRequest
    private let onClose: () -> Void
    private let contentView: SpeakerNamingContentView

    init(request: SpeakerNamingRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose

        let frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        self.contentView = SpeakerNamingContentView(frame: frame, request: request)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Name the speakers"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.level = .modalPanel

        super.init(window: window)
        window.delegate = self

        contentView.onSave = { [weak self] updates in
            guard let self else { return }
            self.request.onComplete(updates)
            self.close()
        }
        contentView.onCancel = { [weak self] in
            guard let self else { return }
            self.request.onComplete([])
            self.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Content view

@available(macOS 14.0, *)
@MainActor
final class SpeakerNamingContentView: NSView {

    private let titleLabel = NSTextField(labelWithString: "Who spoke in this meeting?")
    private let subtitleLabel = NSTextField(labelWithString: "Give each voice a name so we can recognize them next time.")
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let saveButton = NSButton(title: "Save names", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Skip", target: nil, action: nil)

    private let request: SpeakerNamingRequest
    private var rows: [SpeakerRowView] = []

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
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        addSubview(saveButton)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        addSubview(cancelButton)
    }

    private func buildRows() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        for entry in request.speakers {
            let row = SpeakerRowView(entry: entry)
            documentView.addSubview(row)
            rows.append(row)
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

        // Layout rows inside the document view (flipped coordinates — rows
        // stack top-down, but we lay them out using bottom-up math since the
        // document view is not flipped).
        let rowHeight: CGFloat = 112
        let rowSpacing: CGFloat = 10
        let docHeight = max(
            scrollView.frame.height,
            CGFloat(rows.count) * (rowHeight + rowSpacing)
        )
        documentView.frame = NSRect(
            x: 0, y: 0,
            width: scrollView.frame.width,
            height: docHeight
        )

        var y = docHeight
        for row in rows {
            y -= rowHeight
            row.frame = NSRect(
                x: 0,
                y: y,
                width: documentView.frame.width,
                height: rowHeight
            )
            y -= rowSpacing
        }
    }

    // MARK: - Actions

    @objc private func handleSave() {
        var updates: [SpeakerNameUpdate] = []
        for row in rows {
            guard let update = row.buildUpdate() else { continue }
            updates.append(update)
        }
        onSave?(updates)
    }

    @objc private func handleCancel() {
        onCancel?()
    }
}

// MARK: - One speaker row

@available(macOS 14.0, *)
@MainActor
final class SpeakerRowView: NSView {

    private let entry: SpeakerNamingEntry
    private let labelField = NSTextField(labelWithString: "")
    private let sampleField = NSTextField(wrappingLabelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let nameField = NSTextField(string: "")
    private let playButton = NSButton(title: "Play clip", target: nil, action: nil)
    private let confirmButton = NSButton(title: "Confirm", target: nil, action: nil)

    private var userConfirmed: Bool = false
    private var audioPlayer: AVAudioPlayer?

    init(entry: SpeakerNamingEntry) {
        self.entry = entry
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        layer?.borderWidth = 1

        if let current = entry.currentName, !current.isEmpty {
            labelField.stringValue = "Possible match: \(current)"
        } else {
            labelField.stringValue = "Speaker \(entry.sortformerSpeakerId)"
        }
        labelField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        labelField.textColor = NSColor.labelColor
        addSubview(labelField)

        sampleField.stringValue = "\u{201C}\(entry.sampleText)\u{201D}"
        sampleField.font = NSFont.systemFont(ofSize: 11)
        sampleField.textColor = NSColor.secondaryLabelColor
        sampleField.maximumNumberOfLines = 2
        sampleField.lineBreakMode = .byTruncatingTail
        addSubview(sampleField)

        detailField.font = NSFont.systemFont(ofSize: 10)
        detailField.textColor = NSColor.tertiaryLabelColor
        detailField.stringValue = detailText(for: entry)
        addSubview(detailField)

        nameField.placeholderString = "Enter name"
        nameField.font = NSFont.systemFont(ofSize: 12)
        if let current = entry.currentName {
            nameField.stringValue = current
        }
        addSubview(nameField)

        playButton.bezelStyle = .inline
        playButton.target = self
        playButton.action = #selector(handlePlay)
        addSubview(playButton)

        confirmButton.bezelStyle = .inline
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirm)
        confirmButton.isHidden = !(entry.needsConfirmation && entry.currentName != nil)
        addSubview(confirmButton)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let w = bounds.width - pad * 2
        let rowGap: CGFloat = 6

        labelField.frame = NSRect(
            x: pad,
            y: bounds.height - pad - 18,
            width: w,
            height: 18
        )
        sampleField.frame = NSRect(
            x: pad,
            y: labelField.frame.minY - 28,
            width: w,
            height: 24
        )
        detailField.frame = NSRect(
            x: pad,
            y: sampleField.frame.minY - 18,
            width: w,
            height: 14
        )

        let fieldH: CGFloat = 22
        let playSize = playButton.fittingSize
        let playWidth = max(72, playSize.width + 12)
        playButton.frame = NSRect(
            x: pad,
            y: pad,
            width: playWidth,
            height: fieldH
        )

        let rightInset: CGFloat
        if !confirmButton.isHidden {
            let btnSize = confirmButton.fittingSize
            let btnW = max(80, btnSize.width)
            confirmButton.frame = NSRect(
                x: bounds.width - pad - btnW,
                y: pad,
                width: btnW,
                height: fieldH
            )
            rightInset = confirmButton.frame.minX - 8
        } else {
            rightInset = bounds.width - pad
        }

        nameField.frame = NSRect(
            x: playButton.frame.maxX + rowGap,
            y: pad,
            width: max(0, rightInset - (playButton.frame.maxX + rowGap)),
            height: fieldH
        )
    }

    deinit {
        audioPlayer?.stop()
    }

    private func detailText(for entry: SpeakerNamingEntry) -> String {
        if let current = entry.currentName, let similarity = entry.matchSimilarity {
            return "Listen to the clip to confirm \(current) (\(Int((similarity * 100).rounded()))% voice match)."
        }
        if let current = entry.currentName {
            return "Listen to the clip to confirm or correct \(current)."
        }
        return "Listen to the clip, then type the speaker's name."
    }

    @objc private func handlePlay() {
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.stop()
            audioPlayer.currentTime = 0
            playButton.title = "Play clip"
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: entry.clipURL)
            audioPlayer = player
            player.delegate = self
            player.prepareToPlay()
            player.play()
            playButton.title = "Stop"
        } catch {
            NSSound.beep()
            playButton.title = "Play clip"
        }
    }

    private func resetPlaybackUI() {
        playButton.title = "Play clip"
    }

    @objc private func handleConfirm() {
        userConfirmed = true
        confirmButton.title = "Confirmed"
        confirmButton.isEnabled = false
    }

    /// Build a `SpeakerNameUpdate` reflecting the user's input for this row.
    /// Returns nil if the row has nothing to save (empty name, no confirmation).
    func buildUpdate() -> SpeakerNameUpdate? {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if userConfirmed, let current = entry.currentName, !current.isEmpty {
            return SpeakerNameUpdate(
                persistentSpeakerId: entry.id,
                sortformerSpeakerId: entry.sortformerSpeakerId,
                newName: current,
                action: .confirmed
            )
        }

        guard !typed.isEmpty else { return nil }

        let action: SpeakerNameUpdate.NamingAction
        if let current = entry.currentName, !current.isEmpty {
            action = typed.caseInsensitiveCompare(current) == .orderedSame
                ? .confirmed
                : .corrected
        } else {
            action = .named
        }

        return SpeakerNameUpdate(
            persistentSpeakerId: entry.id,
            sortformerSpeakerId: entry.sortformerSpeakerId,
            newName: typed,
            action: action
        )
    }
}

@available(macOS 14.0, *)
extension SpeakerRowView: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.resetPlaybackUI()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.resetPlaybackUI()
        }
    }
}
