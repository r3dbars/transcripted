// NotchIslandBarsView.swift
// The island's level drawings: the scrolling bars (the dictation waveform in
// the wing and the recording drop-down's You and Call lanes) and the meeting
// wing's one shared row of your and the call's levels. Split out of
// NotchIslandView.swift.

import AppKit
import QuartzCore

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

/// You and the call in one row (`NotchIslandMeetingLevelRow`). At rest the
/// whole row is dim accent dots; your voice lights its bars in the full
/// accent, the call's stay dim. A light timer steps the row while it is in a
/// window and stops once the row is at rest with no readings (a hidden island
/// keeps its last wing items), so nothing ticks between meetings.
final class NotchIslandMeetingLevelsView: NSView {
    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 2
    private static let maxBarHeight: CGFloat = 16
    private static let dimAlpha: CGFloat = 0.4

    private var row = NotchIslandMeetingLevelRow()
    private var stepTimer: Timer?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let count = CGFloat(NotchIslandMeetingLevelRow.count)
        return NSSize(width: count * Self.barWidth + (count - 1) * Self.gap, height: Self.maxBarHeight)
    }

    func update(mic: Float, system: Float) {
        row.receive(mic: mic, system: system, at: CACurrentMediaTime())
        if stepTimer == nil { startTimer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopTimer()
        startTimer()
    }

    // Target-selector timer: stopped when the wing drops the view or the row
    // comes to rest, which also breaks the timer's hold on the view.
    private func startTimer() {
        guard window != nil, stepTimer == nil else { return }
        let timer = Timer(
            timeInterval: NotchIslandMeetingLevelRow.stepInterval,
            target: self,
            selector: #selector(step),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = NotchIslandMeetingLevelRow.stepInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    private func stopTimer() {
        stepTimer?.invalidate()
        stepTimer = nil
    }

    @objc private func step() {
        let now = CACurrentMediaTime()
        guard !row.isAtRest(at: now) else {
            stopTimer()
            return
        }
        row.step(at: now)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NotchIslandPalette.accent
        let dim = accent.withAlphaComponent(Self.dimAlpha)
        for (index, slot) in row.slots.enumerated() {
            let x = CGFloat(index) * (Self.barWidth + Self.gap)
            if let call = slot.call { drawBar(at: x, level: call, color: dim) }
            if let you = slot.you {
                drawBar(at: x, level: you, color: you > NotchIslandMeetingLevelRow.audible ? accent : dim)
            }
        }
    }

    private func drawBar(at x: CGFloat, level: Float, color: NSColor) {
        color.setFill()
        let height = max(3, CGFloat(level) * Self.maxBarHeight)
        let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: Self.barWidth, height: height)
        NSBezierPath(roundedRect: rect, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
    }
}
