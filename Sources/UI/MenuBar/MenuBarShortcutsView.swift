// MenuBarShortcutsView.swift
// Primary action rows for dictation and meeting capture.

import AppKit
import Carbon

@MainActor
final class MenuBarShortcutsView: NSView {
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?
    var onImportAudioFile: (() -> Void)?

    private let pushToTalkRow = PrimaryActionRowView()
    private let handsFreeRow = PrimaryActionRowView()
    private let meetingRow = PrimaryActionRowView()
    private let importButton = MenuOutlineButton(
        title: "Transcribe file",
        symbolName: "waveform",
        accessibilityLabel: "Transcribe file",
        toolTip: "Choose an audio file to transcribe"
    )
    private let resetHintLabel = NSTextField(labelWithString: "Edit triggers or import audio")
    private let resetButton = MenuIconButton(
        symbolName: "arrow.counterclockwise",
        accessibilityLabel: "Reset shortcuts",
        toolTip: "Reset shortcuts"
    )
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var resetConfirmationTask: Task<Void, Never>?
    private var recordingTarget: RecordingTarget?
    private var pendingDictationModifier: PhysicalDictationTriggerBinding?
    private var pendingDictationModifierKeyCode: UInt32?
    private var isResetConfirming = false
    private var currentDictationState = MenuBarPrimaryActionState(
        title: "Start Dictation",
        symbolName: "mic.fill",
        isEnabled: true,
        subtitle: "Paste spoken text anywhere"
    )
    private var currentMeetingState = MenuBarPrimaryActionState(
        title: "Start Meeting",
        symbolName: "record.circle.fill",
        isEnabled: true,
        subtitle: "Capture mic and system audio"
    )
    private var canImportAudioFiles = true

    private enum RecordingTarget {
        case pushToTalk
        case handsFree
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
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        resetConfirmationTask?.cancel()
    }

    override func removeFromSuperview() {
        cancelResetConfirmation(refresh: false)
        stopRecording()
        super.removeFromSuperview()
    }

    private func setupViews() {
        pushToTalkRow.onPrimaryAction = { [weak self] in
            guard let self, self.currentDictationState.isEnabled, self.recordingTarget == nil else { return }
            self.onStartDictation?()
        }
        pushToTalkRow.onEditShortcut = { [weak self] in
            self?.startRecording(.pushToTalk)
        }

        handsFreeRow.onPrimaryAction = { [weak self] in
            guard let self, self.currentDictationState.isEnabled, self.recordingTarget == nil else { return }
            self.onStartDictation?()
        }
        handsFreeRow.onEditShortcut = { [weak self] in
            self?.startRecording(.handsFree)
        }

        meetingRow.onPrimaryAction = { [weak self] in
            guard let self, self.currentMeetingState.isEnabled, self.recordingTarget == nil else { return }
            self.onStartMeeting?()
        }
        meetingRow.onEditShortcut = { [weak self] in
            self?.startRecording(.meeting)
        }

        resetHintLabel.font = NSFont.systemFont(ofSize: 10)
        resetHintLabel.textColor = MenuTokens.textMutedNS
        addSubview(resetHintLabel)

        importButton.target = self
        importButton.action = #selector(importAudioFile)
        addSubview(importButton)

        resetButton.target = self
        resetButton.action = #selector(resetShortcuts)
        addSubview(resetButton)
        updateResetButtonAppearance()

        addSubview(pushToTalkRow)
        addSubview(handsFreeRow)
        addSubview(meetingRow)
    }

    override func layout() {
        super.layout()
        pushToTalkRow.frame = NSRect(x: 0, y: 0, width: bounds.width, height: MenuTokens.actionRowHeight)
        handsFreeRow.frame = NSRect(
            x: 0,
            y: MenuTokens.actionRowHeight + 6,
            width: bounds.width,
            height: MenuTokens.actionRowHeight
        )
        meetingRow.frame = NSRect(
            x: 0,
            y: (MenuTokens.actionRowHeight + 6) * 2,
            width: bounds.width,
            height: MenuTokens.actionRowHeight
        )

        let importY = meetingRow.frame.maxY + 8
        importButton.frame = NSRect(
            x: 0,
            y: importY,
            width: bounds.width,
            height: MenuTokens.secondaryButtonSize
        )

        let buttonSize = MenuTokens.secondaryButtonSize
        let footerY = importButton.frame.maxY + 8
        resetButton.frame = NSRect(x: bounds.width - buttonSize, y: footerY, width: buttonSize, height: buttonSize)
        resetHintLabel.frame = NSRect(
            x: 0,
            y: footerY + ((buttonSize - 14) / 2),
            width: max(0, resetButton.frame.minX - 10),
            height: 14
        )
    }

    func update(
        pushToTalkKey: String,
        handsFreeKey: String,
        meetingKey: String,
        dictationState: MenuBarPrimaryActionState,
        meetingState: MenuBarPrimaryActionState,
        canImportAudioFiles: Bool
    ) {
        currentDictationState = dictationState
        currentMeetingState = meetingState
        self.canImportAudioFiles = canImportAudioFiles
        importButton.isEnabled = canImportAudioFiles && recordingTarget == nil
        resetButton.isEnabled = recordingTarget == nil
        resetHintLabel.alphaValue = 1.0
        if recordingTarget != nil {
            resetHintLabel.stringValue = "Press the new shortcut, or Esc to cancel."
        } else if isResetConfirming {
            resetHintLabel.stringValue = "Click reset again to confirm."
        } else {
            resetHintLabel.stringValue = "Edit triggers or import audio"
        }

        pushToTalkRow.update(
            symbolName: "mic.fill",
            title: "Push to Talk",
            subtitle: recordingTarget == .pushToTalk
                ? "Press key, Esc cancels"
                : dictationState.subtitle,
            key: recordingTarget == .pushToTalk ? "Any key" : pushToTalkKey,
            isEditing: recordingTarget == .pushToTalk,
            isEnabled: dictationState.isEnabled
        )

        handsFreeRow.update(
            symbolName: "mic.badge.plus",
            title: "Hands-Free",
            subtitle: recordingTarget == .handsFree
                ? "Press key, Esc cancels"
                : "Tap to start or stop dictation",
            key: recordingTarget == .handsFree ? "Any key" : handsFreeKey,
            isEditing: recordingTarget == .handsFree,
            isEnabled: dictationState.isEnabled
        )

        meetingRow.update(
            symbolName: "record.circle.fill",
            title: "Record meeting",
            subtitle: recordingTarget == .meeting
                ? "Press keys, Esc cancels"
                : meetingState.subtitle,
            key: recordingTarget == .meeting ? "Type keys" : meetingKey,
            isEditing: recordingTarget == .meeting,
            isEnabled: meetingState.isEnabled
        )

        needsLayout = true
    }

    private func startRecording(_ target: RecordingTarget) {
        cancelResetConfirmation(refresh: false)
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

            if ShortcutRecorderKeyEventPolicy.shouldStopRecordingAndPassThrough(event) {
                self.stopRecording()
                self.refreshFromPreferences()
                return event
            }

            self.pendingDictationModifier = nil
            self.pendingDictationModifierKeyCode = nil
            let candidate = PhysicalDictationTriggerPreferences.bindingForKeyDown(
                keyCode: UInt32(event.keyCode),
                modifierFlags: event.modifierFlags
            )
            self.save(candidate, for: target)

            self.stopRecording()
            self.refreshFromPreferences()
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let keyCode = UInt32(event.keyCode)
            let modifiers = PhysicalDictationTriggerPreferences.modifiers(from: event.modifierFlags)

            if let candidate = PhysicalDictationTriggerPreferences.bindingForFlagsChanged(
                keyCode: keyCode,
                modifierFlags: event.modifierFlags
            ) {
                if keyCode == UInt32(kVK_CapsLock) {
                    self.save(candidate, for: target)
                    self.stopRecording()
                    self.refreshFromPreferences()
                    return nil
                }

                self.pendingDictationModifier = candidate
                self.pendingDictationModifierKeyCode = keyCode
                return nil
            }

            if let pending = self.pendingDictationModifier,
               self.pendingDictationModifierKeyCode == keyCode,
               PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(pending, keyCode: keyCode, modifiers: modifiers) {
                self.save(pending, for: target)
                self.stopRecording()
                self.refreshFromPreferences()
                return nil
            }

            return event
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        recordingTarget = nil
        pendingDictationModifier = nil
        pendingDictationModifierKeyCode = nil
    }

    func cancelEditing() {
        stopRecording()
        refreshFromPreferences()
    }

    private func refreshFromPreferences() {
        update(
            pushToTalkKey: PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.pushToTalkBinding()),
            handsFreeKey: PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.handsFreeBinding()),
            meetingKey: PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.meetingBinding()),
            dictationState: currentDictationState,
            meetingState: currentMeetingState,
            canImportAudioFiles: canImportAudioFiles
        )
    }

    var intrinsicHeight: CGFloat {
        MenuTokens.actionRowHeight * 3 + MenuTokens.secondaryButtonSize * 2 + 26
    }

    @objc private func resetShortcuts() {
        guard recordingTarget == nil else { return }

        guard isResetConfirming else {
            beginResetConfirmation()
            return
        }

        HotkeyPreferences.resetToDefaults()
        PhysicalDictationTriggerPreferences.resetToDefaults()
        cancelResetConfirmation(refresh: false)
        refreshFromPreferences()
    }

    private func beginResetConfirmation() {
        isResetConfirming = true
        updateResetButtonAppearance()
        refreshFromPreferences()

        resetConfirmationTask?.cancel()
        resetConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cancelResetConfirmation(refresh: true)
        }
    }

    private func cancelResetConfirmation(refresh: Bool) {
        resetConfirmationTask?.cancel()
        resetConfirmationTask = nil
        guard isResetConfirming else { return }
        isResetConfirming = false
        updateResetButtonAppearance()
        if refresh {
            refreshFromPreferences()
        }
    }

    private func updateResetButtonAppearance() {
        if isResetConfirming {
            resetButton.setSymbol(
                "checkmark",
                accessibilityLabel: "Confirm reset shortcuts",
                tintOverride: MenuTokens.statusOrangeNS
            )
            resetButton.toolTip = "Confirm reset shortcuts"
        } else {
            resetButton.setSymbol(
                "arrow.counterclockwise",
                accessibilityLabel: "Reset shortcuts"
            )
            resetButton.toolTip = "Reset shortcuts"
        }
    }

    private func save(_ binding: PhysicalDictationTriggerBinding, for target: RecordingTarget) {
        switch target {
        case .pushToTalk:
            PhysicalDictationTriggerPreferences.savePushToTalk(binding)
        case .handsFree:
            PhysicalDictationTriggerPreferences.saveHandsFree(binding)
        case .meeting:
            PhysicalDictationTriggerPreferences.saveMeeting(binding)
        }
    }

    @objc private func importAudioFile() {
        guard importButton.isEnabled, recordingTarget == nil else { return }
        onImportAudioFile?()
    }
}

private final class PrimaryActionRowView: NSView {
    var onPrimaryAction: (() -> Void)?
    var onEditShortcut: (() -> Void)?

    private let symbolWellView = NSView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeButton = NSButton(title: "", target: nil, action: nil)
    private var rowEnabled = true
    private var trackingAreaRef: NSTrackingArea?

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

        symbolWellView.wantsLayer = true
        symbolWellView.layer?.cornerRadius = MenuTokens.symbolWellSize / 2
        symbolWellView.layer?.backgroundColor = MenuTokens.symbolBackgroundNS.cgColor
        symbolWellView.layer?.borderWidth = 1
        symbolWellView.layer?.borderColor = MenuTokens.symbolBorderNS.cgColor
        addSubview(symbolWellView)

        symbolView.contentTintColor = MenuTokens.textPrimaryNS
        symbolWellView.addSubview(symbolView)

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func update(symbolName: String, title: String, subtitle: String, key: String, isEditing: Bool, isEnabled: Bool) {
        rowEnabled = isEnabled
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
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

    override func mouseEntered(with event: NSEvent) {
        guard rowEnabled else { return }
        layer?.backgroundColor = MenuTokens.actionPressedNS.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = (rowEnabled ? MenuTokens.actionBackgroundNS : MenuTokens.actionDisabledNS).cgColor
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        symbolWellView.frame = NSRect(
            x: pad,
            y: (bounds.height - MenuTokens.symbolWellSize) / 2,
            width: MenuTokens.symbolWellSize,
            height: MenuTokens.symbolWellSize
        )
        symbolView.frame = symbolWellView.bounds

        let badgeWidth = max(70, badgeButton.fittingSize.width + 18)
        badgeButton.frame = NSRect(
            x: bounds.width - pad - badgeWidth,
            y: (bounds.height - MenuTokens.badgeHeight) / 2,
            width: badgeWidth,
            height: MenuTokens.badgeHeight
        )

        let textX = symbolWellView.frame.maxX + 10
        let textWidth = badgeButton.frame.minX - textX - 10
        titleLabel.frame = NSRect(x: textX, y: 8, width: textWidth, height: 15)
        subtitleLabel.frame = NSRect(x: textX, y: 24, width: textWidth, height: 13)
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
