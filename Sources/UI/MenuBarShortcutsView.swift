// MenuBarShortcutsView.swift
// Compact shortcut rows for the two active capture flows.

import AppKit

@MainActor
final class MenuBarShortcutsView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Shortcuts")
    private let dictationRow = ShortcutRowView()
    private let meetingRow = ShortcutRowView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)
        addSubview(dictationRow)
        addSubview(meetingRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 16, width: width, height: 16)
        dictationRow.frame = NSRect(x: 0, y: bounds.height - 16 - 6 - 24, width: width, height: 24)
        meetingRow.frame = NSRect(x: 0, y: 0, width: width, height: 24)
    }

    func update(dictationKey: String, meetingKey: String) {
        dictationRow.update(title: "Dictation", detail: "Paste spoken text", key: dictationKey)
        meetingRow.update(title: "Meetings", detail: "Transcribe mic and system audio", key: meetingKey)
        needsLayout = true
    }

    var intrinsicHeight: CGFloat { 70 }
}

private final class ShortcutRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let keyBadge = NSTextField(labelWithString: "")

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

        detailLabel.font = NSFont.systemFont(ofSize: 9)
        detailLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(detailLabel)

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

    func update(title: String, detail: String, key: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        keyBadge.stringValue = key
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 9
        let badgeWidth = max(48, keyBadge.fittingSize.width + 14)
        keyBadge.frame = NSRect(x: bounds.width - pad - badgeWidth, y: 3, width: badgeWidth, height: 18)
        let textWidth = keyBadge.frame.minX - pad - 8
        titleLabel.frame = NSRect(x: pad, y: bounds.height - 14, width: textWidth, height: 12)
        detailLabel.frame = NSRect(x: pad, y: 3, width: textWidth, height: 10)
    }
}
