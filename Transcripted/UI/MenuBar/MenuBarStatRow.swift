import AppKit

/// Custom NSView for displaying a stat row in the menu bar dropdown.
/// Layout: [icon] [primary label] [flexible space] [secondary label]
@available(macOS 14.0, *)
final class MenuBarStatRow: NSView {

    private let iconView: NSImageView
    private let primaryLabel: NSTextField
    private let secondaryLabel: NSTextField

    private static let rowHeight: CGFloat = 22
    private static let rowWidth: CGFloat = 250

    init(icon: String, iconColor: NSColor, primary: String, secondary: String = "") {
        iconView = NSImageView()
        primaryLabel = NSTextField(labelWithString: primary)
        secondaryLabel = NSTextField(labelWithString: secondary)

        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))

        setupIcon(name: icon, color: iconColor)
        setupLabels()
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupIcon(name: String, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            iconView.image = image
            iconView.contentTintColor = color
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func setupLabels() {
        primaryLabel.font = NSFont.menuFont(ofSize: 13)
        primaryLabel.textColor = .labelColor
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.alignment = .right
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func setupLayout() {
        addSubview(iconView)
        addSubview(primaryLabel)
        addSubview(secondaryLabel)

        NSLayoutConstraint.activate([
            // View size
            widthAnchor.constraint(equalToConstant: Self.rowWidth),
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            // Icon: left-aligned, vertically centered
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            // Primary label: after icon
            primaryLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Secondary label: right-aligned
            secondaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: primaryLabel.trailingAnchor, constant: 8),
            secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            secondaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Public API

    func update(primary: String, secondary: String = "") {
        primaryLabel.stringValue = primary
        secondaryLabel.stringValue = secondary
        secondaryLabel.isHidden = secondary.isEmpty
    }

    func updateIcon(name: String, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            iconView.image = image
            iconView.contentTintColor = color
        }
    }
}
