// AnimatedTranscriptView.swift
// Displays text word-by-word with fade-in animation using FlowLayout.
// Used for live Apple Speech transcript during recording.

import SwiftUI

struct AnimatedTranscriptView: View {
    let text: String

    // Track the highest word count seen — prevents fade-in re-trigger on Apple Speech revisions
    @State private var highWaterMark: Int = 0

    private var words: [String] {
        text.split(separator: " ").map(String.init)
    }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .opacity(index < highWaterMark ? 1.0 : 0.0)
                    .animation(
                        .easeOut(duration: 0.08)
                            .delay(index < highWaterMark ? 0 : Double(index - highWaterMark) * 0.008),
                        value: highWaterMark
                    )
            }
        }
        .onChange(of: words.count) {
            if words.count > highWaterMark {
                highWaterMark = words.count
            }
        }
        .onAppear {
            // Initial words get animated in
            if words.count > highWaterMark {
                highWaterMark = words.count
            }
        }
    }
}

// MARK: - FlowLayout (SwiftUI Layout protocol)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
