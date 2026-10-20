// NotchIslandView.swift
// Draws the notch island: a black shape attached to the top edge, two wings
// either side of the camera, an optional drop-down below them, and a thin
// progress edge. Pure AppKit (no SwiftUI hosting, like the other overlays).
// It only draws what NotchIslandPresentation decided; NotchIslandController
// sizes the panel and routes taps.

import AppKit
import CoreImage

/// Numbers that change every second without changing the layout.
struct NotchIslandLiveValues: Equatable {
    var dictationElapsed: TimeInterval = 0
    var meetingElapsed: TimeInterval = 0
    var loadingProgress: Double = 0
    var transcriptionProgress: Double = 0
    var callSecondsLeft: Int = 0
}

// MARK: - Palette

enum NotchIslandPalette {
    static let background = NSColor.black
    static let primaryText = NSColor.white
    static let secondaryText = NSColor(white: 1, alpha: 0.64)
    static let bodyText = NSColor(white: 1, alpha: 0.9)
    static let warning = NSColor.systemOrange
    static let recording = NSColor.systemRed
    static let buttonPlain = NSColor(white: 0.17, alpha: 1)
    static let buttonSubtle = NSColor(white: 0.11, alpha: 1)
    static let destructive = NSColor(srgbRed: 0.851, green: 0.176, blue: 0.125, alpha: 1)
    static var accent: NSColor { NSColor.controlAccentColor }

    static func color(for tint: NotchIslandTint) -> NSColor {
        switch tint {
        case .accent: return accent
        case .primary: return primaryText
        case .secondary: return secondaryText
        case .warning: return warning
        }
    }

    static func color(for style: NotchIslandTextStyle) -> NSColor {
        switch style {
        case .title: return primaryText
        case .secondary: return secondaryText
        case .warning: return warning
        }
    }

    static func font(for style: NotchIslandTextStyle) -> NSFont {
        switch style {
        case .title, .warning: return .systemFont(ofSize: 12, weight: .semibold)
        case .secondary: return .systemFont(ofSize: 12, weight: .medium)
        }
    }

    nonisolated(unsafe) static let liveFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold) // immutable, never mutated

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor static func label(_ text: String, font: NSFont, color: NSColor, wraps: Bool = false, width: CGFloat = 0) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
        if wraps {
            field.preferredMaxLayoutWidth = width
            field.lineBreakMode = .byWordWrapping
        } else {
            field.lineBreakMode = .byClipping
            field.maximumNumberOfLines = 1
        }
        return field
    }
}

// MARK: - Small drawings

/// A round progress ring, or a spinning arc when there is no number yet.
final class NotchIslandRingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let indeterminate: Bool

    init(indeterminate: Bool) {
        self.indeterminate = indeterminate
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = 2.5
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor(white: 1, alpha: 0.25).cgColor
        arc.strokeColor = NotchIslandPalette.accent.cgColor
        arc.strokeEnd = indeterminate ? 0.28 : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func layout() {
        super.layout()
        let path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        track.frame = bounds
        arc.frame = bounds
        track.path = path
        arc.path = path
        if indeterminate, arc.animation(forKey: "spin") == nil, !NotchIslandPalette.reduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            arc.add(spin, forKey: "spin")
        }
    }

    func setProgress(_ progress: Double) {
        guard !indeterminate else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = CGFloat(min(1, max(0, progress)))
        CATransaction.commit()
    }
}

/// A plain dot; `pulsing` breathes gently.
final class NotchIslandDotView: NSView {
    private let size: CGFloat
    private let glow: Bool

    init(size: CGFloat, color: NSColor, glow: Bool) {
        self.size = size
        self.glow = glow
        super.init(frame: NSRect(x: 0, y: 0, width: glow ? size * 2 : size, height: glow ? size * 2 : size))
        wantsLayer = true
        let dot = CALayer()
        dot.backgroundColor = color.cgColor
        dot.cornerRadius = size / 2
        let outer = glow ? size * 2 : size
        dot.frame = CGRect(x: (outer - size) / 2, y: (outer - size) / 2, width: size, height: size)
        if glow {
            let ring = CALayer()
            ring.backgroundColor = color.withAlphaComponent(0.3).cgColor
            ring.cornerRadius = outer / 2
            ring.frame = CGRect(x: 0, y: 0, width: outer, height: outer)
            layer?.addSublayer(ring)
        }
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        glow ? NSSize(width: size * 2, height: size * 2) : NSSize(width: size, height: size)
    }
}

/// Three dots that ripple while the words are written.
final class NotchIslandDotsView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 21, height: 5))
        wantsLayer = true
        for index in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = NotchIslandPalette.accent.cgColor
            dot.cornerRadius = 2.5
            dot.frame = CGRect(x: CGFloat(index) * 8, y: 0, width: 5, height: 5)
            if !NotchIslandPalette.reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0.3
                fade.duration = 0.5
                fade.autoreverses = true
                fade.repeatCount = .infinity
                fade.beginTime = CACurrentMediaTime() + Double(index) * 0.15
                dot.add(fade, forKey: "ripple")
            }
            layer?.addSublayer(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 21, height: 5) }
}

/// A short light sweep where the text is being written.
final class NotchIslandShimmerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 46, height: 5))
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: 46, height: 5)
        gradient.cornerRadius = 2.5
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let dim = NSColor(white: 1, alpha: 0.18).cgColor
        let bright = NSColor(white: 1, alpha: 0.55).cgColor
        gradient.colors = [dim, bright, dim]
        gradient.locations = [0, 0.5, 1]
        if !NotchIslandPalette.reduceMotion {
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-1, -0.5, 0]
            sweep.toValue = [1, 1.5, 2]
            sweep.duration = 1
            sweep.repeatCount = .infinity
            gradient.add(sweep, forKey: "sweep")
        }
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 5) }
}

// MARK: - The island
// The wings live in NotchIslandWingView.swift and the drop-down in
// NotchIslandDropView.swift.

/// Flipped holder for everything drawn on the island. It is black and masked
/// to the island shape, so growing the mask is what grows the island.
final class NotchIslandContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NotchIslandView: NSView {
    var onAction: ((NotchIslandAction) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// The target app's icon for "Insert into <app>", asked for only when a
    /// drop-down shows it (drawn once per take by the controller's cache).
    var targetAppIconProvider: (() -> NSImage?)?

    private let contentView = NotchIslandContentView(frame: .zero)
    /// A live rounded rectangle with Apple's continuous corners: springing
    /// its bounds and corner radius keeps the corners true at every frame.
    private let maskLayer = CALayer()
    /// A 1-point view at the content's top-left. Where AppKit puts its layer
    /// tells which way the mask's y axis runs in this view hierarchy.
    private let orientationProbe = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    /// Clear layer holding the wings, edge and drop-down, so they can blur
    /// in and out without softening the island's own edge.
    private let itemsView = NotchIslandContentView(frame: .zero)
    private let leftWing = NotchIslandWingView(side: .leading)
    private let rightWing = NotchIslandWingView(side: .trailing)
    private var dropView: NotchIslandDropView?
    /// The dictation hover's drop-down, kept built between hovers while the
    /// take is spoken (`NotchIslandDrop.staysBuiltBetweenHovers`), so the
    /// next hover puts it back instead of building it again.
    private var keptDictationDrop: NotchIslandDropView?
    /// Set by the controller while a speaker review is up.
    var speakerReviewView: NSView?
    /// Set by the controller while a meeting with live transcript records.
    var liveTranscriptView: NotchIslandLiveTranscriptView?
    var dictationPreviewView: NotchIslandDictationPreviewView?
    private let edge = NSView()
    private var rowHeight: CGFloat = NotchIslandGeometry.tabRowHeight
    private var notchWidth: CGFloat?
    private var cornerRadius: CGFloat = NotchIslandGeometry.restingCornerRadius
    private var edgeProgress: Double?
    /// Where the finished island sits in this view (flipped coordinates).
    private(set) var islandRect: CGRect = .zero
    /// The shape the mask is heading to, and its corner radius.
    private var shapeRect: CGRect = .zero
    private var shapeRadius: CGFloat = 0
    private var morphGeneration = 0
    private var cachedLayerIsYDown: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NotchIslandPalette.background.cgColor
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.cornerCurve = .continuous
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentView.layer?.mask = maskLayer
        addSubview(contentView)
        orientationProbe.wantsLayer = true
        orientationProbe.alphaValue = 0
        contentView.addSubview(orientationProbe)
        itemsView.frame = contentView.bounds
        itemsView.autoresizingMask = [.width, .height]
        itemsView.wantsLayer = true
        contentView.addSubview(itemsView)
        itemsView.addSubview(leftWing)
        itemsView.addSubview(rightWing)
        edge.wantsLayer = true
        edge.layer?.backgroundColor = NotchIslandPalette.accent.cgColor
        edge.layer?.cornerRadius = 1
        itemsView.addSubview(edge)
        for wing in [leftWing, rightWing] {
            wing.onAction = { [weak self] action in self?.onAction?(action) }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Transcripted")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Content widths of the two wings, without padding, for the geometry.
    var wingContentWidths: (left: CGFloat, right: CGFloat) {
        (leftWing.contentWidth, rightWing.contentWidth)
    }

    /// The drop-down's height, measured once per render.
    func measureDropHeight() -> CGFloat? { dropView?.measureHeight() }

    var currentCornerRadius: CGFloat { cornerRadius }

    /// Corner radius of the shape the mask is heading to.
    var shapeCornerRadius: CGFloat { shapeRadius }

    func apply(_ layout: NotchIslandLayout, live: NotchIslandLiveValues) {
        leftWing.setItems(layout.left, live: live)
        rightWing.setItems(layout.right, live: live)
        if layout.drop != dropView?.drop,
           !(layout.drop.map { dropView?.adoptIfOnlyCountdownChanged($0) ?? false } ?? false) {
            let hadDrop = dropView != nil
            if let outgoing = dropView {
                outgoing.removeFromSuperview()
                if outgoing.drop.staysBuiltBetweenHovers { keptDictationDrop = outgoing }
            }
            dropView = nil
            if let drop = layout.drop {
                let view = takeKeptDictationDrop(for: drop) ?? NotchIslandDropView(
                    drop: drop,
                    live: live,
                    targetIcon: { targetAppIconProvider?() },
                    speakerReviewView: speakerReviewView,
                    liveTranscriptView: liveTranscriptView,
                    dictationPreviewView: dictationPreviewView
                )
                view.onAction = { [weak self] action in self?.onAction?(action) }
                itemsView.addSubview(view)
                dropView = view
                if !hadDrop {
                    Self.blur(view, from: NotchIslandMotion.blurRadius, to: 0, duration: NotchIslandMotion.blurInDuration)
                }
                if !hadDrop, !NotchIslandPalette.reduceMotion {
                    // The growing shape uncovers it; the fade only softens it.
                    view.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.16
                        view.animator().alphaValue = 1
                    }
                }
            }
        }
        setAccessibilityValue(Self.accessibilitySummary(layout))
        needsLayout = true
    }

    /// The kept dictation drop-down, ready to show again in the state a new
    /// one starts in, or nil when it doesn't fit this drop.
    private func takeKeptDictationDrop(for drop: NotchIslandDrop) -> NotchIslandDropView? {
        guard let kept = keptDictationDrop, drop.staysBuiltBetweenHovers else { return nil }
        keptDictationDrop = nil
        guard kept.drop == drop, kept.canComeBack else { return nil }
        kept.layer?.removeAnimation(forKey: "islandBlur")
        kept.contentFilters = []
        kept.alphaValue = 1
        kept.cameBack()
        return kept
    }

    /// The take is over: its kept drop-down goes.
    func releaseKeptDictationDrop() {
        keptDictationDrop = nil
    }

    /// Holds the Dismiss ring while the pointer rests on the island.
    func setCountdownPaused(_ paused: Bool) {
        dropView?.setCountdownPaused(paused)
    }

    func updateLive(_ live: NotchIslandLiveValues) {
        leftWing.updateLive(live)
        rightWing.updateLive(live)
        dropView?.updateLive(live)
    }

    func setGeometry(screen: NotchIslandScreenInfo, hasDrop: Bool, edgeProgress: Double?) {
        rowHeight = screen.rowHeight
        notchWidth = screen.notchWidth
        cornerRadius = NotchIslandGeometry.cornerRadius(hasDrop: hasDrop, rowHeight: screen.rowHeight)
        self.edgeProgress = edgeProgress
        let single = notchWidth == nil && (leftWing.contentWidth == 0) != (rightWing.contentWidth == 0)
        leftWing.centersContent = single
        rightWing.centersContent = single
        needsLayout = true
    }

    /// Content fades in with the grow and out before the shrink.
    func setContentVisible(_ visible: Bool, animated: Bool) {
        let views: [NSView] = [leftWing, rightWing, edge] + (dropView.map { [$0] } ?? [])
        let alpha: CGFloat = visible ? 1 : 0
        guard animated, !NotchIslandPalette.reduceMotion else {
            views.forEach { $0.alphaValue = alpha }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? NotchIslandMotion.contentFadeIn : NotchIslandMotion.contentFadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            views.forEach { $0.animator().alphaValue = alpha }
        }
    }

    /// Softens the content while the shape uncovers it, so a half-shown
    /// word never looks cut off, and sharpens it by the time the shape is
    /// full size. Hiding does the reverse while the content fades.
    func blurContent(in blurIn: Bool) {
        if blurIn {
            Self.blur(itemsView, from: NotchIslandMotion.blurRadius, to: 0, duration: NotchIslandMotion.blurInDuration)
        } else {
            Self.blur(itemsView, from: 0, to: NotchIslandMotion.blurRadius, duration: NotchIslandMotion.contentFadeOut)
        }
    }
    func prewarmBlur() { Self.prewarmBlur(on: itemsView) } // NotchIslandView+Blur.swift
    /// Drops any blur left from the last hide.
    func resetBlur() {
        itemsView.layer?.removeAnimation(forKey: "islandBlur")
        itemsView.contentFilters = []
    }

    private static func blur(_ view: NSView, from start: CGFloat, to end: CGFloat, duration: Double) {
        guard !NotchIslandPalette.reduceMotion,
              let filter = CIFilter(name: "CIGaussianBlur") else { return }
        view.layerUsesCoreImageFilters = true
        filter.name = "islandBlur"
        filter.setValue(end, forKey: kCIInputRadiusKey)
        view.contentFilters = [filter]
        guard let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "filters.islandBlur.inputRadius")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in
            // A sharp view carries no filter, so it costs nothing at rest.
            Task { @MainActor [weak view] in
                guard let view, end == 0, view.layer?.animation(forKey: "islandBlur") == nil else { return }
                view.contentFilters = []
            }
        }
        layer.add(animation, forKey: "islandBlur")
        CATransaction.commit()
    }

    /// A dictation meter reading for the waveform's next step.
    func receiveDictationLevel(_ reading: DictationAudioLevel, at time: TimeInterval) {
        leftWing.receiveDictationLevel(reading, at: time)
        rightWing.receiveDictationLevel(reading, at: time)
    }

    /// One display frame for the dictation waveform (NotchIslandController's
    /// display link, while a dictation listens).
    func advanceDictationBars(to time: TimeInterval, frameDuration: TimeInterval) {
        leftWing.advanceDictationBars(to: time, frameDuration: frameDuration)
        rightWing.advanceDictationBars(to: time, frameDuration: frameDuration)
    }

    func pushMeetingLevels(mic: Float, system: Float) {
        leftWing.updateMeters(mic: mic, system: system)
        rightWing.updateMeters(mic: mic, system: system)
        dropView?.pushLevels(mic: mic, system: system)
    }

    // MARK: Shape

    /// Places the finished island in this view; the content is laid out
    /// there at once and the mask uncovers it.
    func setIslandRect(_ rect: CGRect) {
        islandRect = rect
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Where the wings' content hangs from, in this view: the leading
    /// wing's left edge, the trailing wing's right edge (their items are
    /// aligned to those), or the middle of a lone centered wing.
    func contentAnchors() -> [CGFloat] {
        [leftWing, rightWing].map { wing in
            if wing.centersContent { return wing.frame.midX }
            return wing.side == .leading ? wing.frame.minX : wing.frame.maxX
        }
    }

    /// When the island resizes, the wings ride the same spring as the shape
    /// instead of jumping to where the finished island will have them (and
    /// being cut off until the shape catches up). `previous` are the anchors
    /// from before the resize, in this view's current coordinates.
    func slideContent(from previous: [CGFloat], spring: NotchIslandMotion.Spring) {
        guard !NotchIslandPalette.reduceMotion else { return }
        let current = contentAnchors()
        for (wing, (old, new)) in zip([leftWing, rightWing], zip(previous, current)) {
            let delta = old - new
            guard abs(delta) > 0.5, wing.contentWidth > 0, let layer = wing.layer else { continue }
            let slide = CASpringAnimation(keyPath: "position.x")
            slide.isAdditive = true
            slide.fromValue = delta
            slide.toValue = 0
            slide.mass = 1
            slide.stiffness = spring.stiffness
            slide.damping = spring.damping
            slide.duration = slide.settlingDuration
            layer.add(slide, forKey: "islandSlide")
        }
    }

    /// Where the shape is on screen right now, mid-animation included, in
    /// this view's (flipped) coordinates.
    var presentedShapeRect: CGRect {
        flipped((maskLayer.presentation() ?? maskLayer).frame)
    }

    /// Moves the shape from one rect to another with a spring (or at once).
    /// Rects are in this view's flipped coordinates.
    func morph(
        from start: CGRect,
        fromRadius: CGFloat,
        to end: CGRect,
        radius: CGFloat,
        spring: NotchIslandMotion.Spring?,
        completion: (() -> Void)? = nil
    ) {
        morphGeneration += 1
        let generation = morphGeneration
        shapeRect = end
        shapeRadius = radius
        let yDown = layerIsYDown
        let endFrame = layerRect(end)
        let startFrame = layerRect(start)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.removeAllAnimations()
        // Only the bottom corners are round; the top meets the screen edge.
        maskLayer.maskedCorners = yDown
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        maskLayer.bounds = CGRect(origin: .zero, size: endFrame.size)
        maskLayer.position = CGPoint(x: endFrame.midX, y: endFrame.midY)
        maskLayer.cornerRadius = min(radius, endFrame.height, endFrame.width / 2)
        CATransaction.commit()
        guard let spring, !NotchIslandPalette.reduceMotion, start != end || fromRadius != radius else {
            completion?()
            return
        }
        func springAnimation(_ keyPath: String, from value: Any) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.fromValue = value
            animation.mass = 1
            animation.stiffness = spring.stiffness
            animation.damping = spring.damping
            animation.duration = animation.settlingDuration
            return animation
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.morphGeneration == generation else { return }
                completion?()
            }
        }
        maskLayer.add(springAnimation("bounds", from: NSValue(rect: CGRect(origin: .zero, size: startFrame.size))), forKey: "morphBounds")
        maskLayer.add(springAnimation("position", from: NSValue(point: CGPoint(x: startFrame.midX, y: startFrame.midY))), forKey: "morphPosition")
        maskLayer.add(springAnimation("cornerRadius", from: min(fromRadius, startFrame.height, startFrame.width / 2)), forKey: "morphRadius")
        CATransaction.commit()
    }

    /// True when the content layer's y axis runs down, like the view's. It
    /// can't change while the view stays in its window, so it's read there
    /// once instead of forcing a layout pass on every morph.
    private var layerIsYDown: Bool {
        if let cachedLayerIsYDown { return cachedLayerIsYDown }
        contentView.layoutSubtreeIfNeeded()
        let yDown = (orientationProbe.layer?.frame.minY ?? 0) < 0.5
        if window != nil { cachedLayerIsYDown = yDown }
        return yDown
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cachedLayerIsYDown = nil
    }

    /// A rect in this view's (flipped) coordinates, in the mask's.
    private func layerRect(_ rect: CGRect) -> CGRect {
        if layerIsYDown { return rect }
        return CGRect(x: rect.minX, y: contentView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func flipped(_ layerRect: CGRect) -> CGRect {
        if layerIsYDown { return layerRect }
        return CGRect(x: layerRect.minX, y: contentView.bounds.height - layerRect.maxY, width: layerRect.width, height: layerRect.height)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let island = islandRect
        let width = island.width
        let x0 = island.minX
        let y0 = island.minY
        if let notchWidth {
            let wing = max(0, ((width - notchWidth) / 2).rounded(.down))
            leftWing.frame = NSRect(x: x0, y: y0, width: wing, height: rowHeight)
            rightWing.frame = NSRect(x: x0 + width - wing, y: y0, width: wing, height: rowHeight)
        } else {
            let left = NotchIslandGeometry.wingWidth(content: leftWing.contentWidth)
            let right = NotchIslandGeometry.wingWidth(content: rightWing.contentWidth)
            if left > 0, right > 0 {
                leftWing.frame = NSRect(x: x0, y: y0, width: max(left, width - right), height: rowHeight)
                rightWing.frame = NSRect(x: x0 + width - right, y: y0, width: right, height: rowHeight)
            } else {
                leftWing.frame = NSRect(x: x0, y: y0, width: left > 0 ? width : 0, height: rowHeight)
                rightWing.frame = NSRect(x: x0, y: y0, width: right > 0 ? width : 0, height: rowHeight)
            }
        }
        if let dropView {
            let dropWidth = min(NotchIslandGeometry.dropWidth, width)
            dropView.frame = NSRect(
                x: (x0 + (width - dropWidth) / 2).rounded(),
                y: y0 + rowHeight + NotchIslandGeometry.dropTopGap,
                width: dropWidth,
                height: dropView.measuredHeight ?? dropView.measureHeight()
            )
        }
        if let edgeProgress {
            edge.isHidden = false
            edge.frame = NSRect(x: x0 + 18, y: y0 + rowHeight - 2, width: max(0, (width - 36) * CGFloat(edgeProgress)), height: 2)
        } else {
            edge.isHidden = true
        }
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the island itself takes clicks, not the room left around it
        // for the spring.
        let local = convert(point, from: superview)
        guard islandRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
            return
        }
        onBackgroundClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    static func accessibilitySummary(_ layout: NotchIslandLayout) -> String {
        let words = (layout.left + layout.right).compactMap { item -> String? in
            switch item {
            case .text(let text, _): return text
            case .chip(let title, _, _): return title
            default: return nil
            }
        }
        return words.joined(separator: ", ")
    }
}
