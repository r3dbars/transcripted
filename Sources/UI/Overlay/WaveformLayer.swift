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
    var mirroredBarCount = OverlayTokens.waveformMirroredBarCount
    var mirroredBarWidth = OverlayTokens.waveformBarWidth
    var mirroredBarSpacing = OverlayTokens.waveformMirroredBarSpacing

    // Bar geometry — matches original SwiftUI waveform
    let barWidth = OverlayTokens.waveformBarWidth
    let barSpacing = OverlayTokens.waveformBarSpacing
    var barStride: CGFloat { barWidth + barSpacing }
    let minBarHeight = OverlayTokens.waveformMinBarHeight
    let maxBarHeight = OverlayTokens.waveformMaxBarHeight
    let barCornerRadius = OverlayTokens.waveformBarCornerRadius
    let sampleInterval = OverlayTokens.waveformSampleInterval

    override func draw(in ctx: CGContext) {
        let now = CFAbsoluteTimeGetCurrent()
        recordSamplesIfNeeded(now: now)

        switch visualizationStyle {
        case .scrolling:
            drawScrolling(in: ctx, now: now)
        case .mirrored(let anchor, let phaseOffset):
            drawMirrored(in: ctx, now: now, anchor: anchor, phaseOffset: phaseOffset)
        }
    }

    private func drawScrolling(in ctx: CGContext, now: CFAbsoluteTime) {
        guard buffer.currentCount > 0 else { return }

        // 2. Smooth fractional scroll offset for sub-pixel motion
        let smoothOffset = scrollingOffset(now: now, stride: barStride)

        let size = bounds.size
        let centerY = size.height / 2.0
        let effectiveMaxBarHeight = max(minBarHeight, min(maxBarHeight, max(1, size.height - 1)))

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
            let barHeight = max(minBarHeight, boosted * effectiveMaxBarHeight)

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
        guard buffer.currentCount > 0 else { return }

        let _ = phaseOffset
        let stride = mirroredBarWidth + mirroredBarSpacing
        let maxVisibleBars = min(max(1, mirroredBarCount), Int(ceil((size.width + stride) / stride)) + 1)
        let barsToDraw = min(maxVisibleBars, buffer.currentCount)
        let smoothOffset = scrollingOffset(now: now, stride: stride)
        let maxHeight = max(1, size.height - 1)
        let baseAlpha = tintColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1

        for i in 0..<barsToDraw {
            let barIndex = buffer.currentCount - 1 - i
            let sampleValue = smoothedSample(at: barIndex)
            let boosted = CGFloat(sqrt(sampleValue))
            let visualIndex = barsToDraw - 1 - i
            let env = envelopeMultiplier(for: visualIndex, of: barsToDraw)
            let barHeight = max(minBarHeight, boosted * maxHeight * env)
            let x = size.width - CGFloat(i + 1) * stride - smoothOffset + mirroredBarSpacing
            guard x + mirroredBarWidth > 0 else { break }
            guard x < size.width else { continue }
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

            let opacity = baseAlpha * (0.42 + CGFloat(sampleValue) * 0.48)
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

    private func recordSamplesIfNeeded(now: CFAbsoluteTime) {
        let elapsed = now - lastSampleTime
        if elapsed >= sampleInterval {
            let sampleCount = min(Int(elapsed / sampleInterval), 3)
            for _ in 0..<sampleCount {
                buffer.append(currentLevel)
            }
            lastSampleTime = now
        }
    }

    private func scrollingOffset(now: CFAbsoluteTime, stride: CGFloat) -> CGFloat {
        let currentElapsed = now - lastSampleTime
        let fractionalProgress = min(currentElapsed / sampleInterval, 1.0)
        return CGFloat(fractionalProgress) * stride
    }

    private func smoothedSample(at index: Int) -> Float {
        let current = buffer.sample(at: index)
        let previous = buffer.sample(at: max(0, index - 1))
        let next = buffer.sample(at: min(buffer.currentCount - 1, index + 1))
        return min(1, max(0, current * 0.6 + previous * 0.2 + next * 0.2))
    }

    private func envelopeMultiplier(for index: Int, of total: Int) -> CGFloat {
        guard total > 1 else { return 1 }
        let norm = (CGFloat(index) - CGFloat(total - 1) / 2) / (CGFloat(total - 1) / 2)
        let envelope = pow(cos(norm * .pi / 2), 1.2) * 0.85 + 0.15
        return max(0.15, envelope)
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
        didSet {
            drawingLayer.currentLevel = Self.clampedLevel(level)
            if isActive {
                drawingLayer.setNeedsDisplay()
            }
        }
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

    var mirroredBarCount: Int = OverlayTokens.waveformMirroredBarCount {
        didSet {
            drawingLayer.mirroredBarCount = mirroredBarCount
            drawingLayer.setNeedsDisplay()
        }
    }

    var mirroredBarWidth: CGFloat = OverlayTokens.waveformBarWidth {
        didSet {
            drawingLayer.mirroredBarWidth = mirroredBarWidth
            drawingLayer.setNeedsDisplay()
        }
    }

    var mirroredBarSpacing: CGFloat = OverlayTokens.waveformMirroredBarSpacing {
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
                drawingLayer.lastSampleTime = 0
                startTimer()
                drawingLayer.setNeedsDisplay()
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
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(handleRenderTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private func stopTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    @objc private func handleRenderTick() {
        drawingLayer.setNeedsDisplay()
    }

    private static func clampedLevel(_ level: Float) -> Float {
        guard level.isFinite else { return 0 }
        return max(0, min(1, level))
    }
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

    let barWidth = OverlayTokens.waveformBarWidth
    let barSpacing = OverlayTokens.waveformBarSpacing
    var barStride: CGFloat { barWidth + barSpacing }
    let minBarHeight = OverlayTokens.waveformMinBarHeight
    let maxBarHeight = OverlayTokens.waveformMaxBarHeight
    let barCornerRadius = OverlayTokens.waveformBarCornerRadius
    let sampleInterval = OverlayTokens.waveformSampleInterval

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
    private var renderTimer: Timer?

    var primaryLevel: Float = 0 {
        didSet {
            drawingLayer.primaryLevel = Self.clampedLevel(primaryLevel)
            if isActive {
                drawingLayer.setNeedsDisplay()
            }
        }
    }

    var secondaryLevel: Float = 0 {
        didSet {
            drawingLayer.secondaryLevel = Self.clampedLevel(secondaryLevel)
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
                startTimer()
                drawingLayer.setNeedsDisplay()
            } else {
                stopTimer()
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
        stopTimer()
        super.removeFromSuperview()
    }

    deinit {
        renderTimer?.invalidate()
    }

    private func startTimer() {
        guard renderTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(handleRenderTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private func stopTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    @objc private func handleRenderTick() {
        drawingLayer.setNeedsDisplay()
    }

    private static func clampedLevel(_ level: Float) -> Float {
        guard level.isFinite else { return 0 }
        return max(0, min(1, level))
    }
}
