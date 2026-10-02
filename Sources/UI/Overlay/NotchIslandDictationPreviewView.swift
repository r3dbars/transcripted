// NotchIslandDictationPreviewView.swift
// The dictation hover's live words: three lines, newest at the bottom,
// older text fading out at the top. Words the decoder may still rewrite are
// dimmed. When the take is written, the rough words crossfade into the real
// text. Kept alive by the island controller across drop-down rebuilds and
// updated in place, like the meeting's live transcript view.

import AppKit

@MainActor
final class NotchIslandDictationPreviewView: NSView {
    static let visibleLines = 3
    static let lineHeight: CGFloat = 20
    static var height: CGFloat { CGFloat(visibleLines) * lineHeight }
    /// The last words of the partial are still settling.
    static let tentativeWordCount = 2
    /// Only the tail ever shows; capping keeps a long take's layout cheap.
    static let maximumCharacters = 600

    private static let font = NSFont.systemFont(ofSize: 14)
    private static let settledColor = NotchIslandPalette.bodyText
    private static let tentativeColor = NSColor(white: 1, alpha: 0.42)

    private let width: CGFloat
    private let roughLabel: NSTextField
    private let finalLabel: NSTextField
    private let placeholder: NSTextField
    private let fade = CAGradientLayer()
    /// The written text, once the take landed; nil while it's still rough.
    private(set) var finalText: String?
    private(set) var hasWords = false

    init(width: CGFloat) {
        self.width = width
        roughLabel = NotchIslandPalette.label("", font: Self.font, color: Self.settledColor, wraps: true, width: width)
        finalLabel = NotchIslandPalette.label("", font: Self.font, color: Self.settledColor, wraps: true, width: width)
        placeholder = NotchIslandPalette.label("Listening…", font: Self.font, color: NotchIslandPalette.secondaryText)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        wantsLayer = true
        layer?.masksToBounds = true
        // Older lines fade out under the top edge instead of being cut.
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.3, 1]
        layer?.mask = fade
        for label in [roughLabel, finalLabel] {
            label.maximumNumberOfLines = 0
            addSubview(label)
        }
        finalLabel.alphaValue = 0
        addSubview(placeholder)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Live dictation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The rough words so far. A new take (nothing heard yet) also clears
    /// the last take's written text.
    func apply(_ preview: LiveDictationPreview, settling: Bool) {
        if preview.isEmpty {
            finalText = nil
            finalLabel.alphaValue = 0
            roughLabel.alphaValue = 1
        }
        guard finalText == nil else { return }
        hasWords = !preview.isEmpty
        placeholder.isHidden = hasWords
        roughLabel.attributedStringValue = Self.attributed(preview, settling: settling)
        setAccessibilityValue(hasWords ? "\(preview.settled) \(preview.tentative)" : "Listening")
        needsLayout = true
    }

    /// The take was written: show the real text in place of the rough words.
    func showFinal(_ text: String) {
        guard hasWords, finalText != text else { return }
        finalText = text
        finalLabel.attributedStringValue = NSAttributedString(
            string: Self.tail(text),
            attributes: [.font: Self.font, .foregroundColor: Self.settledColor]
        )
        setAccessibilityValue(text)
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard !NotchIslandPalette.reduceMotion else {
            roughLabel.alphaValue = 0
            finalLabel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            roughLabel.animator().alphaValue = 0
            finalLabel.animator().alphaValue = 1
        }
    }

    override func layout() {
        super.layout()
        fade.frame = bounds
        for label in [roughLabel, finalLabel] {
            let fitting = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
            // Bottom-aligned: the newest line sits on the bottom edge.
            label.frame = NSRect(x: 0, y: bounds.height - ceil(fitting), width: width, height: ceil(fitting))
        }
        let placeholderHeight = ceil(placeholder.fittingSize.height)
        placeholder.frame = NSRect(x: 0, y: bounds.height - placeholderHeight, width: width, height: placeholderHeight)
    }

    static func attributed(_ preview: LiveDictationPreview, settling: Bool) -> NSAttributedString {
        let parts = preview.split(dimmingLast: settling ? tentativeWordCount : 0)
        let result = NSMutableAttributedString(
            string: tail(parts.settled),
            attributes: [.font: font, .foregroundColor: settledColor]
        )
        if !parts.tentative.isEmpty {
            result.append(NSAttributedString(
                string: (result.length > 0 ? " " : "") + parts.tentative,
                attributes: [.font: font, .foregroundColor: tentativeColor]
            ))
        }
        return result
    }

    private static func tail(_ text: String) -> String {
        guard text.count > maximumCharacters else { return text }
        let cut = text.suffix(maximumCharacters)
        // Start on a word.
        if let space = cut.firstIndex(of: " ") { return String(cut[cut.index(after: space)...]) }
        return String(cut)
    }
}
