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
    private var validationErrorTarget: RecordingTarget?
    private var validationErrorMessage: String?

    enum RecordingTarget: Hashable {
        case pushToTalk
        case handsFree
        case meeting

        var physicalShortcutTarget: PhysicalShortcutTarget {
            switch self {
            case .pushToTalk:
                return .pushToTalk
            case .handsFree:
                return .handsFree
            case .meeting:
                return .meeting
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        pushToTalkRow = ShortcutRecorderRow(label: "Push to Talk") { [weak self] in self?.startRecording(.pushToTalk) }
            resetAction: { [weak self] in
                self?.stopRecording()
                _ = self?.save(PhysicalDictationTriggerPreferences.defaultPushToTalkBinding, for: .pushToTalk)
                self?.refreshDisplay()
            }
        addSubview(pushToTalkRow)

        handsFreeRow = ShortcutRecorderRow(label: "Hands-Free") { [weak self] in self?.startRecording(.handsFree) }
            resetAction: { [weak self] in
                self?.stopRecording()
                _ = self?.save(PhysicalDictationTriggerPreferences.defaultHandsFreeBinding, for: .handsFree)
                self?.refreshDisplay()
            }
        addSubview(handsFreeRow)

        meetingRow = ShortcutRecorderRow(label: "Meetings") { [weak self] in self?.startRecording(.meeting) }
            resetAction: { [weak self] in
                self?.stopRecording()
                _ = self?.save(PhysicalDictationTriggerPreferences.defaultMeetingBinding, for: .meeting)
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
            displayText: displayText(for: .pushToTalk, binding: pushToTalkBinding, recordingText: "Press key, Esc cancels"),
            isRecording: recordingTarget == .pushToTalk,
            isDefault: pushToTalkBinding == PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            isInvalid: validationErrorTarget == .pushToTalk
        )
        handsFreeRow.update(
            displayText: displayText(for: .handsFree, binding: handsFreeBinding, recordingText: "Press key, Esc cancels"),
            isRecording: recordingTarget == .handsFree,
            isDefault: handsFreeBinding == PhysicalDictationTriggerPreferences.defaultHandsFreeBinding,
            isInvalid: validationErrorTarget == .handsFree
        )
        meetingRow.update(
            displayText: displayText(for: .meeting, binding: meetingBinding, recordingText: "Press keys, Esc cancels"),
            isRecording: recordingTarget == .meeting,
            isDefault: meetingBinding == PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            isInvalid: validationErrorTarget == .meeting
        )
    }

    private func startRecording(_ target: RecordingTarget) {
        if recordingTarget == target {
            stopRecording()
            refreshDisplay()
            return
        }

        stopRecording()
        validationErrorTarget = nil
        validationErrorMessage = nil
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
            _ = self.save(candidate, for: target)
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
                    _ = self.save(candidate, for: target)
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
                _ = self.save(pending, for: target)
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

    private func displayText(
        for target: RecordingTarget,
        binding: PhysicalDictationTriggerBinding,
        recordingText: String
    ) -> String {
        if validationErrorTarget == target, let validationErrorMessage {
            return validationErrorMessage
        }

        if recordingTarget == target {
            return recordingText
        }

        return PhysicalDictationTriggerPreferences.displayString(for: binding)
    }

    private func save(_ binding: PhysicalDictationTriggerBinding, for target: RecordingTarget) -> Bool {
        if let conflict = PhysicalDictationTriggerPreferences.conflictingBinding(
            for: binding,
            target: target.physicalShortcutTarget
        ) {
            validationErrorTarget = target
            validationErrorMessage = "Used by \(conflict.target.title)"
            return false
        }

        switch target {
        case .pushToTalk:
            PhysicalDictationTriggerPreferences.savePushToTalk(binding)
        case .handsFree:
            PhysicalDictationTriggerPreferences.saveHandsFree(binding)
        case .meeting:
            PhysicalDictationTriggerPreferences.saveMeeting(binding)
        }
        validationErrorTarget = nil
        validationErrorMessage = nil
        return true
    }

    @objc private func resetAll() {
        stopRecording()
        validationErrorTarget = nil
        validationErrorMessage = nil
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
    private let rowLabel: String
    private var wasRecording = false

    private var recordAction: () -> Void
    private var resetAction: () -> Void

    init(label: String, recordAction: @escaping () -> Void, resetAction: @escaping () -> Void) {
        rowLabel = label
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
        shortcutButton.setAccessibilityLabel("\(label) shortcut")
        shortcutButton.setAccessibilityHelp("Click to record. Press Escape to cancel.")
        addSubview(shortcutButton)

        if let img = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset") {
            resetRowButton.image = img
            resetRowButton.bezelStyle = .inline
            resetRowButton.isBordered = false
            resetRowButton.contentTintColor = MenuTokens.textSecondaryNS
            resetRowButton.target = self
            resetRowButton.action = #selector(resetTapped)
        }
        resetRowButton.setAccessibilityLabel("Reset \(label) shortcut to default")
        resetRowButton.setAccessibilityHelp("Restores the default \(label) shortcut.")
        resetRowButton.isHidden = true
        addSubview(resetRowButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let labelW: CGFloat = 82
        nameLabel.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: labelW, height: 16)
        let resetSlotW: CGFloat = resetRowButton.isHidden ? 0 : 28
        let availableButtonW = bounds.width - labelW - 8 - resetSlotW
        let btnW = min(CGFloat(170), max(CGFloat(110), availableButtonW))
        shortcutButton.frame = NSRect(x: labelW + 8, y: (bounds.height - 24) / 2, width: btnW, height: 24)
        if !resetRowButton.isHidden {
            resetRowButton.frame = NSRect(x: labelW + 8 + btnW + 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
        }
    }

    func update(displayText: String, isRecording: Bool, isDefault: Bool, isInvalid: Bool = false) {
        shortcutButton.title = displayText
        shortcutButton.setAccessibilityValue(displayText)
        shortcutButton.setAccessibilityHelp(
            isRecording
                ? "Recording. Press your shortcut, or Escape to cancel."
                : "Click to record. Press Escape to cancel."
        )
        if isRecording && !wasRecording {
            NSAccessibility.post(
                element: shortcutButton,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Recording \(rowLabel) shortcut. Press your shortcut, or Escape to cancel.",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
        wasRecording = isRecording

        if isInvalid {
            shortcutButton.bezelColor = NSColor.systemRed.withAlphaComponent(0.28)
            shortcutButton.contentTintColor = NSColor.systemRed
        } else {
            shortcutButton.bezelColor = isRecording ? NSColor.systemOrange.withAlphaComponent(0.35) : MenuTokens.buttonBackgroundNS
            shortcutButton.contentTintColor = MenuTokens.textPrimaryNS
        }
        resetRowButton.isHidden = isDefault
        needsLayout = true
    }

    @objc private func recordTapped() { recordAction() }
    @objc private func resetTapped() { resetAction() }
}
