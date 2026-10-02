// WaveformLayer.swift
// The meeting overlay's split mic/system waveform: CALayer + a 30fps timer,
// pure AppKit, no SwiftUI. Bar height follows each source's audio level.

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

// MARK: - Render Timer

/// Shared 30fps render-timer lifecycle for the waveform host view (sufficient
/// for waveform animation; CADisplayLink requires NSView/NSScreen on macOS and
/// is not available via the iOS-style init).
@MainActor
private final class WaveformRenderTimerDriver {
    private var timer: Timer?

    func start(tick: @escaping () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

private func clampedWaveformLevel(_ level: Float) -> Float {
    guard level.isFinite else { return 0 }
    return max(0, min(1, level))
}

/// Shared-clock split waveform used by the meeting overlay so mic and system
/// audio feel like one visualizer instead of two independent rows.
final class DualWaveformDrawingLayer: CALayer {
    var primaryBuffer = WaveformRingBuffer(capacity: 150)
    var secondaryBuffer = WaveformRingBuffer(capacity: 150)
    var lastSampleTime: CFAbsoluteTime = 0
    var primaryLevel: Float = 0
    var secondaryLevel: Float = 0
    var primaryTintColor: NSColor = .white
    var secondaryTintColor: NSColor = .white

    let barWidth: CGFloat = 2
    let barSpacing: CGFloat = 1
    var barStride: CGFloat { barWidth + barSpacing }
    let minBarHeight: CGFloat = 2
    let maxBarHeight: CGFloat = 14
    let barCornerRadius: CGFloat = 1
    let sampleInterval: TimeInterval = 0.05

    override func draw(in ctx: CGContext) {
        let now = CFAbsoluteTimeGetCurrent()
        recordSamplesIfNeeded(now: now)

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard primaryBuffer.currentCount > 0 || secondaryBuffer.currentCount > 0 else { return }

        let smoothOffset = scrollingOffset(now: now)
        let centerY = size.height / 2
        let effectiveHalfBarHeight = max(minBarHeight, min(maxBarHeight, max(1, centerY - 1)))
        let maxVisibleBars = Int(ceil((size.width + barStride) / barStride)) + 1
        let barsToDraw = min(maxVisibleBars, max(primaryBuffer.currentCount, secondaryBuffer.currentCount))

        for i in 0..<barsToDraw {
            let x = size.width - CGFloat(i + 1) * barStride - smoothOffset + barSpacing
            guard x + barWidth > 0 else { break }
            guard x < size.width else { continue }

            let primarySample = sampleForDisplay(from: primaryBuffer, stepIndex: i)
            let secondarySample = sampleForDisplay(from: secondaryBuffer, stepIndex: i)
            let secondaryHeight = barHeight(for: secondarySample, maxHeight: effectiveHalfBarHeight)

            // Core Animation draws this layer in a bottom-left coordinate space,
            // so the top stream needs to start at the center line and grow upward.
            drawBar(
                in: ctx,
                sampleValue: primarySample,
                x: x,
                y: centerY,
                maxHeight: effectiveHalfBarHeight,
                tintColor: primaryTintColor
            )
            drawBar(
                in: ctx,
                sampleValue: secondarySample,
                x: x,
                y: centerY - secondaryHeight,
                maxHeight: effectiveHalfBarHeight,
                tintColor: secondaryTintColor
            )
        }
    }

    func reset() {
        primaryBuffer.clear()
        secondaryBuffer.clear()
        lastSampleTime = 0
        setNeedsDisplay()
    }

    private func recordSamplesIfNeeded(now: CFAbsoluteTime) {
        let elapsed = now - lastSampleTime
        if elapsed >= sampleInterval {
            let sampleCount = min(Int(elapsed / sampleInterval), 3)
            for _ in 0..<sampleCount {
                primaryBuffer.append(primaryLevel)
                secondaryBuffer.append(secondaryLevel)
            }
            lastSampleTime = now
        }
    }

    private func scrollingOffset(now: CFAbsoluteTime) -> CGFloat {
        // Reduce Motion: skip the sub-pixel glide so bars don't continuously slide.
        guard !AccessibilityDisplayPolicy.reduceMotion else { return 0 }
        let currentElapsed = now - lastSampleTime
        let fractionalProgress = min(currentElapsed / sampleInterval, 1.0)
        return CGFloat(fractionalProgress) * barStride
    }

    private func sampleForDisplay(from buffer: WaveformRingBuffer, stepIndex: Int) -> Float {
        guard stepIndex < buffer.currentCount else { return 0 }
        let index = buffer.currentCount - 1 - stepIndex
        return buffer.sample(at: index)
    }

    private func barHeight(for sampleValue: Float, maxHeight: CGFloat) -> CGFloat {
        let boosted = CGFloat(sqrt(sampleValue))
        return max(minBarHeight, boosted * maxHeight)
    }

    private func drawBar(
        in ctx: CGContext,
        sampleValue: Float,
        x: CGFloat,
        y: CGFloat,
        maxHeight: CGFloat,
        tintColor: NSColor
    ) {
        let height = barHeight(for: sampleValue, maxHeight: maxHeight)
        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
        let opacity = 0.42 + CGFloat(sampleValue) * 0.48
        ctx.setFillColor(tintColor.withAlphaComponent(opacity).cgColor)

        let path = CGPath(
            roundedRect: rect,
            cornerWidth: barCornerRadius,
            cornerHeight: barCornerRadius,
            transform: nil
        )
        ctx.addPath(path)
        ctx.fillPath()
    }
}

@MainActor
final class DualWaveformHostView: NSView {
    private let drawingLayer = DualWaveformDrawingLayer()
    private let renderDriver = WaveformRenderTimerDriver()

    var primaryLevel: Float = 0 {
        didSet {
            drawingLayer.primaryLevel = clampedWaveformLevel(primaryLevel)
            if isActive {
                drawingLayer.setNeedsDisplay()
            }
        }
    }

    var secondaryLevel: Float = 0 {
        didSet {
            drawingLayer.secondaryLevel = clampedWaveformLevel(secondaryLevel)
            if isActive {
                drawingLayer.setNeedsDisplay()
            }
        }
    }

    var primaryTintColor: NSColor = .white {
        didSet { drawingLayer.primaryTintColor = primaryTintColor }
    }

    var secondaryTintColor: NSColor = .white {
        didSet { drawingLayer.secondaryTintColor = secondaryTintColor }
    }

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                drawingLayer.lastSampleTime = 0
                renderDriver.start { [weak self] in
                    self?.drawingLayer.setNeedsDisplay()
                }
                drawingLayer.setNeedsDisplay()
            } else {
                renderDriver.stop()
                drawingLayer.reset()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        drawingLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        drawingLayer.primaryTintColor = primaryTintColor
        drawingLayer.secondaryTintColor = secondaryTintColor
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
        renderDriver.stop()
        super.removeFromSuperview()
    }
}
