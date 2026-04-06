// MenuBarShortcutsView.swift
// Compact shortcut rows for the two active capture flows.

import AppKit
import Carbon

@MainActor
final class MenuBarShortcutsView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Shortcuts")
    private let hintLabel = NSTextField(labelWithString: "Click a shortcut to change it")
    private let dictationRow = ShortcutRowView()
    private let meetingRow = ShortcutRowView()
    private var keyMonitor: Any?
    private var recordingTarget: RecordingTarget?

    private enum RecordingTarget {
        case dictation
        case meeting
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = MenuTokens.textMutedNS
        addSubview(hintLabel)

        dictationRow.onSelect = { [weak self] in self?.startRecording(.dictation) }
        meetingRow.onSelect = { [weak self] in self?.startRecording(.meeting) }
        addSubview(dictationRow)
        addSubview(meetingRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 16, width: width, height: 16)
        hintLabel.frame = NSRect(x: 0, y: bounds.height - 30, width: width, height: 12)
        dictationRow.frame = NSRect(x: 0, y: bounds.height - 30 - 6 - 28, width: width, height: 28)
        meetingRow.frame = NSRect(x: 0, y: 0, width: width, height: 24)
    }

    func update(dictationKey: String, meetingKey: String) {
        dictationRow.update(title: "Dictation", key: recordingTarget == .dictation ? "Press shortcut..." : dictationKey, isRecording: recordingTarget == .dictation)
        meetingRow.update(title: "Meetings", key: recordingTarget == .meeting ? "Press shortcut..." : meetingKey, isRecording: recordingTarget == .meeting)
        needsLayout = true
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func startRecording(_ target: RecordingTarget) {
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
            meetingKey: HotkeyPreferences.displayString(for: HotkeyPreferences.meetingBinding())
        )
    }

    var intrinsicHeight: CGFloat { 88 }
}

private final class ShortcutRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let keyBadge = NSTextField(labelWithString: "")
    var onSelect: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius
        layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor
        layer?.borderColor = MenuTokens.cardBorderNS.cgColor
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        keyBadge.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        keyBadge.textColor = MenuTokens.textPrimaryNS
        keyBadge.alignment = .center
        keyBadge.wantsLayer = true
        keyBadge.layer?.cornerRadius = 6
        keyBadge.layer?.backgroundColor = MenuTokens.pillBackgroundNS.cgColor
        keyBadge.layer?.borderWidth = 1
        keyBadge.layer?.borderColor = MenuTokens.pillBorderNS.cgColor
        addSubview(keyBadge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, key: String, isRecording: Bool) {
        titleLabel.stringValue = title
        keyBadge.stringValue = key
        keyBadge.layer?.backgroundColor = (isRecording ? NSColor.systemOrange.withAlphaComponent(0.12) : MenuTokens.pillBackgroundNS).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 9
        let badgeWidth = max(58, keyBadge.fittingSize.width + 14)
        keyBadge.frame = NSRect(x: bounds.width - pad - badgeWidth, y: (bounds.height - 18) / 2, width: badgeWidth, height: 18)
        let textWidth = keyBadge.frame.minX - pad - 8
        titleLabel.frame = NSRect(x: pad, y: (bounds.height - 12) / 2, width: textWidth, height: 12)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}
