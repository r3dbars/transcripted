// MenuBarShortcutsView.swift
// Primary action rows for dictation and meeting capture.

import AppKit
import Carbon

@MainActor
final class MenuBarShortcutsView: NSView {
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?

    private let dictationRow = PrimaryActionRowView()
    private let meetingRow = PrimaryActionRowView()
    private var keyMonitor: Any?
    private var recordingTarget: RecordingTarget?
    private var rowsEnabled = true

    private enum RecordingTarget {
        case dictation
        case meeting
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func setupViews() {
        dictationRow.onPrimaryAction = { [weak self] in
            guard let self, self.rowsEnabled, self.recordingTarget == nil else { return }
            self.onStartDictation?()
        }
        dictationRow.onEditShortcut = { [weak self] in
            self?.startRecording(.dictation)
        }

        meetingRow.onPrimaryAction = { [weak self] in
            guard let self, self.rowsEnabled, self.recordingTarget == nil else { return }
            self.onStartMeeting?()
        }
        meetingRow.onEditShortcut = { [weak self] in
            self?.startRecording(.meeting)
        }

        addSubview(dictationRow)
        addSubview(meetingRow)
    }

    override func layout() {
        super.layout()
        dictationRow.frame = NSRect(x: 0, y: 0, width: bounds.width, height: MenuTokens.actionRowHeight)
        meetingRow.frame = NSRect(
            x: 0,
            y: MenuTokens.actionRowHeight + 8,
            width: bounds.width,
            height: MenuTokens.actionRowHeight
        )
    }

    func update(dictationKey: String, meetingKey: String, isEnabled: Bool) {
        rowsEnabled = isEnabled

        dictationRow.update(
            title: "Dictation",
            subtitle: recordingTarget == .dictation ? "Press shortcut…" : "Paste spoken text anywhere",
            key: recordingTarget == .dictation ? "Type keys" : dictationKey,
            isEditing: recordingTarget == .dictation,
            isEnabled: isEnabled
        )

        meetingRow.update(
            title: "Record meeting",
            subtitle: recordingTarget == .meeting ? "Press shortcut…" : "Capture mic and system audio",
            key: recordingTarget == .meeting ? "Type keys" : meetingKey,
            isEditing: recordingTarget == .meeting,
            isEnabled: isEnabled
        )

        needsLayout = true
    }

    private func startRecording(_ target: RecordingTarget) {
        guard rowsEnabled else { return }
        stopRecording()
        recordingTarget = target
        refreshFromPreferences()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                self.refreshFromPreferences()
                return nil
            }

            let candidate = HotkeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: HotkeyPreferences.carbonModifiers(from: event.modifierFlags)
            )
            guard HotkeyPreferences.isValid(candidate) else { return nil }

            switch target {
            case .dictation:
                HotkeyPreferences.save(dictation: candidate)
            case .meeting:
                HotkeyPreferences.save(meeting: candidate)
            }

            self.stopRecording()
            self.refreshFromPreferences()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        recordingTarget = nil
    }

    private func refreshFromPreferences() {
        update(
            dictationKey: HotkeyPreferences.displayString(for: HotkeyPreferences.dictationBinding()),
            meetingKey: HotkeyPreferences.displayString(for: HotkeyPreferences.meetingBinding()),
            isEnabled: rowsEnabled
        )
    }

    var intrinsicHeight: CGFloat {
        MenuTokens.actionRowHeight * 2 + 8
    }
}

private final class PrimaryActionRowView: NSView {
    var onPrimaryAction: (() -> Void)?
    var onEditShortcut: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeButton = NSButton(title: "", target: nil, action: nil)
    private var rowEnabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(subtitleLabel)

        badgeButton.isBordered = false
        badgeButton.bezelStyle = .inline
        badgeButton.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        badgeButton.contentTintColor = MenuTokens.textPrimaryNS
        badgeButton.wantsLayer = true
        badgeButton.layer?.cornerRadius = 8
        badgeButton.target = self
        badgeButton.action = #selector(editShortcut)
        addSubview(badgeButton)
    }

    func update(title: String, subtitle: String, key: String, isEditing: Bool, isEnabled: Bool) {
        rowEnabled = isEnabled
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        badgeButton.title = key

        layer?.backgroundColor = (isEnabled ? MenuTokens.actionBackgroundNS : MenuTokens.actionDisabledNS).cgColor
        layer?.borderColor = MenuTokens.actionBorderNS.cgColor

        titleLabel.alphaValue = isEnabled ? 1.0 : 0.55
        subtitleLabel.alphaValue = isEnabled ? 1.0 : 0.55
        badgeButton.alphaValue = isEnabled ? 1.0 : 0.55
        badgeButton.isEnabled = isEnabled
        badgeButton.layer?.backgroundColor = (isEditing ? NSColor.systemOrange.withAlphaComponent(0.18) : MenuTokens.badgeBackgroundNS).cgColor
        badgeButton.layer?.borderWidth = 1
        badgeButton.layer?.borderColor = (isEditing ? NSColor.systemOrange.withAlphaComponent(0.32) : MenuTokens.badgeBorderNS).cgColor

        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let badgeWidth = max(70, badgeButton.fittingSize.width + 18)
        badgeButton.frame = NSRect(
            x: bounds.width - pad - badgeWidth,
            y: (bounds.height - MenuTokens.badgeHeight) / 2,
            width: badgeWidth,
            height: MenuTokens.badgeHeight
        )

        let textWidth = badgeButton.frame.minX - pad - 12
        titleLabel.frame = NSRect(x: pad, y: 11, width: textWidth, height: 15)
        subtitleLabel.frame = NSRect(x: pad, y: 27, width: textWidth, height: 13)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard rowEnabled, !badgeButton.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        onPrimaryAction?()
    }

    @objc private func editShortcut() {
        guard rowEnabled else { return }
        onEditShortcut?()
    }
}
