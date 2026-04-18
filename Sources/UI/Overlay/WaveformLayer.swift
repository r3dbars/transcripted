// WaveformLayer.swift
// Real-time scrolling waveform using CALayer + CADisplayLink — pure AppKit, no SwiftUI
// Thin vertical bars scroll right-to-left, height driven by audio level

import AppKit
import QuartzCore

enum WaveformMirroredAnchor {
    case fromBottom
    case fromTop
}

enum WaveformVisualizationStyle {
    case scrolling
    case mirrored(anchor: WaveformMirroredAnchor, phaseOffset: CGFloat)
}

// MARK: - Ring Buffer (extracted from ScrollingWaveformView, unchanged)

/// Fixed-capacity circular buffer of audio level samples.
/// O(1) append, O(1) read, zero allocations after init.
struct WaveformRingBuffer {
    private var storage: [Float]
    private var writeIndex: Int = 0
    private var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ level: Float) {
        storage[writeIndex % capacity] = level
        writeIndex += 1
        count = min(count + 1, capacity)
    }

    /// Read the i-th sample in chronological order (0 = oldest visible, count-1 = newest)
    func sample(at index: Int) -> Float {
        guard index >= 0, index < count else { return 0 }
        let readIndex = (writeIndex - count + index + capacity) % capacity
        return storage[readIndex]
    }

    mutating func clear() {
        writeIndex = 0
        count = 0
    }

    var currentCount: Int { count }
}

// MARK: - Waveform Drawing Layer

/// CALayer that draws the waveform bars. Driven by WaveformHostView's display link.
final class WaveformDrawingLayer: CALayer {
    var buffer = WaveformRingBuffer(capacity: 150)
    var lastSampleTime: CFAbsoluteTime = 0
    var currentLevel: Float = 0
    var tintColor: NSColor = .white
    var visualizationStyle: WaveformVisualizationStyle = .scrolling
    var mirroredBarCount: Int = 26
    var mirroredBarWidth: CGFloat = 2
    var mirroredBarSpacing: CGFloat = 1.5

    // Bar geometry — matches original SwiftUI waveform
    let barWidth: CGFloat = 2
    let barSpacing: CGFloat = 1
    var barStride: CGFloat { barWidth + barSpacing }
    let minBarHeight: CGFloat = 2
    let maxBarHeight: CGFloat = 14
    let barCornerRadius: CGFloat = 1
    let sampleInterval: TimeInterval = 0.05  // 20Hz

    override func draw(in ctx: CGContext) {
        let now = CFAbsoluteTimeGetCurrent()

        switch visualizationStyle {
        case .scrolling:
            drawScrolling(in: ctx, now: now)
        case .mirrored(let anchor, let phaseOffset):
            drawMirrored(in: ctx, now: now, anchor: anchor, phaseOffset: phaseOffset)
        }
    }

    private func drawScrolling(in ctx: CGContext, now: CFAbsoluteTime) {
        // 1. Sample audio level into ring buffer at 20Hz
        let elapsed = now - lastSampleTime
        if elapsed >= sampleInterval {
            let sampleCount = min(Int(elapsed / sampleInterval), 3)
            for _ in 0..<sampleCount {
                buffer.append(currentLevel)
            }
            lastSampleTime = now
        }

        guard buffer.currentCount > 0 else { return }

        // 2. Smooth fractional scroll offset for sub-pixel motion
        let currentElapsed = now - lastSampleTime
        let fractionalProgress = min(currentElapsed / sampleInterval, 1.0)
        let smoothOffset = CGFloat(fractionalProgress) * barStride

        let size = bounds.size
        let centerY = size.height / 2.0

        // 3. Draw bars right-to-left (newest at right edge)
        let maxVisibleBars = Int(ceil((size.width + barStride) / barStride)) + 1
        let barsToDraw = min(maxVisibleBars, buffer.currentCount)

        for i in 0..<barsToDraw {
            let barIndex = buffer.currentCount - 1 - i
            let sampleValue = buffer.sample(at: barIndex)

            let x = size.width - CGFloat(i + 1) * barStride - smoothOffset + barSpacing
            guard x + barWidth > 0 else { break }
            guard x < size.width else { continue }

            // Height: sqrt curve boosts low/mid levels
            let boosted = CGFloat(sqrt(sampleValue))
            let barHeight = max(minBarHeight, boosted * maxBarHeight)

            let rect = CGRect(
                x: x,
                y: centerY - barHeight / 2.0,
                width: barWidth,
                height: barHeight
            )

            // Opacity: subtle brightness variation with amplitude
            let opacity = 0.42 + CGFloat(sampleValue) * 0.48
            ctx.setFillColor(tintColor.withAlphaComponent(opacity).cgColor)

            let path = CGPath(roundedRect: rect, cornerWidth: barCornerRadius, cornerHeight: barCornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    private func drawMirrored(
        in ctx: CGContext,
        now: CFAbsoluteTime,
        anchor: WaveformMirroredAnchor,
        phaseOffset: CGFloat
    ) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let count = max(1, mirroredBarCount)
        let stride = mirroredBarWidth + mirroredBarSpacing
        let totalWidth = CGFloat(count) * mirroredBarWidth + CGFloat(max(0, count - 1)) * mirroredBarSpacing
        let startX = max(0, (size.width - totalWidth) / 2)
        let maxHeight = max(1, size.height - 1)
        let level = max(0, min(1, CGFloat(currentLevel)))
        let boostedLevel = max(0.08, sqrt(level))
        let baseAlpha = tintColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1
        let time = CGFloat(now)

        for index in 0..<count {
            let env = envelopeMultiplier(for: index, of: count)
            let phase = phaseOffset + CGFloat(index) * 0.48
            let motionA = normalizedSine(time * 4.8 + phase)
            let motionB = normalizedSine(time * 7.1 + phase * 1.7 + 0.9)
            let motion = max(0.12, motionA * 0.7 + motionB * 0.3)
            let rawLevel = min(1, boostedLevel * (0.45 + motion * 0.9))
            let barHeight = max(minBarHeight, rawLevel * maxHeight * env)
            let x = startX + CGFloat(index) * stride
            let y: CGFloat = switch anchor {
            case .fromBottom:
                0
            case .fromTop:
                size.height - barHeight
            }

            let rect = CGRect(
                x: x,
                y: y,
                width: mirroredBarWidth,
                height: barHeight
            )

            let opacity = baseAlpha * (0.5 + rawLevel * 0.5)
            ctx.setFillColor(tintColor.withAlphaComponent(opacity).cgColor)

            let path = CGPath(
                roundedRect: rect,
                cornerWidth: mirroredBarWidth / 2,
                cornerHeight: mirroredBarWidth / 2,
                transform: nil
            )
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    private func envelopeMultiplier(for index: Int, of total: Int) -> CGFloat {
        guard total > 1 else { return 1 }
        let norm = (CGFloat(index) - CGFloat(total - 1) / 2) / (CGFloat(total - 1) / 2)
        let envelope = pow(cos(norm * .pi / 2), 1.2) * 0.85 + 0.15
        return max(0.15, envelope)
    }

    private func normalizedSine(_ value: CGFloat) -> CGFloat {
        (sin(value) + 1) / 2
    }
}

// MARK: - Host View

/// NSView that hosts the waveform drawing layer and drives it with a timer.
/// Uses a 30fps Timer (sufficient for waveform animation) instead of CADisplayLink
/// which requires NSView/NSScreen on macOS (not available via the iOS-style init).
@MainActor
final class WaveformHostView: NSView {
    private let drawingLayer = WaveformDrawingLayer()
    private var renderTimer: Timer?

    /// Current audio level (0.0–1.0). Set by the controller from sttRouter.audioLevel.
    var level: Float = 0 {
        didSet { drawingLayer.currentLevel = level }
    }

    var tintColor: NSColor = .white {
        didSet { drawingLayer.tintColor = tintColor }
    }

    var visualizationStyle: WaveformVisualizationStyle = .scrolling {
        didSet {
            drawingLayer.visualizationStyle = visualizationStyle
            drawingLayer.buffer.clear()
            drawingLayer.lastSampleTime = 0
            drawingLayer.setNeedsDisplay()
        }
    }

    var mirroredBarCount: Int = 26 {
        didSet {
            drawingLayer.mirroredBarCount = mirroredBarCount
            drawingLayer.setNeedsDisplay()
        }
    }

    var mirroredBarWidth: CGFloat = 2 {
        didSet {
            drawingLayer.mirroredBarWidth = mirroredBarWidth
            drawingLayer.setNeedsDisplay()
        }
    }

    var mirroredBarSpacing: CGFloat = 1.5 {
        didSet {
            drawingLayer.mirroredBarSpacing = mirroredBarSpacing
            drawingLayer.setNeedsDisplay()
        }
    }

    /// Start/stop the render timer. Stop when not recording to avoid unnecessary GPU work.
    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                startTimer()
            } else {
                stopTimer()
                drawingLayer.buffer.clear()
                drawingLayer.lastSampleTime = 0
                drawingLayer.setNeedsDisplay()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        drawingLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        drawingLayer.tintColor = tintColor
        drawingLayer.visualizationStyle = visualizationStyle
        drawingLayer.mirroredBarCount = mirroredBarCount
        drawingLayer.mirroredBarWidth = mirroredBarWidth
        drawingLayer.mirroredBarSpacing = mirroredBarSpacing
        drawingLayer.frame = bounds
        layer?.addSublayer(drawingLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawingLayer.frame = bounds
        drawingLayer.contentsScale = window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0)
        CATransaction.commit()
    }

    override func removeFromSuperview() {
        stopTimer()
        super.removeFromSuperview()
    }

    deinit {
        renderTimer?.invalidate()
    }

    // MARK: - Render Timer (30fps)

    private func startTimer() {
        guard renderTimer == nil else { return }
        renderTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(handleRenderTick),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    @objc private func handleRenderTick() {
        drawingLayer.setNeedsDisplay()
    }
}
