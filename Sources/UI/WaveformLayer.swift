// WaveformLayer.swift
// Real-time scrolling waveform using CALayer + CADisplayLink — pure AppKit, no SwiftUI
// Thin vertical bars scroll right-to-left, height driven by audio level

import AppKit
import QuartzCore

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
            let opacity = 0.4 + CGFloat(sampleValue) * 0.45
            ctx.setFillColor(NSColor.white.withAlphaComponent(opacity).cgColor)

            let path = CGPath(roundedRect: rect, cornerWidth: barCornerRadius, cornerHeight: barCornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
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
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drawingLayer.setNeedsDisplay()
            }
        }
    }

    private func stopTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }
}
