// HotkeyRecorderAppKitView.swift
// Compact two-row keyboard shortcut recorder — pure AppKit

import AppKit
import Carbon

@MainActor
final class HotkeyRecorderAppKitView: NSView {
    private var draftRow: ShortcutRecorderRow!
    private var dictationRow: ShortcutRecorderRow!
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)

    private var keyMonitor: Any?
    private var recordingTarget: RecordingTarget?

    enum RecordingTarget {
        case draft
        case dictation
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        draftRow = ShortcutRecorderRow(label: "Draft") { [weak self] in self?.startRecording(.draft) }
            resetAction: { [weak self] in
                self?.stopRecording()
                HotkeyPreferences.save(draft: HotkeyPreferences.defaultDraft)
                self?.refreshDisplay()
            }
        addSubview(draftRow)

        dictationRow = ShortcutRecorderRow(label: "Dictation") { [weak self] in self?.startRecording(.dictation) }
            resetAction: { [weak self] in
                self?.stopRecording()
                HotkeyPreferences.save(dictation: HotkeyPreferences.defaultDictation)
                self?.refreshDisplay()
            }
        addSubview(dictationRow)

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
        draftRow.frame = NSRect(x: 0, y: bounds.height - rowH, width: bounds.width, height: rowH)
        dictationRow.frame = NSRect(x: 0, y: bounds.height - rowH * 2 - 4, width: bounds.width, height: rowH)
        let resetSize = resetButton.fittingSize
        resetButton.frame = NSRect(x: (bounds.width - resetSize.width) / 2, y: 0, width: resetSize.width, height: resetSize.height)
    }

    override func removeFromSuperview() {
        stopRecording()
        super.removeFromSuperview()
    }

    func refreshDisplay() {
        let draftBinding = HotkeyPreferences.draftBinding()
        let dictBinding = HotkeyPreferences.dictationBinding()
        draftRow.update(
            displayText: recordingTarget == .draft ? "Press shortcut..." : HotkeyPreferences.displayString(for: draftBinding),
            isRecording: recordingTarget == .draft,
            isDefault: draftBinding == HotkeyPreferences.defaultDraft
        )
        dictationRow.update(
            displayText: recordingTarget == .dictation ? "Press shortcut..." : HotkeyPreferences.displayString(for: dictBinding),
            isRecording: recordingTarget == .dictation,
            isDefault: dictBinding == HotkeyPreferences.defaultDictation
        )
    }

    private func startRecording(_ target: RecordingTarget) {
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

            let carbonMods = HotkeyPreferences.carbonModifiers(from: event.modifierFlags)
            let candidate = HotkeyBinding(keyCode: UInt32(code), modifiers: carbonMods)

            guard HotkeyPreferences.isValid(candidate) else { return nil }

            switch target {
            case .draft: HotkeyPreferences.save(draft: candidate)
            case .dictation: HotkeyPreferences.save(dictation: candidate)
            }
            self.stopRecording()
            self.refreshDisplay()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        recordingTarget = nil
    }

    @objc private func resetAll() {
        stopRecording()
        HotkeyPreferences.resetToDefaults()
        refreshDisplay()
    }

    var intrinsicHeight: CGFloat { 76 }
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
        let labelW: CGFloat = 60
        nameLabel.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: labelW, height: 16)
        let btnW: CGFloat = 110
        shortcutButton.frame = NSRect(x: labelW + 8, y: (bounds.height - 24) / 2, width: btnW, height: 24)
        if !resetRowButton.isHidden {
            resetRowButton.frame = NSRect(x: labelW + 8 + btnW + 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
        }
    }

    func update(displayText: String, isRecording: Bool, isDefault: Bool) {
        shortcutButton.title = displayText
        resetRowButton.isHidden = isDefault
        needsLayout = true
    }

    @objc private func recordTapped() { recordAction() }
    @objc private func resetTapped() { resetAction() }
}
