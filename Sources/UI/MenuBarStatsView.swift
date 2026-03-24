// MenuBarStatsView.swift
// Three-column stat display: words dictated, messages drafted, time saved

import AppKit

@MainActor
final class MenuBarStatsView: NSView {
    private let col1Value = NSTextField(labelWithString: "0")
    private let col1Label = NSTextField(labelWithString: "words\ndictated")
    private let col2Value = NSTextField(labelWithString: "0")
    private let col2Label = NSTextField(labelWithString: "messages\ndrafted")
    private let col3Value = NSTextField(labelWithString: "0 min")
    private let col3Label = NSTextField(labelWithString: "saved")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        for field in [col1Value, col2Value, col3Value] {
            field.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
            field.textColor = MenuTokens.textPrimaryNS
            field.alignment = .center
            addSubview(field)
        }
        for field in [col1Label, col2Label, col3Label] {
            field.font = NSFont.systemFont(ofSize: 11)
            field.textColor = MenuTokens.textSecondaryNS
            field.alignment = .center
            field.maximumNumberOfLines = 2
            addSubview(field)
        }
    }

    override func layout() {
        super.layout()
        let colWidth = bounds.width / 3
        let valueH: CGFloat = 24
        let labelH: CGFloat = 28
        let centerY = bounds.midY

        for (i, (value, label)) in [(col1Value, col1Label), (col2Value, col2Label), (col3Value, col3Label)].enumerated() {
            let x = CGFloat(i) * colWidth
            value.frame = NSRect(x: x, y: centerY, width: colWidth, height: valueH)
            label.frame = NSRect(x: x, y: centerY - labelH - 2, width: colWidth, height: labelH)
        }
    }

    func update(stats: UsageStats) {
        col1Value.stringValue = formatNumber(stats.wordsDictated)
        col2Value.stringValue = "\(stats.messagesDrafted)"
        col3Value.stringValue = formatMinutes(stats.minutesSaved)
        needsLayout = true
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }

    private func formatMinutes(_ m: Int) -> String {
        if m >= 60 {
            return String(format: "%.1f hr", Double(m) / 60.0)
        }
        return "\(m) min"
    }

    var intrinsicHeight: CGFloat { 60 }
}
