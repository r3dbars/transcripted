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

// MARK: - Wings

final class NotchIslandWingView: NSView {
    enum Side {
        case leading
        case trailing
    }

    static let itemGap: CGFloat = 6
    static let outerPadding: CGFloat = 14
    static let innerPadding: CGFloat = 10

    let side: Side
    var centersContent = false {
        didSet { if centersContent != oldValue { needsLayout = true } }
    }
    var onAction: ((NotchIslandAction) -> Void)?

    private var itemViews: [NSView] = []
    private var itemWidths: [CGFloat] = []
    private var liveLabels: [(NotchIslandLiveValue, NSTextField)] = []
    private var barViews: [NotchIslandBarsView] = []
    private var meterViews: [NotchIslandMeetingLevelsView] = []
    private var rings: [(NotchIslandItem, NotchIslandRingView)] = []
    private var items: [NotchIslandItem] = []

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Width of the items alone, without the wing's padding.
    var contentWidth: CGFloat {
        guard !itemWidths.isEmpty else { return 0 }
        return itemWidths.reduce(0, +) + CGFloat(itemWidths.count - 1) * Self.itemGap
    }

    func setItems(_ newItems: [NotchIslandItem], live: NotchIslandLiveValues) {
        guard newItems != items else {
            updateLive(live)
            return
        }
        items = newItems
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = []
        itemWidths = []
        liveLabels = []
        barViews = []
        meterViews = []
        rings = []
        for item in newItems {
            let view = makeView(for: item, live: live)
            itemViews.append(view)
            addSubview(view)
        }
        updateLive(live)
        measure()
        if !NotchIslandPalette.reduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            layer?.add(fade, forKey: "contents")
        }
        needsLayout = true
    }

    func updateLive(_ live: NotchIslandLiveValues) {
        var widthChanged = false
        for (value, label) in liveLabels {
            let text = Self.liveText(value, live: live)
            if label.stringValue != text {
                let before = Self.templateText(value, current: label.stringValue)
                label.stringValue = text
                if Self.templateText(value, current: text) != before { widthChanged = true }
            }
        }
        for (item, ring) in rings {
            ring.setProgress(item == .transcriptionRing ? live.transcriptionProgress : live.loadingProgress)
        }
        if widthChanged {
            measure()
            needsLayout = true
        }
    }

    func receiveDictationLevel(_ reading: DictationAudioLevel, at time: TimeInterval) {
        barViews.forEach { $0.receive(reading, at: time) }
    }

    func advanceDictationBars(to time: TimeInterval, frameDuration: TimeInterval) {
        barViews.forEach { $0.advance(to: time, frameDuration: frameDuration) }
    }

    func updateMeters(mic: Float, system: Float) {
        meterViews.forEach { $0.update(mic: mic, system: system) }
    }

    override func layout() {
        super.layout()
        let total = contentWidth
        var x: CGFloat
        if centersContent {
            x = ((bounds.width - total) / 2).rounded()
        } else {
            switch side {
            case .leading: x = Self.outerPadding
            case .trailing: x = bounds.width - Self.outerPadding - total
            }
        }
        for (view, width) in zip(itemViews, itemWidths) {
            let height = min(bounds.height, Self.naturalHeight(of: view))
            view.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            x += width + Self.itemGap
        }
    }

    // MARK: Items

    /// A label's cell draws its text a couple of points in from each edge,
    /// so a frame sized to the bare text clips the last letter ("Cal").
    static let labelInset: CGFloat = 5

    private func measure() {
        itemWidths = itemViews.map { view in
            if let label = view as? NSTextField {
                if let live = liveLabels.first(where: { $0.1 === label })?.0 {
                    let template = Self.templateText(live, current: label.stringValue)
                    let font = label.font ?? NotchIslandPalette.liveFont
                    return ceil((template as NSString).size(withAttributes: [.font: font]).width) + Self.labelInset
                }
                return ceil(label.fittingSize.width)
            }
            if let image = (view as? NSImageView)?.image {
                return ceil(image.size.width)
            }
            let size = view.intrinsicContentSize
            if size.width > 0, size.width != NSView.noIntrinsicMetric { return ceil(size.width) }
            return ceil(view.fittingSize.width)
        }
    }

    /// Symbols report a trimmed alignment rect; lay them out at full image
    /// size so nothing is cut off above or below.
    private static func naturalHeight(of view: NSView) -> CGFloat {
        if let image = (view as? NSImageView)?.image { return ceil(image.size.height) }
        if view is NSTextField { return ceil(view.fittingSize.height) }
        let height = view.intrinsicContentSize.height
        return height > 0 ? height : max(view.fittingSize.height, 5)
    }

    private func makeView(for item: NotchIslandItem, live: NotchIslandLiveValues) -> NSView {
        switch item {
        case .symbol(let symbol, let tint):
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            let image = NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            let view = NSImageView(image: image ?? NSImage())
            view.contentTintColor = NotchIslandPalette.color(for: tint)
            view.imageScaling = .scaleNone
            return view
        case .text(let text, let style):
            return NotchIslandPalette.label(text, font: NotchIslandPalette.font(for: style), color: NotchIslandPalette.color(for: style))
        case .live(let value, let style):
            let label = NotchIslandPalette.label(Self.liveText(value, live: live), font: NotchIslandPalette.liveFont, color: NotchIslandPalette.color(for: style))
            label.alignment = side == .trailing ? .right : .left
            liveLabels.append((value, label))
            return label
        case .dictationBars(let count):
            let bars = NotchIslandBarsView(count: count, color: NotchIslandPalette.accent, clocked: true)
            barViews.append(bars)
            return bars
        case .meetingMeters:
            let meters = NotchIslandMeetingLevelsView(frame: .zero)
            meterViews.append(meters)
            return meters
        case .dots:
            return NotchIslandDotsView(frame: .zero)
        case .shimmer:
            return NotchIslandShimmerView(frame: .zero)
        case .spinner:
            return NotchIslandRingView(indeterminate: true)
        case .transcriptionRing, .loadingRing:
            let ring = NotchIslandRingView(indeterminate: false)
            rings.append((item, ring))
            return ring
        case .recordingDot:
            return NotchIslandDotView(size: 7, color: NotchIslandPalette.recording, glow: false)
        case .accentDot:
            return NotchIslandDotView(size: 8, color: NotchIslandPalette.accent, glow: true)
        case .chip(let title, let style, let action):
            let buttonStyle: NotchIslandButton.Style
            switch style {
            case .plain: buttonStyle = .subtle
            case .accent: buttonStyle = .accent
            case .destructive: buttonStyle = .destructive
            case .warning: buttonStyle = .warning
            }
            let button = NotchIslandButton(title: title, style: buttonStyle, height: 22, fontSize: 11)
            button.onPress = { [weak self] in self?.onAction?(action) }
            return button
        }
    }

    static func liveText(_ value: NotchIslandLiveValue, live: NotchIslandLiveValues) -> String {
        switch value {
        case .dictationTimer: return NotchIslandPresentation.timerText(live.dictationElapsed)
        case .meetingTimer: return NotchIslandPresentation.timerText(live.meetingElapsed)
        case .loadingPercent: return "\(Int((live.loadingProgress * 100).rounded()))%"
        case .callSeconds: return "\(max(1, live.callSecondsLeft))s"
        }
    }

    /// The widest text a live value can show at its current digit count, so
    /// the wing does not twitch every second.
    static func templateText(_ value: NotchIslandLiveValue, current: String) -> String {
        switch value {
        case .loadingPercent: return "100%"
        case .callSeconds: return "00s"
        case .dictationTimer, .meetingTimer:
            return String(current.map { $0.isNumber ? "0" : $0 })
        }
    }
}

// MARK: - Drop-down

final class NotchIslandDropView: NSView {
    static let contentWidth = NotchIslandGeometry.dropWidth - 40

    var onAction: ((NotchIslandAction) -> Void)?
    private(set) var drop: NotchIslandDrop
    let stack = NSStackView()
    private var youLane: NotchIslandBarsView?
    private var callLane: NotchIslandBarsView?
    private var promptCountdownLabel: NSTextField?
    private var countdownButton: NotchIslandButton?
    /// A dictation message's words and hint. A click on them is someone
    /// reading, so it never reaches the island's click-to-dismiss.
    var readableText: [NSView] = []

    func setCountdownPaused(_ paused: Bool) {
        countdownButton?.setCountdownPaused(paused)
    }

    /// The island's "Who was on this call?" view, kept alive by the
    /// controller so typing and playback survive the drop-down being rebuilt.
    private let speakerReviewView: NSView?
    /// The live transcript, kept alive by the controller like the review.
    private let liveTranscriptView: NotchIslandLiveTranscriptView?
    /// The dictation's live words, kept alive by the controller the same way.
    let dictationPreviewView: NotchIslandDictationPreviewView?

    init(
        drop: NotchIslandDrop,
        live: NotchIslandLiveValues,
        targetIcon: () -> NSImage?,
        speakerReviewView: NSView? = nil,
        liveTranscriptView: NotchIslandLiveTranscriptView? = nil,
        dictationPreviewView: NotchIslandDictationPreviewView? = nil
    ) {
        self.drop = drop
        self.speakerReviewView = speakerReviewView
        self.liveTranscriptView = liveTranscriptView
        self.dictationPreviewView = dictationPreviewView
        super.init(frame: NSRect(x: 0, y: 0, width: NotchIslandGeometry.dropWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: NotchIslandGeometry.dropWidth),
        ])
        build(live: live, targetIcon: targetIcon)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat { ceil(stack.fittingSize.height) }

    /// Measured once per island render (`NotchIslandView.measureDropHeight`),
    /// so the island's layout passes don't each solve the stack again.
    private(set) var measuredHeight: CGFloat?

    func measureHeight() -> CGFloat {
        let height = fittingHeight
        measuredHeight = height
        return height
    }

    /// Nothing in the drop-down reads a live value today: the call prompt's
    /// countdown is the ring around Skip, which runs by itself.
    func updateLive(_ live: NotchIslandLiveValues) {}

    /// A meeting prompt that only changed its "Stops in 12s" line is updated
    /// in place, so its buttons are not rebuilt under the pointer each second.
    func adoptIfOnlyCountdownChanged(_ newDrop: NotchIslandDrop) -> Bool {
        guard case .meetingPrompt(let old) = drop,
              case .meetingPrompt(let new) = newDrop,
              let promptCountdownLabel,
              !new.countdown.isEmpty else { return false }
        var oldWithoutCountdown = old
        oldWithoutCountdown.countdown = new.countdown
        guard oldWithoutCountdown == new else { return false }
        promptCountdownLabel.stringValue = new.countdown
        drop = newDrop
        return true
    }

    func pushLevels(mic: Float, system: Float) {
        youLane?.push(mic)
        callLane?.push(system)
    }

    // MARK: Building

    private func build(live: NotchIslandLiveValues, targetIcon: () -> NSImage?) {
        switch drop {
        case .dictationTarget(let appName, let showsPreview, let isWriting):
            buildDictationTarget(appName: appName, icon: targetIcon, showsPreview: showsPreview, isWriting: isWriting)
        case .dictationLoading(let title, let detail):
            add(titleBlock(title, detail, wrapsDetail: true))
        case .dictationMessage(let message) where message.preview != nil:
            let quote = body("“\(message.preview ?? "")”", maxLines: 2)
            let hint = NotchIslandPalette.label(
                message.hint ?? "Click where it goes, then press ⌘V.",
                font: .systemFont(ofSize: 12),
                color: NotchIslandPalette.secondaryText
            )
            readableText = [quote, hint]
            add(quote)
            add(hint)
            let dismiss = NotchIslandButton(title: "Dismiss", style: .plain)
            dismiss.onPress = { [weak self] in self?.onAction?(.dictationDismissMessage) }
            dismiss.setContentHuggingPriority(.required, for: .horizontal)
            if let seconds = message.dismissSeconds {
                dismiss.startCountdown(seconds: seconds)
                countdownButton = dismiss
            }
            add(buttonRow(leading: [], trailing: [
                dismiss,
                button(message.actionTitle ?? "Paste", .accent, .dictationMessageAction),
            ]))
        case .dictationMessage(let message):
            let text = body(message.text)
            readableText = [text]
            add(text)
            var trailing = [button("Dismiss", .plain, .dictationDismissMessage)]
            if let actionTitle = message.actionTitle {
                trailing.append(button(actionTitle, .accent, .dictationMessageAction))
            }
            add(buttonRow(leading: [], trailing: trailing))
        case .justInserted(let text, _):
            buildJustInserted(text: text)
        case .meetingPreparing(let title, let detail):
            add(titleBlock(title, detail, wrapsDetail: true))
        case .meetingControls(let note, let unverified, let showsTranscript):
            let subtitle: String
            if unverified {
                subtitle = "Can't confirm call audio yet"
            } else {
                switch note {
                case .off?: subtitle = "Call audio is off"
                case .onForNextMeeting?: subtitle = "Call audio starts next meeting"
                case nil: subtitle = "You and the call"
                }
            }
            add(titleBlock("Recording", subtitle))
            if showsTranscript, let liveTranscriptView {
                liveTranscriptView.removeFromSuperview()
                stack.addArrangedSubview(liveTranscriptView) // not add(): it pins its own size
                readableText.append(liveTranscriptView)
                DispatchQueue.main.async { [weak liveTranscriptView] in liveTranscriptView?.scrollToNewest() }
                var leading = [copyTranscriptButton()]
                if note == .off {
                    leading.append(button("Turn on call audio", .warning, .meetingCallAudio))
                }
                add(buttonRow(leading: leading, trailing: [
                    button("Stop", .destructive, .meetingStop, symbol: "stop.fill"),
                ]))
                break
            }
            let you = NotchIslandBarsView(count: 46, maxHeight: 20, color: NotchIslandPalette.accent)
            let call = NotchIslandBarsView(count: 46, maxHeight: 20, color: NSColor(white: 1, alpha: 0.8))
            youLane = you
            callLane = call
            add(lane("You", you))
            add(lane("Call", call))
            var leading: [NSView] = []
            if note == .off {
                leading.append(button("Turn on", .warning, .meetingCallAudio))
            }
            add(buttonRow(leading: leading, trailing: [
                button("Stop", .destructive, .meetingStop, symbol: "stop.fill"),
            ]))
        case .meetingPrompt(let prompt):
            add(titleBlock(prompt.title, prompt.detail, wrapsDetail: true))
            if !prompt.countdown.isEmpty {
                let countdown = NotchIslandPalette.label(
                    prompt.countdown,
                    font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    color: NotchIslandPalette.secondaryText
                )
                promptCountdownLabel = countdown
                add(countdown)
            }
            var leading: [NSView] = []
            if let tertiary = prompt.tertiaryTitle, !tertiary.isEmpty {
                leading.append(button(tertiary, .subtle, .meetingTertiary))
            }
            var trailing: [NSView] = []
            if !prompt.secondaryTitle.isEmpty {
                trailing.append(button(prompt.secondaryTitle, .plain, .meetingSecondary))
            }
            if !prompt.primaryTitle.isEmpty {
                let style: NotchIslandButton.Style = prompt.primaryTitle == "Stop" ? .destructive : .accent
                trailing.append(button(prompt.primaryTitle, style, .meetingPrimary))
            }
            add(buttonRow(leading: leading, trailing: trailing))
        case .meetingSaved(let title):
            add(titleBlock(title ?? "Meeting saved", "Saved to Meetings"))
            add(buttonRow(leading: [], trailing: [button("Open", .accent, .meetingOpen)]))
        case .meetingError(let title, let message, let canOpen, let grantsSystemAudio):
            add(titleBlock(title, message, wrapsDetail: true))
            var trailing = [button("OK", .plain, .meetingDismissError)]
            if grantsSystemAudio {
                // The meeting overlay's primary action opens the audio-only
                // Settings pane while the start's denial is on screen.
                trailing.append(button("Open Settings", .accent, .meetingPrimary))
            } else if canOpen {
                trailing.append(button("Open", .accent, .meetingOpen))
            }
            add(buttonRow(leading: [], trailing: trailing))
        case .callPrompt(let title, let detail):
            add(titleBlock(title, detail))
            // The countdown is a ring around Skip, like the dictation
            // Dismiss ring; it pauses while the pointer is over the island.
            let notNow = NotchIslandButton(title: "Skip", style: .plain)
            notNow.onPress = { [weak self] in self?.onAction?(.callDismiss) }
            notNow.setContentHuggingPriority(.required, for: .horizontal)
            notNow.startCountdown(seconds: Double(max(1, live.callSecondsLeft)))
            countdownButton = notNow
            add(buttonRow(leading: [], trailing: [
                notNow,
                button("Remind me", .plain, .callRemind),
                button("Record", .destructive, .callRecord, symbol: "record.circle.fill"),
            ]))
        case .meetingCallAudioAsk:
            add(titleBlock(
                "Call audio is off",
                "Turn it on to record the other people. Starts next meeting.",
                wrapsDetail: true
            ))
            add(buttonRow(leading: [], trailing: [
                button("Skip", .plain, .meetingCallAudioDismiss),
                button("Turn on", .accent, .meetingCallAudio),
            ]))
        case .speakerReview:
            if let speakerReviewView {
                speakerReviewView.removeFromSuperview()
                stack.addArrangedSubview(speakerReviewView)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A control-click still reaches the island for its menu.
        if !event.modifierFlags.contains(.control),
           readableText.contains(where: { $0.convert($0.bounds, to: self).contains(point) }) {
            return
        }
        super.mouseDown(with: event)
    }

    func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    func buttonRow(leading: [NSView], trailing: [NSView]) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: leading + [spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func titleBlock(_ title: String, _ detail: String, wrapsDetail: Bool = false) -> NSView {
        let titleLabel = NotchIslandPalette.label(title, font: .systemFont(ofSize: 15, weight: .bold), color: NotchIslandPalette.primaryText)
        titleLabel.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [titleLabel]
        if !detail.isEmpty {
            let detailLabel = NotchIslandPalette.label(
                detail,
                font: .systemFont(ofSize: 12),
                color: NotchIslandPalette.secondaryText,
                wraps: wrapsDetail,
                width: Self.contentWidth - 48
            )
            if !wrapsDetail { detailLabel.lineBreakMode = .byTruncatingTail }
            views.append(detailLabel)
        }
        let block = NSStackView(views: views)
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 2
        return block
    }

    func body(_ text: String, maxLines: Int = 0) -> NSTextField {
        let label = NotchIslandPalette.label(
            text,
            font: .systemFont(ofSize: 13),
            color: NotchIslandPalette.bodyText,
            wraps: true,
            width: Self.contentWidth
        )
        label.maximumNumberOfLines = maxLines
        // Wrap, and put the ellipsis on the last line that fits.
        label.cell?.truncatesLastVisibleLine = maxLines > 0
        return label
    }

    private func lane(_ name: String, _ bars: NotchIslandBarsView) -> NSView {
        let label = NotchIslandPalette.label(name, font: .systemFont(ofSize: 11, weight: .semibold), color: NotchIslandPalette.secondaryText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return row([label, bars])
    }

    /// Copy all, which says "Copied" for a beat.
    private func copyTranscriptButton() -> NSView {
        let button = NotchIslandButton(title: "Copy all", style: .plain, symbolName: "doc.on.doc")
        button.onPress = { [weak self, weak button] in
            self?.onAction?(.meetingCopyTranscript)
            button?.replaceTitle("Copied")
            Task { @MainActor [weak button] in
                try? await Task.sleep(for: .seconds(1.4))
                button?.replaceTitle("Copy all")
            }
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func button(_ title: String, _ style: NotchIslandButton.Style, _ action: NotchIslandAction, symbol: String? = nil, appIcon: NSImage? = nil) -> NSView {
        let button = NotchIslandButton(title: title, style: style, symbolName: symbol, appIcon: appIcon)
        button.onPress = { [weak self] in self?.onAction?(action) }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

// MARK: - The island

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
