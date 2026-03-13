import SwiftUI

/// The signature "unforgettable moment" animation
/// Words from transcript scatter outward, then fade as insight cards appear
/// Uses SwiftUI native animations for reliability (no Canvas timing issues)
@available(macOS 26.0, *)
struct ParticleExplosionView: View {
    @State private var phase: AnimationPhase = .idle
    @State private var showCards: Bool = false
    @State private var cardOpacities: [Double] = [0, 0, 0]

    let onComplete: (() -> Void)?

    init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    enum AnimationPhase {
        case idle           // Waiting to start
        case text           // Show transcript text
        case explode        // Words scatter outward
        case fadeOut        // Words fade away
        case complete       // Show insight cards
    }

    // Sample transcript words with their colors
    private let wordGroups: [(words: [String], color: Color)] = [
        (["Let's", "follow", "up", "with", "the", "design", "team"], .terracotta),
        (["by", "Friday"], .terracotta),
        (["I'll", "take", "the", "lead", "on", "the"], .processingPurple),
        (["competitor", "analysis"], .processingPurple),
        (["We're", "targeting"], .successGreen),
        (["March", "15th", "for", "launch"], .successGreen)
    ]

    // Target insights that appear at the end
    private let insights: [(title: String, subtitle: String, color: Color, icon: String)] = [
        ("Action Item", "Follow up with design team by Friday", .terracotta, "checkmark.circle.fill"),
        ("Decision", "Target launch: March 15th", .successGreen, "flag.fill"),
        ("Assignment", "Competitor analysis - assigned", .processingPurple, "person.fill")
    ]

    var body: some View {
        ZStack {
            // Particle words layer
            if phase != .complete {
                ParticleWordsView(
                    wordGroups: wordGroups,
                    phase: phase
                )
                .opacity(phase == .fadeOut ? 0 : 1)
                .animation(.easeOut(duration: 0.5), value: phase)
            }

            // Insight cards layer
            if showCards {
                VStack(spacing: Spacing.md) {
                    ForEach(Array(insights.enumerated()), id: \.offset) { index, insight in
                        InsightCard(
                            icon: insight.icon,
                            title: insight.title,
                            subtitle: insight.subtitle,
                            color: insight.color
                        )
                        .opacity(cardOpacities[index])
                        .scaleEffect(cardOpacities[index] > 0 ? 1 : 0.8)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .transition(.opacity)
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        // Phase 1: Show text (immediate)
        withAnimation(.easeIn(duration: 0.2)) {
            phase = .text
        }

        // Phase 2: Explode words outward (0.6s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                phase = .explode
            }
        }

        // Phase 3: Fade out words (1.8s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.4)) {
                phase = .fadeOut
            }
        }

        // Phase 4: Show cards (2.4s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            phase = .complete
            showCards = true

            // Staggered card appearance
            for i in 0..<3 {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(i) * 0.15)) {
                    cardOpacities[i] = 1.0
                }
            }

            // Notify completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                onComplete?()
            }
        }
    }
}

// MARK: - Particle Words View (Using SwiftUI Layout)

@available(macOS 26.0, *)
private struct ParticleWordsView: View {
    let wordGroups: [(words: [String], color: Color)]
    let phase: ParticleExplosionView.AnimationPhase

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            // Generate all words with their explosion offsets
            let allWords = generateWordData(center: center, containerSize: geometry.size)

            ZStack {
                ForEach(allWords) { word in
                    Text(word.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(word.color)
                        .position(
                            x: word.basePosition.x + (phase == .explode ? word.explosionOffset.x : 0),
                            y: word.basePosition.y + (phase == .explode ? word.explosionOffset.y : 0)
                        )
                        .scaleEffect(phase == .explode ? word.explosionScale : 1.0)
                        .opacity(phase == .idle ? 0 : 1)
                        .animation(
                            .spring(response: 0.6, dampingFraction: 0.7)
                                .delay(word.animationDelay),
                            value: phase
                        )
                }
            }
        }
    }

    private func generateWordData(center: CGPoint, containerSize: CGSize) -> [WordData] {
        var words: [WordData] = []
        var wordIndex = 0

        // Layout words in three rows centered in the container
        let rowHeight: CGFloat = 32
        let startY = center.y - rowHeight // Start one row above center

        // Flatten word groups into rows
        let rows: [[(String, Color)]] = [
            wordGroups[0].words.map { ($0, wordGroups[0].color) } +
            wordGroups[1].words.map { ($0, wordGroups[1].color) },

            wordGroups[2].words.map { ($0, wordGroups[2].color) } +
            wordGroups[3].words.map { ($0, wordGroups[3].color) },

            wordGroups[4].words.map { ($0, wordGroups[4].color) } +
            wordGroups[5].words.map { ($0, wordGroups[5].color) }
        ]

        for (rowIndex, row) in rows.enumerated() {
            // Calculate total width of this row (approximate)
            let totalWidth = row.reduce(0) { $0 + estimateWordWidth($1.0) + 8 }
            var currentX = center.x - totalWidth / 2
            let currentY = startY + CGFloat(rowIndex) * rowHeight

            for (text, color) in row {
                let wordWidth = estimateWordWidth(text)
                let wordCenter = currentX + wordWidth / 2

                // Create explosion offset (radial burst from center)
                let dx = wordCenter - center.x
                let dy = currentY - center.y
                let distance = sqrt(dx * dx + dy * dy)
                let normalizedX = distance > 0 ? dx / distance : 0
                let normalizedY = distance > 0 ? dy / distance : 0

                // Deterministic "random" based on word index (seeded by index)
                // This ensures consistent values across redraws
                let seed = Double(wordIndex + 1)
                let explosionMagnitude = 60 + CGFloat(sin(seed * 1.7) * 30 + 30) // Range ~60-120
                let randomAngle = CGFloat(sin(seed * 2.3) * 0.4) // Range ~-0.4 to 0.4

                let word = WordData(
                    id: wordIndex,
                    text: text,
                    color: color,
                    basePosition: CGPoint(x: wordCenter, y: currentY),
                    explosionOffset: CGPoint(
                        x: (normalizedX + randomAngle) * explosionMagnitude,
                        y: (normalizedY - 0.3) * explosionMagnitude // Slight upward bias
                    ),
                    explosionScale: 0.9 + CGFloat(sin(seed * 3.1) * 0.15 + 0.15), // Range ~0.9-1.2
                    animationDelay: Double(wordIndex) * 0.02
                )

                words.append(word)
                currentX += wordWidth + 8
                wordIndex += 1
            }
        }

        return words
    }

    private func estimateWordWidth(_ text: String) -> CGFloat {
        // More accurate width estimation based on character types
        var width: CGFloat = 0
        for char in text {
            if char.isUppercase || char == "W" || char == "M" {
                width += 10
            } else if char.isLetter {
                width += 7.5
            } else {
                width += 5
            }
        }
        return max(width, 20)
    }
}

// MARK: - Word Data Model

private struct WordData: Identifiable {
    let id: Int
    let text: String
    let color: Color
    let basePosition: CGPoint
    let explosionOffset: CGPoint
    let explosionScale: CGFloat
    let animationDelay: Double
}

// MARK: - Supporting Types (kept for compatibility)

enum InsightCategory: Int {
    case actionItem = 0
    case decision = 1
    case assignment = 2

    var color: Color {
        switch self {
        case .actionItem: return .terracotta
        case .decision: return .successGreen
        case .assignment: return .processingPurple
        }
    }
}

struct WordParticle: Identifiable {
    let id: UUID
    var text: String
    var originalPosition: CGPoint
    var targetPosition: CGPoint
    var velocity: CGVector
    var category: InsightCategory
}

// MARK: - Insight Card

@available(macOS 26.0, *)
struct InsightCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(color)
            }

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(subtitle)
                    .font(.bodyMedium)
                    .foregroundColor(.charcoal)
            }

            Spacer()

            // Checkmark
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
        }
        .padding(Spacing.md)
        .background(Color.warmCream)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
        .shadow(
            color: color.opacity(isHovered ? 0.15 : 0.08),
            radius: isHovered ? 12 : 6,
            x: 0,
            y: isHovered ? 4 : 2
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.smooth, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    ParticleExplosionView()
        .frame(width: 500, height: 400)
        .background(Color.cream)
}
#endif
