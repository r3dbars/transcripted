// NotchIslandSpeakerReviewControls.swift
// Small AppKit controls used by the island's speaker review
// (`NotchIslandSpeakerReviewView.swift`): the clip play/pause button, the
// name box, and the suggestion rows under it.

import AppKit

// MARK: - Controls

/// Play / pause for a voice clip: a round 30 pt face with the glyph on
/// top. While the clip plays, a ring fills around it; a full circle means
/// the clip has finished. A plain view rather than an NSButton so it stays
/// exactly square (and so exactly round) inside the row's stack.
@available(macOS 14.0, *)
@MainActor
final class NotchIslandClipButton: NSView {
    var onPress: (() -> Void)?
    private let clipURL: URL
    private let glyph = NSImageView()
    private let track = CAShapeLayer()
    private let progressRing = CAShapeLayer()
    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private var isPlaying = false
    private static let size: CGFloat = 30

    init(clipURL: URL) {
        self.clipURL = clipURL
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 0.5),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for (shape, color) in [(track, NSColor(white: 1, alpha: 0.14)), (progressRing, NSColor.white)] {
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = 2
            shape.lineCap = .round
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        observer = NotificationCenter.default.addObserver(
            forName: SpeakerClipPlayback.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        pollTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        layer?.cornerRadius = side / 2
        // The ring: a circle 4 pt outside the face, from the top, clockwise
        // (y grows downward in this flipped view).
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: side / 2 + 4,
            startAngle: -.pi / 2,
            endAngle: 1.5 * .pi,
            clockwise: false
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        progressRing.frame = bounds
        track.path = path
        progressRing.path = path
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.8
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    private func press() {
        onPress?()
        SpeakerClipPlayback.play(clipURL)
        sync()
    }

    private func sync() {
        let playing = SpeakerClipPlayback.isPlaying(clipURL)
        isPlaying = playing
        glyph.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        glyph.contentTintColor = playing ? .black : .white
        layer?.backgroundColor = (playing ? NSColor.white : NotchIslandPalette.buttonPlain).cgColor
        setAccessibilityLabel(playing ? "Pause clip" : "Play clip")
        track.isHidden = !playing
        progressRing.isHidden = !playing
        pollTimer?.invalidate()
        pollTimer = nil
        if playing {
            updateProgress()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateProgress() }
            }
        }
    }

    private func updateProgress() {
        guard let progress = SpeakerClipPlayback.progress(of: clipURL) else {
            if !SpeakerClipPlayback.isPlaying(clipURL) { sync() }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressRing.strokeEnd = CGFloat(progress)
        CATransaction.commit()
    }
}

/// A name box on the island's black surface. Clicking it asks for the
/// keyboard, since the island never has it otherwise.
@MainActor
final class NotchIslandNameField: NSTextField {
    var onFocusRequest: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBezeled = false
        drawsBackground = true
        backgroundColor = NotchIslandPalette.buttonSubtle
        textColor = NotchIslandPalette.primaryText
        font = .systemFont(ofSize: 14, weight: .semibold)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        placeholderAttributedString = NSAttributedString(
            string: "Type a name…",
            attributes: [
                .foregroundColor: NotchIslandPalette.secondaryText,
                .font: NSFont.systemFont(ofSize: 14),
            ]
        )
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("Name for this voice")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onFocusRequest?()
        return super.becomeFirstResponder()
    }
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
