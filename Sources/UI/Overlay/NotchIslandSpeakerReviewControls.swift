// NotchIslandSpeakerReviewControls.swift
// Small AppKit controls used by the island's speaker review
// (`NotchIslandSpeakerReviewView.swift`): the title that is also the name
// field, the invitee chips and suggestion rows under it, and the faint
// "Not a person" ×. The print, ✕ / ✓ and text buttons are in
// NotchIslandVoicePrintControls.swift.

import AppKit

// MARK: - Controls

/// The text part of a voice's title-as-name-field. Borderless and clear: the
/// surrounding `NotchIslandTitleField` draws the hover and focus looks.
/// Clicking it asks for the keyboard, since the island never has it otherwise.
@MainActor
final class NotchIslandNameField: NSTextField {
    var onFocusRequest: (() -> Void)?
    /// The field took the keyboard (true) or editing ended (false).
    var onFocusChange: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        textColor = NotchIslandPalette.primaryText
        font = Self.titleFont
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byTruncatingTail
        setPlaceholder(alpha: 0.62)
        setAccessibilityLabel("Name this voice")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

    /// "Who's this?" in white at `alpha` (brighter on hover, fainter while typing).
    func setPlaceholder(alpha: CGFloat) {
        placeholderAttributedString = NSAttributedString(
            string: "Who\u{2019}s this?",
            attributes: [
                .foregroundColor: NSColor(white: 1, alpha: alpha),
                .font: Self.titleFont,
            ]
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onFocusRequest?()
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// A voice's title that is also its name field ("Who's this?"). At rest it
/// reads like any other title; on hover a faint rounded highlight and a small
/// pencil fade in; with the keyboard it gets a thin outline. Its text lines
/// up with the other rows' titles: the highlight reaches 9 pt to the left.
@MainActor
final class NotchIslandTitleField: NSView {
    static let height: CGFloat = 30
    /// How far the highlight reaches left of the title's text.
    static let leadingBleed: CGFloat = 9

    let field = NotchIslandNameField()
    private let pencil = NotchIslandPencilView()
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private(set) var isFocused = false
    /// The field took or lost the keyboard.
    var onFocusChange: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        pencil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(pencil)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingBleed),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            pencil.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pencil.centerYAnchor.constraint(equalTo: centerYAnchor),
            pencil.widthAnchor.constraint(equalToConstant: 12),
            pencil.heightAnchor.constraint(equalToConstant: 12),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // AppKit can report an end of editing in the middle of a field taking
        // the keyboard, so read the real state once the change has settled.
        field.onFocusChange = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshFocus() }
        }
        updateLook(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// A click on the padding around the text still starts typing.
    override func mouseDown(with event: NSEvent) {
        field.onFocusRequest?()
        window?.makeKey()
        window?.makeFirstResponder(field)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateLook(animated: true)
    }

    /// The field is being edited right now: the window's field editor is
    /// first responder and is editing this field.
    func refreshFocus() {
        guard let editor = field.currentEditor() else { return setFocused(false) }
        setFocused(window?.firstResponder === editor)
    }

    private func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        updateLook(animated: true)
        onFocusChange?(focused)
    }

    private func updateLook(animated: Bool) {
        let background: CGFloat = isFocused ? 0.07 : (isHovered ? 0.06 : 0)
        let border: CGFloat = isFocused ? 0.2 : 0
        field.setPlaceholder(alpha: isFocused ? 0.32 : (isHovered ? 0.9 : 0.62))
        let pencilAlpha: CGFloat = isHovered && !isFocused ? 0.7 : 0
        let apply = {
            self.layer?.backgroundColor = NSColor(white: 1, alpha: background).cgColor
            self.layer?.borderColor = NSColor(white: 1, alpha: border).cgColor
        }
        if animated, !NotchIslandPalette.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                apply()
                pencil.animator().alphaValue = pencilAlpha
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
            pencil.alphaValue = pencilAlpha
        }
    }
}

/// The small pencil inside a hovered name field (the mockup's 12 pt path).
@MainActor
final class NotchIslandPencilView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8.2, y: 1.8))
        path.line(to: NSPoint(x: 10.2, y: 3.8))
        path.line(to: NSPoint(x: 4.2, y: 9.8))
        path.line(to: NSPoint(x: 1.6, y: 10.4))
        path.line(to: NSPoint(x: 2.2, y: 7.8))
        path.close()
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }
}

/// A one-tap name under a focused name field: an invitee, or "Me". A click
/// doesn't take the keyboard from the field, so the field keeps its caret
/// and the chips stay put until one is picked.
@MainActor
final class NotchIslandChipButton: NSButton {
    var onPress: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateBackground() }
    }

    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 13
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.9)]
        )
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel(title)
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(super.intrinsicContentSize.width) + 22, height: 26)
    }

    override var acceptsFirstResponder: Bool {
        guard let type = NSApp?.currentEvent?.type else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateBackground() {
        let alpha: CGFloat = isHighlighted ? 0.2 : (isHovered ? 0.16 : 0.08)
        layer?.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
    }

    @objc private func pressed() { onPress?() }
}

/// One autocomplete row under the name box.
@MainActor
final class NotchIslandSuggestionButton: NSButton {
    var onPress: (() -> Void)?
    var isHighlightedRow = false {
        didSet { layer?.backgroundColor = (isHighlightedRow ? NotchIslandPalette.buttonPlain : .clear).cgColor }
    }

    init(title: String, detail: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        self.title = ""
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        let name = NotchIslandPalette.label(title, font: .systemFont(ofSize: 14, weight: .semibold), color: NotchIslandPalette.primaryText)
        let note = NotchIslandPalette.label(detail, font: .systemFont(ofSize: 12), color: NotchIslandPalette.secondaryText)
        let row = NSStackView(views: [name, NSView(), note])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("\(title), \(detail)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func pressed() { onPress?() }
}

/// The small × on a voice that isn't a person. It stays faint until the
/// pointer rests on it; then a short label to its left says what it does.
/// The label is drawn by the island itself because system tooltips don't
/// show reliably over a non-activating panel.
@MainActor
final class NotchIslandDiscardControl: NSStackView {
    private let tip = NSView()
    private let x = NotchIslandHoverButton()
    private var showTask: Task<Void, Never>?

    init(onPress: @escaping () -> Void) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        let label = NotchIslandPalette.label(
            NotchIslandSpeakerReviewPolicy.discardTooltip,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: NotchIslandPalette.primaryText
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        // The label never clips; the quote beside it truncates instead.
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        tip.wantsLayer = true
        tip.layer?.backgroundColor = NotchIslandPalette.buttonPlain.cgColor
        tip.layer?.cornerRadius = 6
        tip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: tip.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: tip.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: tip.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: tip.bottomAnchor, constant: -4),
        ])
        tip.isHidden = true

        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) {
            x.image = image
        }
        x.imagePosition = .imageOnly
        x.isBordered = false
        x.wantsLayer = true
        x.layer?.cornerRadius = 12
        x.contentTintColor = NotchIslandPalette.secondaryText
        x.translatesAutoresizingMaskIntoConstraints = false
        x.widthAnchor.constraint(equalToConstant: 24).isActive = true
        x.heightAnchor.constraint(equalToConstant: 24).isActive = true
        x.onPress = onPress
        x.onHover = { [weak self] inside in self?.setHovered(inside) }
        x.setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.discardTitle(discarded: false))
        x.setAccessibilityHelp(NotchIslandSpeakerReviewPolicy.discardHelp)
        addArrangedSubview(tip)
        addArrangedSubview(x)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setHovered(_ inside: Bool) {
        x.layer?.backgroundColor = inside ? NotchIslandPalette.buttonPlain.cgColor : NSColor.clear.cgColor
        x.contentTintColor = inside ? NotchIslandPalette.primaryText : NotchIslandPalette.secondaryText
        showTask?.cancel()
        guard inside else {
            tip.isHidden = true
            return
        }
        // A short rest first, like a system tooltip, so passing over it is quiet.
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.tip.isHidden = false
        }
    }
}

/// A borderless button that reports the pointer entering and leaving it.
@MainActor
final class NotchIslandHoverButton: NSButton {
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next)
        area = next
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func pressed() { onPress?() }
}
