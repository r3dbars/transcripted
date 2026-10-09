// VoicePrintView.swift
// A saved person's voice print: five concentric rings, each open at the
// person's own angle (VoicePrintStyle), lit innermost first in their color as
// meetings confirm them, with a play button in the middle. It is the person's
// face in the island's speaker review and in Settings › Speakers. A click
// anywhere on it (or Space / Return when it has keyboard focus) calls `onPlay`;
// the host plays the clip and sets `isPlaying`. No audio happens here.
//
// Everything is Core Animation on layers built once: geometry and colors come
// from VoicePrintGeometry / VoicePrintInk (UI/Shared, tested), the match
// animation is VoicePrintView+Cascade.swift, and nothing runs per frame on the
// main thread.
//
// Overflow: the cascade draws outside the bounds and the view doesn't clip
// it (masksToBounds is off all the way down). Hosts must leave
// `cascadeOutset(diameter:kind:)` unclipped on every side of the print: for a
// 42-point print that's 45 points for the full version's burst and 9 points
// for the small one (the hover scale and glow fit inside the small one). Any
// superview or layer in between that clips (a scroll view's clip view, a
// rounded card with masksToBounds) cuts the burst at its edge. For Auto
// Layout, size it by its intrinsic size (diameter x diameter).
//
// Orientation: the print's own layers are always y-down on screen, whatever
// AppKit does with the host layer's flipping (`syncOrientation()`), so gap
// angles read clockwise from 3 o'clock as in the mockup.

import AppKit

@MainActor
final class VoicePrintView: NSView {
    enum Surface: Equatable {
        case island
        case settingsDark
        case settingsLight
    }

    struct Model: Equatable {
        var style: VoicePrintStyle
        /// Index into `VoicePrintStyle.palette`.
        var colorIndex: Int
        /// 0...5, innermost first.
        var litRings: Int
        var surface: Surface

        init(style: VoicePrintStyle, colorIndex: Int, litRings: Int, surface: Surface) {
            self.style = style
            self.colorIndex = colorIndex
            self.litRings = litRings
            self.surface = surface
        }
    }

    let diameter: CGFloat

    /// Setting it redraws without animation and stops a running cascade,
    /// which was drawn for the old model.
    var model: Model {
        get { currentModel }
        set {
            guard newValue != currentModel else { return }
            stopCascade()
            currentModel = newValue
            render()
        }
    }

    /// Pause glyph and a brighter well while true; the rings ripple outward
    /// on a loop unless Reduce Motion is on.
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            renderPlayback(animated: true)
            NSAccessibility.post(element: self, notification: .titleChanged)
        }
    }

    /// A click anywhere in the print, Space / Return while focused, or
    /// VoiceOver's press.
    var onPlay: (() -> Void)?

    /// First name (or full name) for VoiceOver: "Play Priya's clip".
    var accessibilityName: String?

    /// False for a print with no clip behind it (a name recognized without
    /// audio): no well or play glyph, no pointer, keyboard or VoiceOver
    /// button. The host labels the row.
    var isPlayable = true {
        didSet {
            guard isPlayable != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wellLayer.isHidden = !isPlayable
            glyphLayer.isHidden = !isPlayable
            CATransaction.commit()
            window?.invalidateCursorRects(for: self)
        }
    }

    // Shared with VoicePrintView+Cascade.swift.
    var currentModel: Model
    /// Rings, well and glyph; it scales on hover and carries the glow.
    let printLayer = CALayer()
    let ringLayers: [CAShapeLayer]
    let wellLayer = CAShapeLayer()
    let glyphLayer = CAShapeLayer()
    /// Zero-sized, at the print's center; the cascade's squares live here,
    /// above the print and unaffected by the hover scale.
    let effectsLayer = CALayer()
    var squarePool: [CALayer] = []
    var liveSquares: [CALayer] = []
    var cascadeGeneration = 0

    private var isHovered = false
    private var isPressed = false
    private var hoverArea: NSTrackingArea?
    private static let rippleKey = "voicePrint.ripple"
    private static let pressKey = "voicePrint.press"
    private static let wellFadeKey = "voicePrint.wellFade"

    init(diameter: CGFloat = 42, model: Model) {
        self.diameter = diameter
        self.currentModel = model
        self.ringLayers = VoicePrintStyle.ringRadii.map { _ in CAShapeLayer() }
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        buildLayers()
        render()
        renderPlayback(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// How far past its bounds the print may draw while celebrating, on every
    /// side. Leave this much unclipped around it (`.full` covers both).
    static func cascadeOutset(diameter: CGFloat, kind: VoicePrintCascadePlan.Kind = .full) -> CGFloat {
        ceil(CGFloat(VoicePrintCascadePlan.outset(kind)) * diameter / CGFloat(VoicePrintGeometry.designSize))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
    }

    override func layout() {
        super.layout()
        centerLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        centerLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in ringLayers + [wellLayer, glyphLayer] {
            shape.contentsScale = backingScale
        }
        CATransaction.commit()
    }

    // MARK: - Drawing

    /// Points per design point.
    var scale: CGFloat { diameter / CGFloat(VoicePrintGeometry.designSize) }

    var tone: VoicePrintTone { currentModel.surface == .settingsLight ? .light : .dark }

    /// Ring colors, glow and well for the current model, with no animation.
    func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let arcs = VoicePrintGeometry.arcs(for: currentModel.style)
        let colors = VoicePrintInk.ringColors(colorIndex: currentModel.colorIndex, litRings: currentModel.litRings, tone: tone)
        for (index, ring) in ringLayers.enumerated() {
            ring.path = index < arcs.count ? ringPath(arcs[index]) : nil
            ring.strokeColor = colors[index].cgColor
            ring.lineWidth = CGFloat(VoicePrintGeometry.strokeWidth) * scale
        }
        printLayer.shadowColor = VoicePrintInk.personColor(colorIndex: currentModel.colorIndex, tone: tone).cgColor
        printLayer.shadowOpacity = Float(VoicePrintInk.glowOpacity(litRings: currentModel.litRings, tone: tone))
        wellLayer.fillColor = VoicePrintInk.well(tone: tone, isPlaying: isPlaying).cgColor
        CATransaction.commit()
    }

    private func buildLayers() {
        guard let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        printLayer.bounds = side
        printLayer.masksToBounds = false
        printLayer.shadowOffset = .zero
        printLayer.shadowRadius = CGFloat(VoicePrintGeometry.glowBlur / 2) * scale
        for ring in ringLayers {
            ring.frame = side
            ring.fillColor = nil
            ring.lineCap = .round
            ring.contentsScale = backingScale
            printLayer.addSublayer(ring)
        }
        let center = point(VoicePrintGeometry.center)
        let wellRadius = CGFloat(VoicePrintGeometry.wellRadius) * scale
        wellLayer.frame = side
        wellLayer.path = CGPath(ellipseIn: CGRect(x: center.x - wellRadius, y: center.y - wellRadius, width: wellRadius * 2, height: wellRadius * 2), transform: nil)
        wellLayer.contentsScale = backingScale
        printLayer.addSublayer(wellLayer)
        glyphLayer.frame = side
        glyphLayer.fillColor = VoicePrintInk.glyph.cgColor
        glyphLayer.contentsScale = backingScale
        printLayer.addSublayer(glyphLayer)
        // Zero-sized, so square positions are offsets from the print's center.
        effectsLayer.bounds = .zero
        effectsLayer.masksToBounds = false
        host.addSublayer(printLayer)
        host.addSublayer(effectsLayer)
        CATransaction.commit()
        centerLayers()
    }

    private func centerLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        printLayer.position = middle
        effectsLayer.position = middle
        syncOrientation()
        CATransaction.commit()
    }

    /// Paths and square offsets are y-down, like the mockup's SVG. AppKit may
    /// or may not flip the host layer (it depends on the view and its
    /// superviews), so the print's own layers flip themselves whenever the
    /// host's space isn't already y-down on screen. `contentsAreFlipped()`
    /// counts every flipped layer up to the window, which is what decides it.
    func syncOrientation() {
        guard let host = layer else { return }
        let flip = !host.contentsAreFlipped()
        guard printLayer.isGeometryFlipped != flip || effectsLayer.isGeometryFlipped != flip else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        printLayer.isGeometryFlipped = flip
        effectsLayer.isGeometryFlipped = flip
        CATransaction.commit()
    }

    /// A design-box point in the print layer's coordinates (y-down on screen).
    func point(_ point: VoicePrintGeometry.Point) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * scale, y: CGFloat(point.y) * scale)
    }

    private func ringPath(_ arc: VoicePrintGeometry.Arc) -> CGPath {
        let path = CGMutablePath()
        // Y is down, so increasing angles (clockwise: false) run clockwise on screen.
        path.addArc(
            center: point(VoicePrintGeometry.center),
            radius: CGFloat(arc.radius) * scale,
            startAngle: CGFloat(arc.startAngle * .pi / 180),
            endAngle: CGFloat(arc.endAngle * .pi / 180),
            clockwise: false
        )
        return path
    }

    private var playGlyphPath: CGPath {
        let path = CGMutablePath()
        path.addLines(between: VoicePrintGeometry.playTriangle.map { point($0) })
        path.closeSubpath()
        return path
    }

    private var pauseGlyphPath: CGPath {
        let path = CGMutablePath()
        for bar in VoicePrintGeometry.pauseBars {
            let origin = point(VoicePrintGeometry.Point(x: bar.x, y: bar.y))
            path.addRect(CGRect(x: origin.x, y: origin.y, width: CGFloat(bar.width) * scale, height: CGFloat(bar.height) * scale))
        }
        return path
    }

    // MARK: - Playback

    private func renderPlayback(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fill = VoicePrintInk.well(tone: tone, isPlaying: isPlaying).cgColor
        if animated, let current = wellLayer.presentation()?.fillColor ?? wellLayer.fillColor {
            let fade = CABasicAnimation(keyPath: "fillColor")
            fade.fromValue = current
            fade.toValue = fill
            fade.duration = VoicePrintCascadePlan.wellFadeDuration
            fade.timingFunction = VoicePrintCascadePlan.Curve.ease.mediaTimingFunction
            wellLayer.add(fade, forKey: Self.wellFadeKey)
        }
        wellLayer.fillColor = fill
        glyphLayer.path = isPlaying ? pauseGlyphPath : playGlyphPath
        CATransaction.commit()
        if isPlaying {
            startRipple()
        } else {
            stopRipple()
        }
    }

    /// The rings pulse outward on a loop; it replaces a running dissolve.
    private func startRipple() {
        guard !AccessibilityDisplayPolicy.reduceMotion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let start = printLayer.convertTime(CACurrentMediaTime(), from: nil)
        for (index, ring) in ringLayers.enumerated() {
            removeRingCascade(from: ring)
            let pulse = Self.keyframes(
                "opacity",
                VoicePrintCascadePlan.ripple,
                duration: VoicePrintCascadePlan.rippleDuration,
                begin: start + Double(index) * VoicePrintCascadePlan.rippleStagger
            )
            pulse.repeatCount = .infinity
            ring.add(pulse, forKey: Self.rippleKey)
        }
        CATransaction.commit()
    }

    private func stopRipple() {
        for ring in ringLayers {
            ring.removeAnimation(forKey: Self.rippleKey)
        }
    }

    // MARK: - Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isPlayable ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        guard isPlayable else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isPlayable else { return super.cursorUpdate(with: event) }
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isPlayable else { return }
        isHovered = true
        updatePressScale()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updatePressScale()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updatePressScale()
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != isPressed else { return }
        isPressed = inside
        updatePressScale()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updatePressScale()
        if inside { onPlay?() }
    }

    /// 1.06 under the pointer, 0.95 while pressed, easing like the mockup.
    private func updatePressScale() {
        let target = CGFloat(isPressed ? VoicePrintGeometry.pressedScale : (isHovered ? VoicePrintGeometry.hoverScale : 1))
        let transform = CATransform3DMakeScale(target, target, 1)
        guard !CATransform3DEqualToTransform(printLayer.transform, transform) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !AccessibilityDisplayPolicy.reduceMotion {
            let ease = CABasicAnimation(keyPath: "transform")
            ease.fromValue = printLayer.presentation()?.transform ?? printLayer.transform
            ease.toValue = transform
            ease.duration = VoicePrintGeometry.hoverDuration
            ease.timingFunction = VoicePrintCascadePlan.Curve.ease.mediaTimingFunction
            printLayer.add(ease, forKey: Self.pressKey)
        }
        printLayer.transform = transform
        CATransaction.commit()
    }

    // MARK: - Keyboard

    /// Tab can focus the print, then Space or Return plays. A click doesn't
    /// take the keyboard, so typing in a name box beside it carries on.
    override var acceptsFirstResponder: Bool {
        guard isPlayable else { return false }
        guard let type = NSApp?.currentEvent?.type else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        // Space, Return, keypad Enter.
        if plain, [49, 36, 76].contains(event.keyCode) {
            if !event.isARepeat { onPlay?() }
            return
        }
        super.keyDown(with: event)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { isPlayable }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        VoicePrintCopy.accessibilityLabel(name: accessibilityName, isPlaying: isPlaying)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPlay else { return false }
        onPlay()
        return true
    }
}

extension VoicePrintRGBA {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

extension VoicePrintCascadePlan.Curve {
    var mediaTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(c1x), Float(c1y), Float(c2x), Float(c2y))
    }
}
