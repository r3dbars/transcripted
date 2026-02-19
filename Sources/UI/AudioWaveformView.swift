// AudioWaveformView.swift
// Animated audio level bars for the floating overlay

import SwiftUI

struct AudioWaveformView: View {
    let level: Float  // 0.0 to 1.0

    @State private var levels: [Float] = Array(repeating: 0, count: 5)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 4, height: max(4, CGFloat(levels[i]) * 40))
            }
        }
        .frame(width: 32, height: 44)
        .onChange(of: level) { _, newLevel in
            withAnimation(.easeOut(duration: 0.1)) {
                levels.removeFirst()
                levels.append(newLevel)
            }
        }
    }
}
