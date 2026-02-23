// FluidWaveformView.swift
// Three overlapping sine waves rendered at 60fps via TimelineView + Canvas.
// Organic, breathing waveform that reacts dynamically to voice level.

import SwiftUI

struct FluidWaveformView: View {
    let level: Float  // 0.0–1.0, audio RMS level from WhisperEngine

    // Smoothed level for fluid transitions (avoids jumpy amplitude)
    @State private var smoothLevel: CGFloat = 0

    // Wave layers with distinct character
    private struct WaveConfig {
        let freqScale: Double    // Frequency relative to base
        let speed: Double        // Scroll speed
        let opacity: Double      // Base opacity
        let lineWidth: CGFloat   // Stroke width
        let reactSpeed: Double   // How fast this wave reacts to level (0-1, lower = more lag)
        let phaseOffset: Double  // Starting phase offset
    }

    private let waves: [WaveConfig] = [
        WaveConfig(freqScale: 0.6,  speed: 0.8,  opacity: 0.15, lineWidth: 2.5, reactSpeed: 0.3, phaseOffset: 0.0),
        WaveConfig(freqScale: 0.85, speed: 1.2,  opacity: 0.30, lineWidth: 2.0, reactSpeed: 0.5, phaseOffset: 1.8),
        WaveConfig(freqScale: 1.0,  speed: 1.6,  opacity: 0.50, lineWidth: 1.8, reactSpeed: 0.7, phaseOffset: 3.2),
        WaveConfig(freqScale: 1.4,  speed: 2.2,  opacity: 0.70, lineWidth: 1.5, reactSpeed: 0.85, phaseOffset: 4.7),
        WaveConfig(freqScale: 1.8,  speed: 2.8,  opacity: 0.90, lineWidth: 1.2, reactSpeed: 1.0, phaseOffset: 5.9),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                for wave in waves {
                    // Each wave reacts at a different speed — creates organic lag
                    let waveLevel = smoothLevel * CGFloat(wave.reactSpeed)
                    let amplitude = amplitudeForLevel(waveLevel, height: size.height)

                    let path = wavePath(
                        in: size,
                        time: time,
                        wave: wave,
                        amplitude: amplitude
                    )

                    let color = colorForLevel(smoothLevel)
                    context.stroke(
                        path,
                        with: .color(color.opacity(wave.opacity)),
                        lineWidth: wave.lineWidth
                    )
                }
            }
        }
        .onChange(of: level) {
            // Smooth the audio level — easeOut interpolation toward target
            withAnimation(.easeOut(duration: 0.12)) {
                smoothLevel = CGFloat(level)
            }
        }
    }

    // MARK: - Wave Math

    private func amplitudeForLevel(_ level: CGFloat, height: CGFloat) -> CGFloat {
        let maxAmplitude = height * 0.42
        if level < 0.03 {
            return maxAmplitude * 0.035
        }
        // Curve the response — quiet sounds still visible, loud sounds dramatic
        let curved = pow(level, 0.7)
        return maxAmplitude * min(1.0, curved)
    }

    private func wavePath(
        in size: CGSize,
        time: Double,
        wave: WaveConfig,
        amplitude: CGFloat
    ) -> Path {
        let midY = size.height / 2
        let wavelength = size.width / 1.8
        let frequency = (2.0 * .pi) / wavelength * wave.freqScale
        let steps = Int(size.width / 1.5)  // ~1.5px per point for smooth curves

        var path = Path()
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps) * size.width
            let xNorm = Double(x) / Double(size.width)

            // Primary sine wave
            let phase = frequency * Double(x) - wave.speed * time + wave.phaseOffset
            let primary = sin(phase)

            // Secondary harmonic — adds organic complexity
            let harmonic = 0.3 * sin(phase * 2.1 + time * 0.4)

            // Slow drift — wave shape subtly evolves over time
            let drift = 0.15 * sin(xNorm * 3.0 + time * 0.3 + wave.phaseOffset * 0.5)

            let combined = primary + harmonic + drift

            // Edge taper: smooth sine envelope
            let taper = sin(xNorm * .pi)
            let taperSq = taper * taper  // Sharper falloff at edges

            // Idle breathing: slow pulse when silent
            let breathe: CGFloat = smoothLevel < 0.03
                ? 0.4 + 0.6 * CGFloat(sin(time * 0.9 + wave.phaseOffset * 0.7))
                : 1.0

            let y = midY + amplitude * CGFloat(combined) * CGFloat(taperSq) * breathe

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    /// Smooth mint → cyan gradient based on level.
    private func colorForLevel(_ level: CGFloat) -> Color {
        // Mint: (0.07, 0.94, 0.58) → Cyan: (0.0, 0.85, 0.95)
        let t = min(1.0, level * 1.5)  // Reaches full cyan at ~0.67 level
        let r = 0.07 * (1 - t) + 0.0 * t
        let g = 0.94 * (1 - t) + 0.85 * t
        let b = 0.58 * (1 - t) + 0.95 * t
        return Color(red: r, green: g, blue: b)
    }
}
