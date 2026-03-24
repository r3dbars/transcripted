// OverlayDiffStripView.swift
// Compact word-level diff strip showing changes between AI draft and user edits

import AppKit

@MainActor
final class OverlayDiffStripView: NSView {
    private let scrollView = NSScrollView()
    private let contentField = NSTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")
    private let descriptionIcon = NSImageView()
    private let descriptionLabel = NSTextField(labelWithString: "")

    /// Whether to show the full diff view (DiffFlash) or the compact strip (review)
    var isFullDiffMode: Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Horizontal scroll for change badges
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        contentField.isBezeled = false
        contentField.isEditable = false
        contentField.drawsBackground = false
        contentField.maximumNumberOfLines = 1
        contentField.lineBreakMode = .byClipping
        scrollView.documentView = contentField
        addSubview(scrollView)

        // Word delta label (+2 / -1)
        deltaLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        deltaLabel.isBezeled = false
        deltaLabel.isEditable = false
        deltaLabel.drawsBackground = false
        deltaLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(deltaLabel)

        // Description icon (brain symbol, for full diff mode)
        if let image = NSImage(systemSymbolName: "brain", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            descriptionIcon.image = image.withSymbolConfiguration(config)
            descriptionIcon.contentTintColor = OverlayTokens.accentGreen
        }
        descriptionIcon.isHidden = true
        addSubview(descriptionIcon)

        // Description label
        descriptionLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        descriptionLabel.textColor = OverlayTokens.accentGreen
        descriptionLabel.isBezeled = false
        descriptionLabel.isEditable = false
        descriptionLabel.drawsBackground = false
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.isHidden = true
        addSubview(descriptionLabel)
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding

        if isFullDiffMode {
            // Full diff: scroll view fills most of space, description at bottom
            let descHeight: CGFloat = descriptionLabel.isHidden ? 0 : 20
            scrollView.frame = NSRect(
                x: pad, y: descHeight + 10,
                width: bounds.width - pad * 2,
                height: bounds.height - descHeight - 20
            )
            descriptionIcon.frame = NSRect(x: pad, y: 5, width: 14, height: 14)
            descriptionLabel.frame = NSRect(
                x: pad + 20, y: 5,
                width: bounds.width - pad * 2 - 20,
                height: 16
            )
            deltaLabel.isHidden = true
        } else {
            // Compact strip
            let deltaSize = deltaLabel.fittingSize
            let deltaWidth = deltaLabel.stringValue.isEmpty ? 0 : deltaSize.width + 6
            scrollView.frame = NSRect(
                x: pad, y: 0,
                width: bounds.width - pad * 2 - deltaWidth,
                height: bounds.height
            )
            deltaLabel.frame = NSRect(
                x: bounds.width - pad - deltaSize.width,
                y: (bounds.height - deltaSize.height) / 2,
                width: deltaSize.width,
                height: deltaSize.height
            )
        }

        // Size content field to fit
        let fittingSize = contentField.fittingSize
        contentField.frame = NSRect(
            x: 0, y: (scrollView.frame.height - fittingSize.height) / 2,
            width: max(scrollView.frame.width, fittingSize.width),
            height: fittingSize.height
        )
    }

    func update(original: String, edited: String, description: String = "") {
        let ops = DiffSummary.computeWordDiff(original: original, edited: edited)
        let changeGroups = buildChangeGroups(ops)

        // Build attributed string for change badges
        let result = NSMutableAttributedString()
        let dotAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: OverlayTokens.textMuted
        ]

        for (i, group) in changeGroups.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(string: " \u{00B7} ", attributes: dotAttrs))
            }
            for op in group {
                switch op {
                case .equal:
                    break
                case .delete(let word):
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: OverlayTokens.diffDeleteText,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: OverlayTokens.diffDeleteText
                    ]
                    result.append(NSAttributedString(string: word + " ", attributes: attrs))
                case .insert(let word):
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: OverlayTokens.diffInsertText
                    ]
                    result.append(NSAttributedString(string: word + " ", attributes: attrs))
                case .replace(let old, let new):
                    let delAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: OverlayTokens.diffDeleteText,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: OverlayTokens.diffDeleteText
                    ]
                    let insAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: OverlayTokens.diffReplaceText
                    ]
                    result.append(NSAttributedString(string: old, attributes: delAttrs))
                    result.append(NSAttributedString(string: " ", attributes: dotAttrs))
                    result.append(NSAttributedString(string: new + " ", attributes: insAttrs))
                }
            }
        }

        contentField.attributedStringValue = result

        // Word delta
        let editedWords = edited.split(whereSeparator: \.isWhitespace).count
        let originalWords = original.split(whereSeparator: \.isWhitespace).count
        let delta = editedWords - originalWords
        if delta != 0 {
            deltaLabel.stringValue = delta > 0 ? "+\(delta)" : "\(delta)"
            deltaLabel.textColor = delta < 0 ? OverlayTokens.diffDeleteText : OverlayTokens.diffInsertText
        } else {
            deltaLabel.stringValue = ""
        }

        // Description (for full diff mode)
        if !description.isEmpty {
            descriptionIcon.isHidden = false
            descriptionLabel.isHidden = false
            descriptionLabel.stringValue = description
        } else {
            descriptionIcon.isHidden = true
            descriptionLabel.isHidden = true
        }

        needsLayout = true
    }

    /// Group consecutive non-equal ops, separated by runs of equal ops.
    private func buildChangeGroups(_ ops: [DiffOp]) -> [[DiffOp]] {
        var groups: [[DiffOp]] = []
        var current: [DiffOp] = []
        for op in ops {
            if case .equal = op {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
            } else {
                current.append(op)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
