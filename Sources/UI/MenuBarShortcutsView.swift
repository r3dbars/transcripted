// MenuBarShortcutsView.swift
// Pill-shaped shortcut badges for the active capture flows.

import AppKit

@MainActor
final class MenuBarShortcutsView: NSView {
    private let pill1 = ShortcutPillView()
    private let pill2 = ShortcutPillView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pill1)
        addSubview(pill2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pill1Size = pill1.fittingSize
        let pill2Size = pill2.fittingSize
        let y = (bounds.height - pill1Size.height) / 2
        pill1.frame = NSRect(x: 0, y: y, width: pill1Size.width, height: pill1Size.height)
        pill2.frame = NSRect(x: pill1Size.width + 12, y: y, width: pill2Size.width, height: pill2Size.height)
    }

    func update(dictationKey: String, meetingKey: String) {
        pill1.update(key: dictationKey, label: "Dictation")
        pill2.update(key: meetingKey, label: "Meetings")
        needsLayout = true
    }

    var intrinsicHeight: CGFloat { 32 }
}

private final class ShortcutPillView: NSView {
    private let keyLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.pillCornerRadius
        layer?.backgroundColor = MenuTokens.pillBackgroundNS.cgColor
        layer?.borderColor = MenuTokens.pillBorderNS.cgColor
        layer?.borderWidth = 1

        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        keyLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(keyLabel)

        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(nameLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(key: String, label: String) {
        keyLabel.stringValue = key
        nameLabel.stringValue = label
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var fittingSize: NSSize {
        let kSize = keyLabel.fittingSize
        let nSize = nameLabel.fittingSize
        return NSSize(width: kSize.width + 4 + nSize.width + 20, height: max(kSize.height, nSize.height) + 10)
    }

    override func layout() {
        super.layout()
        let kSize = keyLabel.fittingSize
        let nSize = nameLabel.fittingSize
        let y = (bounds.height - kSize.height) / 2
        keyLabel.frame = NSRect(x: 10, y: y, width: kSize.width, height: kSize.height)
        nameLabel.frame = NSRect(x: 10 + kSize.width + 4, y: y, width: nSize.width, height: nSize.height)
    }
}
