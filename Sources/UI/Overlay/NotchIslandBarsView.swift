// NotchIslandBarsView.swift
// The island's level drawings: the scrolling bars (the dictation waveform in
// the wing and the recording drop-down's You and Call lanes) and the meeting
// wing's two tiny meters. Split out of NotchIslandView.swift.

import AppKit

/// Level bars that scroll: each new level pushes in from the right.
final class NotchIslandBarsView: NSView {
    private var levels: [CGFloat]
    private let barWidth: CGFloat
    private let gap: CGFloat
    private let maxBarHeight: CGFloat
    var barColor: NSColor
    /// The dictation waveform steps on the display clock
    /// (`NotchIslandLevelScroller`); the meeting lanes are nil and shift once
    /// per `push`.
    private var scroller: NotchIslandLevelScroller?

    init(count: Int, barWidth: CGFloat = 2.5, gap: CGFloat = 2, maxHeight: CGFloat = 16, color: NSColor, clocked: Bool = false) {
        self.levels = Array(repeating: 0, count: max(1, count))
        self.barWidth = barWidth
        self.gap = gap
        self.maxBarHeight = maxHeight
        self.barColor = color
        self.scroller = clocked ? NotchIslandLevelScroller(count: count) : nil
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(levels.count)
        return NSSize(width: count * barWidth + (count - 1) * gap, height: maxBarHeight)
    }

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(Self.shaped(level))
        needsDisplay = true
    }

    func quiet() {
        levels = levels.map { _ in 0 }
        needsDisplay = true
    }

    /// The dictation waveform: a meter reading for the next step.
    func receive(_ reading: DictationAudioLevel, at time: TimeInterval) {
        scroller?.receive(reading, at: time)
    }

    /// The dictation waveform: one display frame. Redraws only on a step.
    func advance(to time: TimeInterval, frameDuration: TimeInterval) {
        guard scroller?.advance(to: time, frameDuration: frameDuration) == true, let scroller else { return }
        levels = scroller.levels.map(Self.shaped)
        needsDisplay = true
    }

    static func shaped(_ level: Float) -> CGFloat {
        CGFloat(min(1, pow(Double(max(0, level)), 0.6) * 1.15))
    }

    override func draw(_ dirtyRect: NSRect) {
        barColor.setFill()
        for (index, level) in levels.enumerated() {
            let height = max(3, level * maxBarHeight)
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

/// You and the call as two tiny three-bar meters.
final class NotchIslandMetersView: NSView {
    private var mic: CGFloat = 0
    private var system: CGFloat = 0
    private var phase = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 14) }

    func update(mic: Float, system: Float) {
        self.mic = NotchIslandBarsView.shaped(mic)
        self.system = NotchIslandBarsView.shaped(system)
        phase += 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape: [CGFloat] = [0.55, 1, 0.7]
        drawGroup(level: mic, originX: 0, color: NotchIslandPalette.accent, shape: shape)
        drawGroup(level: system, originX: 16, color: NSColor(white: 1, alpha: 0.72), shape: shape.reversed())
    }

    private func drawGroup(level: CGFloat, originX: CGFloat, color: NSColor, shape: [CGFloat]) {
        color.setFill()
        for (index, factor) in shape.enumerated() {
            let wobble = CGFloat((phase + index * 3) % 5) * 0.04
            let height = max(3, min(14, (level * factor + wobble) * 14))
            let rect = NSRect(x: originX + CGFloat(index) * 4, y: (bounds.height - height) / 2, width: 2, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}
