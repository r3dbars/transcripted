// AudioWaveformView.swift
// Animated audio level visualizer for the floating overlay
// Center-peaked bars with idle breathing and organic phase-shifted motion
// Supports compact mode (4 bars, 20px) for inline use in headers/placeholders

import SwiftUI

struct AudioWaveformView: View {
    let level: Float  // 0.0 to 1.0 (logarithmic from SpeechEngine)
    var compact: Bool = false

    // Dynamic layout based on mode
    private var barCount: Int { compact ? 4 : 9 }
    private var barWidth: CGFloat { compact ? 2.5 : 4 }
    private var barSpacing: CGFloat { compact ? 2 : 3 }
    private var minHeight: CGFloat { compact ? 3 : 6 }
    private var maxHeight: CGFloat { compact ? 16 : 56 }
    private var containerSize: CGFloat { compact ? 20 : 64 }

    // Center-peaked envelope: middle bar = 1.0, edges taper to 0.45
    private func envelope(for index: Int) -> Float {
        let center = Float(barCount - 1) / 2.0
        let maxDist = max(center, 1.0)
        let dist = abs(Float(index) - center) / maxDist
        return 1.0 - dist * 0.55
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: compact ? 1.5 : 2)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: barWidth, height: barHeight(index: i, date: timeline.date))
                }
            }
            .frame(width: containerSize, height: containerSize)
        }
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let lvl = CGFloat(level)

        // Idle breathing: each bar oscillates at a unique frequency/phase
        let breathFreq = 2.0 + Double(index) * 0.15
        let breathPhase = Double(index) * 0.7
        let breathSin = CGFloat(sin(t * breathFreq + breathPhase))
        let breathAmplitude: CGFloat = compact ? 2.0 : 4.0
        let idleHeight = minHeight + breathAmplitude * (1.0 + breathSin) / 2.0

        // Active: level-driven height with center-peaked envelope + per-bar noise
        let env = CGFloat(envelope(for: index))
        let noisePhase = Double(index) * 1.3 + t * 8.0
        let noise = CGFloat(sin(noisePhase)) * 0.15 * lvl
        let barLevel = max(0.0, min(1.0, lvl * env + noise))
        let activeHeight = minHeight + barLevel * (maxHeight - minHeight)

        // Crossfade: silence -> breathing, speech -> level-driven
        let activity = min(1.0, lvl / 0.08)
        return idleHeight * (1.0 - activity) + activeHeight * activity
    }
}
