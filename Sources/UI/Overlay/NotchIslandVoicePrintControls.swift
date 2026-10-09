// NotchIslandVoicePrintControls.swift
// The pieces around a voice print in the island's speaker review
// (Prints.dc.html): the hover slot that holds the print, the round ✕ and ✓,
// the small text buttons ("Undo", "Not Priya?"), the glowing dots and count
// in the footer, and the light tip under a hovered print. The print itself is
// VoicePrintView; the rules for what shows are NotchIslandSpeakerReviewPolicy.

import AppKit

/// Holds a row's VoicePrintView and reports the pointer resting on it, for
/// the tip. It never clips, so the match animation can spill past the print
/// (`VoicePrintView.cascadeOutset`).
@MainActor
final class NotchIslandPrintSlot: NSView {
    let print: VoicePrintView
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    init(print: VoicePrintView) {
        self.print = print
        super.init(frame: NSRect(x: 0, y: 0, width: print.diameter, height: print.diameter))
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false
        print.translatesAutoresizingMaskIntoConstraints = false
        addSubview(print)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: print.diameter),
            heightAnchor.constraint(equalToConstant: print.diameter),
            print.centerXAnchor.constraint(equalTo: centerXAnchor),
            print.centerYAnchor.constraint(equalTo: centerYAnchor),
            print.widthAnchor.constraint(equalToConstant: print.diameter),
            print.heightAnchor.constraint(equalToConstant: print.diameter),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The round 36 pt answer buttons: a dark ✕ and a white ✓ with a black
/// check, icons only (VoiceOver gets the words).
@MainActor
final class NotchIslandRoundIconButton: NSButton {
    enum Kind {
        case no
        case yes
    }

    static let side: CGFloat = 36
    var onPress: (() -> Void)?
    private let kind: Kind
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateBackground() }
    }

    init(kind: Kind, accessibilityLabel: String) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel(accessibilityLabel)
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

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
        let color: NSColor
        switch kind {
        case .no:
            color = NSColor(white: 1, alpha: isHighlighted ? 0.2 : (isHovered ? 0.16 : 0.09))
        case .yes:
            color = NSColor(white: isHighlighted ? 0.82 : (isHovered ? 0.9 : 1), alpha: 1)
        }
        layer?.backgroundColor = color.cgColor
    }

    /// The mockup's 12 pt ✕ and 14 pt ✓, centered.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch kind {
        case .no:
            let origin = NSPoint(x: bounds.midX - 6, y: bounds.midY - 6)
            path.move(to: NSPoint(x: origin.x + 2.5, y: origin.y + 2.5))
            path.line(to: NSPoint(x: origin.x + 9.5, y: origin.y + 9.5))
            path.move(to: NSPoint(x: origin.x + 9.5, y: origin.y + 2.5))
            path.line(to: NSPoint(x: origin.x + 2.5, y: origin.y + 9.5))
            path.lineWidth = 1.8
            NSColor(white: 1, alpha: 0.85).setStroke()
        case .yes:
            let origin = NSPoint(x: bounds.midX - 7, y: bounds.midY - 7)
            path.move(to: NSPoint(x: origin.x + 2.5, y: origin.y + 7.5))
            path.line(to: NSPoint(x: origin.x + 5.8, y: origin.y + 10.5))
            path.line(to: NSPoint(x: origin.x + 11.5, y: origin.y + 3.5))
            path.lineWidth = 2
            NSColor.black.setStroke()
        }
        path.stroke()
    }

    @objc private func pressed() { onPress?() }
}

/// A small text button ("Undo", "Not Priya?", "Later") that brightens to
/// white under the pointer.
@MainActor
final class NotchIslandTextButton: NSButton {
    var onPress: (() -> Void)?
    private let restAlpha: CGFloat
    private let fontSize: CGFloat
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { applyTitle() }
    }
    private var text: String

    init(title: String, fontSize: CGFloat = 12, restAlpha: CGFloat = 0.42) {
        self.text = title
        self.restAlpha = restAlpha
        self.fontSize = fontSize
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyTitle()
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: ceil(base.width) + 8, height: max(24, ceil(base.height) + 12))
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

    private func applyTitle() {
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: isHovered ? 1 : restAlpha),
            ]
        )
    }

    @objc private func pressed() { onPress?() }
}

/// An 8 pt dot in a person's color with a soft glow, for the footer's
/// "N people named automatically". A dot that just joined pops in once the
/// print has re-formed (a fade under Reduce Motion).
@MainActor
final class NotchIslandGlowDot: NSView {
    static let side: CGFloat = 8
    private let dot = CALayer()

    init(color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        dot.backgroundColor = color.cgColor
        dot.cornerRadius = Self.side / 2
        dot.shadowColor = color.cgColor
        dot.shadowOpacity = 0.6
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        dot.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        layer?.addSublayer(dot)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func setColor(_ color: NSColor) {
        guard dot.backgroundColor != color.cgColor else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        dot.shadowColor = color.cgColor
        CATransaction.commit()
    }

    /// The mockup's footer sparkle (`PX.sparks`): eight 2 pt squares in the
    /// dot's color push out from it and fade; the two on the level twinkle
    /// white once. Not under Reduce Motion (the caller skips it).
    func sparkle(after delay: CFTimeInterval = 0) {
        guard let host = layer, let color = dot.backgroundColor else { return }
        let start = host.convertTime(CACurrentMediaTime(), from: nil) + delay
        let curve = CAMediaTimingFunction(controlPoints: 0.15, 0.8, 0.3, 1)
        var squares: [CALayer] = []
        CATransaction.begin()
        CATransaction.setCompletionBlock { squares.forEach { $0.removeFromSuperlayer() } }
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let (ux, uy) = (cos(angle), sin(angle))
            let onAxis = index % 2 == 0
            let reach: Double = onAxis ? 6 : 4
            let square = CALayer()
            square.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
            square.cornerRadius = 0.5
            square.backgroundColor = color
            square.position = CGPoint(x: Self.side / 2 + (ux * 5).rounded(), y: Self.side / 2 + (uy * 5).rounded())
            square.opacity = 0
            host.addSublayer(square)
            squares.append(square)
            let begin = start + 0.04 + Double(index) * VoicePrintCascadePlan.FooterLanding.sparkleStagger
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, onAxis ? 0.95 : 0.55, 0]
            fade.keyTimes = [0, 0.22, 1]
            fade.timingFunctions = [curve, curve]
            let push = CABasicAnimation(keyPath: "transform.translation")
            push.fromValue = NSValue(size: .zero)
            push.toValue = NSValue(size: NSSize(width: (ux * reach).rounded(), height: (uy * reach).rounded()))
            push.timingFunction = curve
            let burst = CAAnimationGroup()
            burst.animations = [fade, push]
            burst.beginTime = begin
            burst.duration = VoicePrintCascadePlan.FooterLanding.sparkleDuration
            burst.fillMode = .backwards
            square.add(burst, forKey: "sparkle")
            if index == 0 || index == 4 {
                let twinkle = CAKeyframeAnimation(keyPath: "backgroundColor")
                twinkle.values = [color, NSColor.white.cgColor, color]
                twinkle.keyTimes = [0, 0.5, 1]
                twinkle.beginTime = start + 0.2
                twinkle.duration = 0.36
                twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                square.add(twinkle, forKey: "twinkle")
            }
        }
        CATransaction.commit()
    }

    /// Scale in from nothing with a little overshoot after `delay` seconds
    /// (the mockup's `dot` keyframes), or just fade in under Reduce Motion.
    func popIn(after delay: CFTimeInterval, reduceMotion: Bool) {
        let begin = dot.convertTime(CACurrentMediaTime(), from: nil) + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = begin
        fade.duration = reduceMotion ? 0.3 : VoicePrintCascadePlan.FooterLanding.dotPopDuration
        fade.fillMode = .backwards
        dot.add(fade, forKey: "popIn.opacity")
        guard !reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0
        scale.toValue = 1
        scale.beginTime = begin
        scale.duration = VoicePrintCascadePlan.FooterLanding.dotPopDuration
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.7, 0.5, 1)
        scale.fillMode = .backwards
        dot.add(scale, forKey: "popIn.scale")
    }
}

/// The footer's "2 people named automatically". The number sits on its own
/// so that when someone joins it can tick up in their color and settle to
/// the line's grey (the mockup's `tk`), or just fade in under Reduce Motion.
@MainActor
final class NotchIslandFooterCount: NSStackView {
    static let restColor = NSColor(white: 1, alpha: 0.42)
    private let numberHolder = NSView()
    private let number: NSTextField
    /// The number again in the new person's color, laid over it and faded out.
    private let flash: NSTextField
    private let rest: NSTextField

    init() {
        let font = NSFont.systemFont(ofSize: 12)
        number = NotchIslandPalette.label("", font: font, color: Self.restColor)
        flash = NotchIslandPalette.label("", font: font, color: Self.restColor)
        rest = NotchIslandPalette.label("", font: font, color: Self.restColor)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        // The mockup's .27em after the number.
        spacing = 3
        rest.lineBreakMode = .byTruncatingTail
        rest.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        numberHolder.wantsLayer = true
        numberHolder.translatesAutoresizingMaskIntoConstraints = false
        flash.wantsLayer = true
        flash.alphaValue = 0
        for label in [number, flash] {
            label.translatesAutoresizingMaskIntoConstraints = false
            numberHolder.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: numberHolder.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: numberHolder.trailingAnchor),
                label.topAnchor.constraint(equalTo: numberHolder.topAnchor),
                label.bottomAnchor.constraint(equalTo: numberHolder.bottomAnchor),
            ])
        }
        numberHolder.setContentHuggingPriority(.required, for: .horizontal)
        numberHolder.setContentCompressionResistancePriority(.required, for: .horizontal)
        addArrangedSubview(numberHolder)
        addArrangedSubview(rest)
        setHuggingPriority(.defaultLow, for: .horizontal)
        setClippingResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `text` from SpeakerNamingTierPresentation.autoNamedFooter, or nil to
    /// hide. `tickColor`: someone just joined, in this color.
    func setText(_ text: String?, tickColor: NSColor?, tickDelay: CFTimeInterval = 0, reduceMotion: Bool) {
        guard let text, let space = text.firstIndex(of: " ") else {
            isHidden = true
            return
        }
        isHidden = false
        let count = String(text[..<space])
        number.stringValue = count
        flash.stringValue = count
        rest.stringValue = String(text[text.index(after: space)...])
        setAccessibilityLabel(text)
        guard let tickColor, let holder = numberHolder.layer else { return }
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            holder.add(fade, forKey: "tick")
            return
        }
        // Rises 5 pt and fades in over the first half, then the color
        // settles to grey over the second.
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.25)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1]
        fade.keyTimes = [0, 0.5, 1]
        fade.timingFunctions = [curve, curve]
        let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
        rise.values = [holder.contentsAreFlipped() ? 5 : -5, 0, 0]
        rise.keyTimes = [0, 0.5, 1]
        rise.timingFunctions = [curve, curve]
        let tick = CAAnimationGroup()
        tick.animations = [fade, rise]
        tick.beginTime = holder.convertTime(CACurrentMediaTime(), from: nil) + tickDelay
        tick.duration = VoicePrintCascadePlan.FooterLanding.countTickDuration
        tick.fillMode = .backwards
        holder.add(tick, forKey: "tick")
        flash.textColor = tickColor
        if let flashLayer = flash.layer {
            let settle = CAKeyframeAnimation(keyPath: "opacity")
            settle.values = [1, 1, 0]
            settle.keyTimes = [0, 0.5, 1]
            settle.beginTime = flashLayer.convertTime(CACurrentMediaTime(), from: nil) + tickDelay
            settle.duration = VoicePrintCascadePlan.FooterLanding.countTickDuration
            settle.fillMode = .backwards
            flashLayer.add(settle, forKey: "tick")
        }
    }
}

/// The light tip under a hovered print: how far the person is toward being
/// named on their own. Drawn by the island because system tooltips don't
/// show reliably over a non-activating panel.
@MainActor
final class NotchIslandPrintTip: NSView {
    static let width: CGFloat = 220
    private let label: NSTextField

    init() {
        label = NotchIslandPalette.label(
            "",
            font: .systemFont(ofSize: 11.5),
            color: NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1),
            wraps: true,
            width: Self.width - 20
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 0.97).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        // VoiceOver reads the same words as the print's help.
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks pass through to whatever is under the tip.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}
