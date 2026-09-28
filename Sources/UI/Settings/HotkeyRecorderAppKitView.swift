// HotkeyRecorderAppKitView.swift
// Compact keyboard shortcut recorder — pure AppKit

import AppKit
import Carbon

@MainActor
final class HotkeyRecorderAppKitView: NSView {
    private var pushToTalkRow: ShortcutRecorderRow!
    private var handsFreeRow: ShortcutRecorderRow!
    private var meetingRow: ShortcutRecorderRow!
    private var pasteLastDictationRow: ShortcutRecorderRow!
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

    /// Why the last recorded chord was refused (see
    /// `PhysicalDictationTriggerPreferences.rejectionReason`). Shown in the
    /// recording row until the user presses an acceptable chord or cancels.
    private var rejectionHint: String?


    enum RecordingTarget {
        case pushToTalk
        case handsFree
        case meeting
        case pasteLastDictation

        var isDictation: Bool {
            switch self {
            case .pushToTalk, .handsFree:
                return true
            case .meeting, .pasteLastDictation:
                return false
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        pushToTalkRow = ShortcutRecorderRow(
            label: "Push to Talk",
            recordAction: { [weak self] in self?.startRecording(.pushToTalk) },
            resetAction: { [weak self] in
                self?.resetRow(.pushToTalk, to: PhysicalDictationTriggerPreferences.defaultPushToTalkBinding)
            }
        )
        addSubview(pushToTalkRow)

        handsFreeRow = ShortcutRecorderRow(
            label: "Hands-Free",
            recordAction: { [weak self] in self?.startRecording(.handsFree) },
            resetAction: { [weak self] in
                self?.resetRow(.handsFree, to: PhysicalDictationTriggerPreferences.defaultHandsFreeBinding)
            }
        )
        addSubview(handsFreeRow)

        meetingRow = ShortcutRecorderRow(
            label: "Meetings",
            recordAction: { [weak self] in self?.startRecording(.meeting) },
            resetAction: { [weak self] in
                self?.resetRow(.meeting, to: PhysicalDictationTriggerPreferences.defaultMeetingBinding)
            }
        )
        addSubview(meetingRow)

        pasteLastDictationRow = ShortcutRecorderRow(
            label: "Paste Last",
            recordAction: { [weak self] in self?.startRecording(.pasteLastDictation) },
            resetAction: { [weak self] in
                self?.resetRow(.pasteLastDictation, to: PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding)
            }
        )
        addSubview(pasteLastDictationRow)

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
        pasteLastDictationRow.frame = NSRect(x: 0, y: bounds.height - rowH * 4 - 12, width: bounds.width, height: rowH)
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
        let pasteLastDictationBinding = PhysicalDictationTriggerPreferences.pasteLastDictationBinding()
        pushToTalkRow.update(
            displayText: dictationShortcutsEnabled
                ? (recordingTarget == .pushToTalk ? "Press key..." : PhysicalDictationTriggerPreferences.displayString(for: pushToTalkBinding))
                : "Off",
            isRecording: recordingTarget == .pushToTalk,
            isDefault: pushToTalkBinding == PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            isEnabled: dictationShortcutsEnabled,
            hint: hint(for: .pushToTalk)
        )
        handsFreeRow.update(
            displayText: dictationShortcutsEnabled
                ? (recordingTarget == .handsFree ? "Press key..." : PhysicalDictationTriggerPreferences.displayString(for: handsFreeBinding))
                : "Off",
            isRecording: recordingTarget == .handsFree,
            isDefault: handsFreeBinding == PhysicalDictationTriggerPreferences.defaultHandsFreeBinding,
            isEnabled: dictationShortcutsEnabled,
            hint: hint(for: .handsFree)
        )
        meetingRow.update(
            displayText: recordingTarget == .meeting ? "Press shortcut..." : PhysicalDictationTriggerPreferences.displayString(for: meetingBinding),
            isRecording: recordingTarget == .meeting,
            isDefault: meetingBinding == PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            isEnabled: true,
            hint: hint(for: .meeting)
        )
        pasteLastDictationRow.update(
            displayText: recordingTarget == .pasteLastDictation ? "Press shortcut..." : PhysicalDictationTriggerPreferences.displayString(for: pasteLastDictationBinding),
            isRecording: recordingTarget == .pasteLastDictation,
            isDefault: pasteLastDictationBinding == PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding,
            isEnabled: true,
            hint: hint(for: .pasteLastDictation)
        )
    }

    private func hint(for target: RecordingTarget) -> String? {
        recordingTarget == target ? rejectionHint : nil
    }

    /// The other shortcuts' names and current bindings, for the duplicate
    /// check. Dictation keys count even while dictation shortcuts are off, so
    /// turning them back on can't bring a clash back.
    private func otherShortcuts(than target: RecordingTarget) -> [(name: String, binding: PhysicalDictationTriggerBinding)] {
        let all: [(RecordingTarget, String, PhysicalDictationTriggerBinding)] = [
            (.pushToTalk, "Push to Talk", PhysicalDictationTriggerPreferences.pushToTalkBinding()),
            (.handsFree, "Hands-Free", PhysicalDictationTriggerPreferences.handsFreeBinding()),
            (.meeting, "Meetings", PhysicalDictationTriggerPreferences.meetingBinding()),
            (.pasteLastDictation, "Paste Last Dictation", PhysicalDictationTriggerPreferences.pasteLastDictationBinding()),
        ]
        return all.filter { $0.0 != target }.map { (name: $0.1, binding: $0.2) }
    }

    private func duplicateReason(for binding: PhysicalDictationTriggerBinding, target: RecordingTarget) -> String? {
        PhysicalDictationTriggerPreferences.duplicateReason(for: binding, otherShortcuts: otherShortcuts(than: target))
    }

    /// Saves `binding` for `target` and ends recording, unless another
    /// shortcut already uses it. Then it beeps, says which one, and keeps
    /// listening for a different key.
    private func saveIfFree(_ binding: PhysicalDictationTriggerBinding, for target: RecordingTarget) {
        if let reason = duplicateReason(for: binding, target: target) {
            NSSound.beep()
            pendingDictationModifier = nil
            pendingDictationModifierKeyCode = nil
            rejectionHint = reason
            refreshDisplay()
            return
        }
        rejectionHint = nil
        save(binding, for: target)
        stopRecording()
        refreshDisplay()
    }

    /// A row's reset button. If the default is now taken by another
    /// shortcut, the row opens for recording with the reason instead of
    /// saving a duplicate.
    private func resetRow(_ target: RecordingTarget, to defaultBinding: PhysicalDictationTriggerBinding) {
        stopRecording()
        if let reason = duplicateReason(for: defaultBinding, target: target) {
            NSSound.beep()
            startRecording(target)
            rejectionHint = reason
            refreshDisplay()
            return
        }
        save(defaultBinding, for: target)
        refreshDisplay()
    }

    private func startRecording(_ target: RecordingTarget) {
        guard dictationShortcutsEnabled || !target.isDictation else { return }
        stopRecording()
        rejectionHint = nil
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
            // A bare typing key or a macOS-reserved ⌘ chord would be swallowed
            // system-wide by the event tap (a ⌘V paste-last binding turns every
            // paste on the Mac into Transcripted's popup). Refuse it, say why,
            // and keep listening for an acceptable chord.
            if let reason = PhysicalDictationTriggerPreferences.rejectionReason(for: candidate) {
                NSSound.beep()
                self.rejectionHint = reason
                self.refreshDisplay()
                return nil
            }
            self.saveIfFree(candidate, for: target)
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
                    self.saveIfFree(candidate, for: target)
                    return nil
                }

                self.pendingDictationModifier = candidate
                self.pendingDictationModifierKeyCode = keyCode
                return nil
            }

            if let pending = self.pendingDictationModifier,
               self.pendingDictationModifierKeyCode == keyCode,
               PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(pending, keyCode: keyCode, modifiers: modifiers) {
                self.saveIfFree(pending, for: target)
                return nil
            }

            return event
        }
    }

    private func stopRecording() {
        rejectionHint = nil
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
        case .pasteLastDictation:
            PhysicalDictationTriggerPreferences.savePasteLastDictation(binding)
        }
    }

    @objc private func resetAll() {
        stopRecording()
        HotkeyPreferences.resetToDefaults()
        PhysicalDictationTriggerPreferences.resetToDefaults()
        refreshDisplay()
    }

    var intrinsicHeight: CGFloat { 140 }
}

// MARK: - Single Shortcut Row

private final class ShortcutRecorderRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let resetRowButton = NSButton()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

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

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = NSColor.systemOrange
        hintLabel.maximumNumberOfLines = 2
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.isHidden = true
        addSubview(hintLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let labelW: CGFloat = 82
        nameLabel.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: labelW, height: 16)
        let btnW: CGFloat = 110
        shortcutButton.frame = NSRect(x: labelW + 8, y: (bounds.height - 24) / 2, width: btnW, height: 24)
        var trailingX = labelW + 8 + btnW + 8
        if !resetRowButton.isHidden {
            resetRowButton.frame = NSRect(x: trailingX, y: (bounds.height - 20) / 2, width: 20, height: 20)
            trailingX += 20 + 8
        }
        if !hintLabel.isHidden {
            hintLabel.frame = NSRect(x: trailingX, y: 0, width: max(0, bounds.width - trailingX), height: bounds.height)
        }
    }

    func update(displayText: String, isRecording: Bool, isDefault: Bool, isEnabled: Bool, hint: String? = nil) {
        hintLabel.stringValue = hint ?? ""
        hintLabel.toolTip = hint
        hintLabel.isHidden = hint == nil
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
