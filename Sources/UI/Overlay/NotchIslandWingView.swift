// NotchIslandWingView.swift
// One wing of the island, either side of the camera: lays out the items
// NotchIslandPresentation chose and keeps their live values current. Split
// out of NotchIslandView.swift.

import AppKit

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
