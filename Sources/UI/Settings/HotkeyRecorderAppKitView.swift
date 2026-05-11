// HotkeyRecorderAppKitView.swift
// Compact keyboard shortcut recorder — pure AppKit

import AppKit
import Carbon

@MainActor
final class HotkeyRecorderAppKitView: NSView {
    private var pushToTalkRow: ShortcutRecorderRow!
    private var handsFreeRow: ShortcutRecorderRow!
    private var meetingRow: ShortcutRecorderRow!
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var recordingTarget: RecordingTarget?
    private var pendingDictationModifier: PhysicalDictationTriggerBinding?
    private var pendingDictationModifierKeyCode: UInt32?
    var dictationShortcutsEnabled = true {
        didSet {
            if !dictationShortcutsEnabled, recordingTarget?.isDictation == true {
                stopRecording()
            }
            refreshDisplay()
        }
    }

    enum RecordingTarget {
        case pushToTalk
        case handsFree
        case meeting

        var isDictation: Bool {
            switch self {
            case .pushToTalk, .handsFree:
                return true
            case .meeting:
                return false
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        pushToTalkRow = ShortcutRecorderRow(label: "Push to Talk") { [weak self] in self?.startRecording(.pushToTalk) }
            resetAction: { [weak self] in
                self?.stopRecording()
                PhysicalDictationTriggerPreferences.savePushToTalk(
                    PhysicalDictationTriggerPreferences.defaultPushToTalkBinding
                )
                self?.refreshDisplay()
            }
        addSubview(pushToTalkRow)

        handsFreeRow = ShortcutRecorderRow(label: "Hands-Free") { [weak self] in self?.startRecording(.handsFree) }
            resetAction: { [weak self] in
                self?.stopRecording()
                PhysicalDictationTriggerPreferences.saveHandsFree(
                    PhysicalDictationTriggerPreferences.defaultHandsFreeBinding
                )
                self?.refreshDisplay()
            }
        addSubview(handsFreeRow)

        meetingRow = ShortcutRecorderRow(label: "Meetings") { [weak self] in self?.startRecording(.meeting) }
            resetAction: { [weak self] in
                self?.stopRecording()
                PhysicalDictationTriggerPreferences.saveMeeting(
                    PhysicalDictationTriggerPreferences.defaultMeetingBinding
                )
                self?.refreshDisplay()
            }
        addSubview(meetingRow)

        resetButton.bezelStyle = .inline
        resetButton.isBordered = false
        resetButton.font = NSFont.systemFont(ofSize: 11)
        resetButton.contentTintColor = MenuTokens.textSecondaryNS
        resetButton.target = self
        resetButton.action = #selector(resetAll)
        addSubview(resetButton)

        refreshDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let rowH: CGFloat = 28
        pushToTalkRow.frame = NSRect(x: 0, y: bounds.height - rowH, width: bounds.width, height: rowH)
        handsFreeRow.frame = NSRect(x: 0, y: bounds.height - rowH * 2 - 4, width: bounds.width, height: rowH)
        meetingRow.frame = NSRect(x: 0, y: bounds.height - rowH * 3 - 8, width: bounds.width, height: rowH)
        let resetSize = resetButton.fittingSize
        resetButton.frame = NSRect(x: (bounds.width - resetSize.width) / 2, y: 0, width: resetSize.width, height: resetSize.height)
    }

    override func removeFromSuperview() {
        stopRecording()
        super.removeFromSuperview()
    }

    func refreshDisplay() {
        let pushToTalkBinding = PhysicalDictationTriggerPreferences.pushToTalkBinding()
        let handsFreeBinding = PhysicalDictationTriggerPreferences.handsFreeBinding()
        let meetingBinding = PhysicalDictationTriggerPreferences.meetingBinding()
        pushToTalkRow.update(
            displayText: dictationShortcutsEnabled
                ? (recordingTarget == .pushToTalk ? "Press key..." : PhysicalDictationTriggerPreferences.displayString(for: pushToTalkBinding))
                : "Off",
            isRecording: recordingTarget == .pushToTalk,
            isDefault: pushToTalkBinding == PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            isEnabled: dictationShortcutsEnabled
        )
        handsFreeRow.update(
            displayText: dictationShortcutsEnabled
                ? (recordingTarget == .handsFree ? "Press key..." : PhysicalDictationTriggerPreferences.displayString(for: handsFreeBinding))
                : "Off",
            isRecording: recordingTarget == .handsFree,
            isDefault: handsFreeBinding == PhysicalDictationTriggerPreferences.defaultHandsFreeBinding,
            isEnabled: dictationShortcutsEnabled
        )
        meetingRow.update(
            displayText: recordingTarget == .meeting ? "Press shortcut..." : PhysicalDictationTriggerPreferences.displayString(for: meetingBinding),
            isRecording: recordingTarget == .meeting,
            isDefault: meetingBinding == PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            isEnabled: true
        )
    }

    private func startRecording(_ target: RecordingTarget) {
        guard dictationShortcutsEnabled || !target.isDictation else { return }
        stopRecording()
        recordingTarget = target
        refreshDisplay()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let code = event.keyCode

            if code == UInt16(kVK_Escape) {
                self.stopRecording()
                self.refreshDisplay()
                return nil
            }

            self.pendingDictationModifier = nil
            self.pendingDictationModifierKeyCode = nil
            let candidate = PhysicalDictationTriggerPreferences.bindingForKeyDown(
                keyCode: UInt32(code),
                modifierFlags: event.modifierFlags
            )
            self.save(candidate, for: target)
            self.stopRecording()
            self.refreshDisplay()
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            let keyCode = UInt32(event.keyCode)
            let modifiers = PhysicalDictationTriggerPreferences.modifiers(from: event.modifierFlags)

            if let candidate = PhysicalDictationTriggerPreferences.bindingForFlagsChanged(
                keyCode: keyCode,
                modifierFlags: event.modifierFlags
            ) {
                if keyCode == UInt32(kVK_CapsLock) {
                    self.save(candidate, for: target)
                    self.stopRecording()
                    self.refreshDisplay()
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
                self.refreshDisplay()
                return nil
            }

            return event
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        recordingTarget = nil
        pendingDictationModifier = nil
        pendingDictationModifierKeyCode = nil
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

    @objc private func resetAll() {
        stopRecording()
        HotkeyPreferences.resetToDefaults()
        PhysicalDictationTriggerPreferences.resetToDefaults()
        refreshDisplay()
    }

    var intrinsicHeight: CGFloat { 108 }
}

// MARK: - Single Shortcut Row

private final class ShortcutRecorderRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let resetRowButton = NSButton()

    private var recordAction: () -> Void
    private var resetAction: () -> Void

    init(label: String, recordAction: @escaping () -> Void, resetAction: @escaping () -> Void) {
        self.recordAction = recordAction
        self.resetAction = resetAction
        super.init(frame: .zero)

        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.textColor = MenuTokens.textSecondaryNS
        nameLabel.stringValue = label
        addSubview(nameLabel)

        shortcutButton.bezelStyle = .rounded
        shortcutButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutButton.contentTintColor = MenuTokens.textPrimaryNS
        shortcutButton.bezelColor = MenuTokens.buttonBackgroundNS
        shortcutButton.target = self
        shortcutButton.action = #selector(recordTapped)
        addSubview(shortcutButton)

        if let img = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset") {
            resetRowButton.image = img
            resetRowButton.bezelStyle = .inline
            resetRowButton.isBordered = false
            resetRowButton.contentTintColor = MenuTokens.textSecondaryNS
            resetRowButton.target = self
            resetRowButton.action = #selector(resetTapped)
        }
        resetRowButton.isHidden = true
        addSubview(resetRowButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let labelW: CGFloat = 82
        nameLabel.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: labelW, height: 16)
        let btnW: CGFloat = 110
        shortcutButton.frame = NSRect(x: labelW + 8, y: (bounds.height - 24) / 2, width: btnW, height: 24)
        if !resetRowButton.isHidden {
            resetRowButton.frame = NSRect(x: labelW + 8 + btnW + 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
        }
    }

    func update(displayText: String, isRecording: Bool, isDefault: Bool, isEnabled: Bool) {
        shortcutButton.title = displayText
        shortcutButton.bezelColor = isRecording ? NSColor.systemOrange.withAlphaComponent(0.35) : MenuTokens.buttonBackgroundNS
        shortcutButton.isEnabled = isEnabled
        shortcutButton.alphaValue = isEnabled ? 1.0 : 0.55
        nameLabel.alphaValue = isEnabled ? 1.0 : 0.55
        resetRowButton.isHidden = isDefault || !isEnabled
        needsLayout = true
    }

    @objc private func recordTapped() {
        guard shortcutButton.isEnabled else { return }
        recordAction()
    }

    @objc private func resetTapped() {
        guard !resetRowButton.isHidden else { return }
        resetAction()
    }
}
