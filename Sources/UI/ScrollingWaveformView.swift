// ScrollingWaveformView.swift
// Real-time scrolling waveform for the floating overlay header bar
// Thin vertical bars scroll right-to-left, height driven by audio level
// Uses Canvas for GPU-accelerated drawing + TimelineView for 60fps animation
//
// Key design: WaveformState is a reference type (class) so Canvas closures
// can mutate the buffer across frames. @State with a struct would give each
// Canvas frame a copy that gets discarded after drawing.

import SwiftUI

// MARK: - Ring Buffer

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

// MARK: - Mutable State (Reference Type)

/// Holds mutable waveform state as a reference type so Canvas closures
/// can accumulate samples across frames without copy-on-write issues.
@MainActor
private class WaveformState {
    var buffer = WaveformRingBuffer(capacity: 150)
    var lastSampleTime: Date = .distantPast
}

// MARK: - Scrolling Waveform View

struct ScrollingWaveformView: View {
    let level: Float       // 0.0–1.0, from parakeetEngine.audioLevel
    let isActive: Bool     // true while recording

    // Bar geometry
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1
    private var barStride: CGFloat { barWidth + barSpacing }
    private let minBarHeight: CGFloat = 2      // silence: visible dots
    private let maxBarHeight: CGFloat = 14     // loud speech
    private let cornerRadius: CGFloat = 1

    // Sampling rate matches ParakeetEngine's 20Hz audioLevel throttle
    private let sampleInterval: TimeInterval = 0.05

    @State private var state = WaveformState()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                drawWaveform(context: context, size: size, now: timeline.date)
            }
        }
        .onChange(of: isActive) { _, newValue in
            if !newValue {
                state.buffer.clear()
                state.lastSampleTime = .distantPast
            }
        }
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize, now: Date) {
        // 1. Sample audio level into ring buffer at 20Hz
        let elapsed = now.timeIntervalSince(state.lastSampleTime)
        if elapsed >= sampleInterval {
            let sampleCount = min(Int(elapsed / sampleInterval), 3) // cap catch-up
            for _ in 0..<sampleCount {
                state.buffer.append(level)
            }
            state.lastSampleTime = now
        }

        guard state.buffer.currentCount > 0 else { return }

        // 2. Smooth fractional scroll offset for sub-pixel motion between samples
        let currentElapsed = now.timeIntervalSince(state.lastSampleTime)
        let fractionalProgress = min(currentElapsed / sampleInterval, 1.0)
        let smoothOffset = CGFloat(fractionalProgress) * barStride

        let centerY = size.height / 2.0

        // 3. Draw bars right-to-left (newest at right edge)
        let maxVisibleBars = Int(ceil((size.width + barStride) / barStride)) + 1
        let barsToDraw = min(maxVisibleBars, state.buffer.currentCount)

        for i in 0..<barsToDraw {
            let barIndex = state.buffer.currentCount - 1 - i
            let sampleValue = state.buffer.sample(at: barIndex)

            // X position: right edge minus bar offset minus smooth scroll
            let x = size.width - CGFloat(i + 1) * barStride - smoothOffset + barSpacing

            // Skip bars past the left edge
            guard x + barWidth > 0 else { break }
            // Skip bars past the right edge (can happen during fractional scroll)
            guard x < size.width else { continue }

            // Height: sqrt curve boosts low/mid levels for visual sensitivity
            // (raw audioLevel 0.1 → 0.32, 0.3 → 0.55, 0.5 → 0.71)
            let boosted = CGFloat(sqrt(sampleValue))
            let barHeight = max(minBarHeight, boosted * maxBarHeight)

            // Vertically centered: grow up and down from midline
            let rect = CGRect(
                x: x,
                y: centerY - barHeight / 2.0,
                width: barWidth,
                height: barHeight
            )

            // Opacity: subtle brightness variation with amplitude
            let opacity = 0.4 + Double(sampleValue) * 0.45

            let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
            context.fill(path, with: .color(.white.opacity(opacity)))
        }
    }
}
