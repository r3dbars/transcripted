import AppKit
import QuartzCore

/// While the card waits for its first words: a slow aurora in the tone colors drifts behind three
/// skeleton lines that breathe in width with a shimmer. As text arrives each line melts away, and the
/// aurora fades once the message is there.
final class NextSentenceAurora: NextSentenceFlippedView {
    private var blobs: [CAGradientLayer] = []
    private var bars: [NSView] = []
    private let widths: [CGFloat] = [0.95, 0.84, 0.52]
    private var timer: Timer?
    private var start = Date()
    private(set) var active = false
    /// Where the skeleton lines go: the text box, in this view's coordinates.
    var textFrame: NSRect = .zero { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = NextSentenceCardStyle.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0
        let colors = NextSentenceCardStyle.toneColors + [NextSentenceCardStyle.factColors[0]]
        for color in [colors[0], colors[2], colors[3]] {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.colors = [color.withAlphaComponent(0.42).cgColor, color.withAlphaComponent(0).cgColor]
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.compositingFilter = "screenBlendMode"
            layer?.addSublayer(blob)
            blobs.append(blob)
        }
        for _ in widths {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 5
            let shine = CAGradientLayer()
            shine.startPoint = CGPoint(x: 0, y: 0.5)
            shine.endPoint = CGPoint(x: 1, y: 0.5)
            let dim = NSColor(white: 1, alpha: 0.07).cgColor
            shine.colors = [dim, NSColor(white: 1, alpha: 0.18).cgColor, dim]
            shine.locations = [0, 0.15, 0.3]
            bar.layer?.addSublayer(shine)
            addSubview(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fades in and starts drifting, or fades out and stops.
    func set(active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if active {
            start = Date()
            bars.forEach { $0.alphaValue = 1 }
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = active ? 0.6 : 1.1
            animator().alphaValue = active ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.active else { return }
                self.timer?.invalidate()
                self.timer = nil
            }
        })
    }

    /// The first `lines` skeleton lines have text now: melt them away.
    func melt(lines: Int) {
        for (index, bar) in bars.enumerated() where index < lines && bar.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                bar.animator().alphaValue = 0
            }
        }
    }

    private func tick() {
        let t = Date().timeIntervalSince(start)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width, h = bounds.height
        for (index, blob) in blobs.enumerated() {
            let i = Double(index)
            let x = w * (-0.15 + 0.62 * (0.5 + 0.5 * sin(t * 0.52 * (i + 1) + i * 2.1)))
            let y = h * (-0.35 + 0.45 * (0.5 + 0.5 * cos(t * 0.67 * (i + 1) + i)))
            blob.frame = CGRect(x: x, y: y, width: w * 0.6, height: h * 1.5)
        }
        for (index, bar) in bars.enumerated() {
            let breathe = widths[index] + 0.05 * CGFloat(sin(t / 0.62 + Double(index) * 1.4))
            bar.frame = NSRect(x: textFrame.minX, y: textFrame.minY + CGFloat(index) * NextSentenceCardStyle.lineHeight + 7,
                               width: max(0, textFrame.width * breathe), height: 10)
            if let shine = bar.layer?.sublayers?.first as? CAGradientLayer {
                shine.frame = CGRect(x: 0, y: 0, width: 420, height: 10)
                let phase = (t * 0.16 * 1000 + Double(index) * 40).truncatingRemainder(dividingBy: 420) / 420
                shine.locations = [phase - 0.15, phase, phase + 0.15].map { NSNumber(value: $0) }
            }
        }
        CATransaction.commit()
    }
}

/// The footer while it works: a small breathing dot and a shimmering line saying what it's doing
/// ("Reading the window", "Found 3 notes about Riley", "Writing it like you").
final class NextSentenceStatusLine: NextSentenceFlippedView {
    private let dot = NSView()
    private let label = NextSentenceCardStyle.label(.systemFont(ofSize: 11.5, weight: .medium), NSColor(white: 1, alpha: 0.85))
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.white.cgColor
        dot.layer?.cornerRadius = 3
        dot.layer?.shadowColor = NextSentenceCardStyle.accent.cgColor
        dot.layer?.shadowOpacity = 0.9
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOffset = .zero
        addSubview(dot)
        label.wantsLayer = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ new: String) {
        guard new != text else { return }
        let first = text.isEmpty
        text = new
        if !first, !NextSentenceMotion.reduced {
            let change = CATransition()
            change.type = .push
            change.subtype = .fromBottom
            change.duration = 0.26
            change.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            label.layer?.add(change, forKey: "change")
        }
        label.stringValue = new
        needsLayout = true
    }

    /// Starts or stops the dot's breathing and the text shimmer.
    func set(running: Bool) {
        dot.layer?.removeAllAnimations()
        NextSentenceMotion.shimmer(label, on: running)
        guard running, !NextSentenceMotion.reduced else { return }
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.82
        breathe.toValue = 1.18
        breathe.duration = 0.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        dot.layer?.add(breathe, forKey: "breathe")
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 0, y: (bounds.height - 6) / 2, width: 6, height: 6)
        label.frame = NSRect(x: 13, y: (bounds.height - 15) / 2, width: bounds.width - 13, height: 15)
    }
}

/// Ink bleed for streamed words: each new stretch of text lands in bright accent blue with a glow
/// and cools to its final color over about a second, so you can see the leading edge of the thought.
struct NextSentenceInk {
    static let duration: TimeInterval = 1.15
    private var arrivals: [(range: NSRange, at: Date)] = []

    var isActive: Bool { arrivals.contains { Date().timeIntervalSince($0.at) < Self.duration } }

    /// Text grew from `old` to `new` characters: the new stretch starts glowing now.
    mutating func noteGrowth(from old: Int, to new: Int) {
        guard new > old else { return }
        arrivals.append((NSRange(location: old, length: new - old), Date()))
    }

    mutating func reset() { arrivals.removeAll() }

    /// Colors and glows the fresh stretches in `storage`, given each range's settled color.
    mutating func apply(to storage: NSTextStorage, settled: (Int) -> NSColor) {
        let now = Date()
        arrivals.removeAll { now.timeIntervalSince($0.at) >= Self.duration + 0.1 }
        let hot = NSColor(srgbRed: 0.35, green: 0.66, blue: 1, alpha: 1)
        storage.beginEditing()
        for arrival in arrivals where NSMaxRange(arrival.range) <= storage.length {
            let raw = min(1, now.timeIntervalSince(arrival.at) / Self.duration)
            let cool = 1 - pow(1 - raw, 3)
            let final = settled(arrival.range.location)
            storage.addAttribute(.foregroundColor, value: hot.blended(withFraction: CGFloat(cool), of: final) ?? final, range: arrival.range)
            let glow = NSShadow()
            glow.shadowColor = NextSentenceCardStyle.accent.withAlphaComponent(0.7 * CGFloat(1 - cool))
            glow.shadowBlurRadius = 8 * CGFloat(1 - cool)
            glow.shadowOffset = .zero
            storage.addAttribute(.shadow, value: glow, range: arrival.range)
        }
        storage.endEditing()
    }
}
