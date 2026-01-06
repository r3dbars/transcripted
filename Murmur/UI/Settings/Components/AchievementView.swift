import SwiftUI

/// Achievement celebration overlay with confetti and glow effects
/// Signature moment for milestones: first recording, streaks, action item counts
@available(macOS 14.0, *)
struct AchievementView: View {

    let achievement: Achievement
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var showConfetti = false
    @State private var glowIntensity: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(isVisible ? 0.6 : 0)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Achievement card
            VStack(spacing: Spacing.lg) {
                // Icon with glow
                ZStack {
                    // Outer glow
                    Circle()
                        .fill(achievement.color.opacity(0.3 * glowIntensity))
                        .frame(width: 120, height: 120)
                        .blur(radius: 30)

                    // Middle glow
                    Circle()
                        .fill(achievement.color.opacity(0.5 * glowIntensity))
                        .frame(width: 80, height: 80)
                        .blur(radius: 15)

                    // Icon circle
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [achievement.color, achievement.color.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)
                        .overlay {
                            Text(achievement.emoji)
                                .font(.system(size: 36))
                        }
                        .shadow(color: achievement.color.opacity(0.5), radius: 10, y: 4)
                }
                .scaleEffect(isVisible ? 1 : 0.5)
                .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1), value: isVisible)

                // Title
                Text(achievement.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.panelTextPrimary)
                    .opacity(isVisible ? 1 : 0)
                    .offset(y: isVisible ? 0 : 20)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.2), value: isVisible)

                // Description
                Text(achievement.message)
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .opacity(isVisible ? 1 : 0)
                    .offset(y: isVisible ? 0 : 20)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.3), value: isVisible)

                // Dismiss button
                Button("Awesome!") {
                    dismiss()
                }
                .buttonStyle(AchievementButtonStyle(color: achievement.color))
                .opacity(isVisible ? 1 : 0)
                .offset(y: isVisible ? 0 : 20)
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.4), value: isVisible)
            }
            .padding(Spacing.xl)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.1), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: achievement.color.opacity(0.3), radius: 30, y: 10)
            }
            .scaleEffect(isVisible ? 1 : 0.9)
            .opacity(isVisible ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isVisible)

            // Confetti overlay
            if showConfetti && !reduceMotion {
                ConfettiView(color: achievement.color)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            withAnimation {
                isVisible = true
            }
            // Start glow animation
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    glowIntensity = 1
                }
                // Show confetti
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showConfetti = true
                }
            } else {
                glowIntensity = 0.7
            }
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}

// MARK: - Achievement Model

struct Achievement: Identifiable {
    let id = UUID()
    let type: AchievementType
    let title: String
    let message: String
    let emoji: String
    let color: Color

    enum AchievementType: String {
        case firstRecording
        case streak7
        case streak14
        case streak30
        case actionItems100
        case hoursTranscribed10
    }

    static let firstRecording = Achievement(
        type: .firstRecording,
        title: "First Steps!",
        message: "You've completed your first recording. Every great journey starts with a single step.",
        emoji: "🎉",
        color: .recordingCoral
    )

    static let streak7 = Achievement(
        type: .streak7,
        title: "One Week Strong!",
        message: "7 days in a row! You're building a great habit.",
        emoji: "🔥",
        color: .orange
    )

    static let streak14 = Achievement(
        type: .streak14,
        title: "Two Weeks Champion!",
        message: "14 days of consistent recording. You're unstoppable!",
        emoji: "⚡️",
        color: .yellow
    )

    static let streak30 = Achievement(
        type: .streak30,
        title: "Monthly Master!",
        message: "30 days! You've truly mastered the art of capturing meetings.",
        emoji: "🏆",
        color: Color(hex: "#FFD700") // Gold
    )

    static let actionItems100 = Achievement(
        type: .actionItems100,
        title: "Action Hero!",
        message: "100 action items extracted. You're a productivity powerhouse!",
        emoji: "✅",
        color: .attentionGreen
    )

    static let hoursTranscribed10 = Achievement(
        type: .hoursTranscribed10,
        title: "10 Hours Club!",
        message: "You've transcribed over 10 hours of meetings. That's dedication!",
        emoji: "⏱",
        color: .accentBlue
    )
}

// MARK: - Achievement Button Style

@available(macOS 14.0, *)
struct AchievementButtonStyle: ButtonStyle {

    let color: Color

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color)

                    // Glow on hover
                    if isHovered {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(color.opacity(0.3))
                            .blur(radius: 10)
                    }

                    // Inner highlight
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.3), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
            }
            .shadow(color: color.opacity(0.4), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - Confetti View

@available(macOS 14.0, *)
struct ConfettiView: View {

    let color: Color

    @State private var particles: [ConfettiParticle] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(particles) { particle in
                    particle.shape
                        .fill(particle.color)
                        .frame(width: particle.size, height: particle.size)
                        .rotationEffect(.degrees(particle.rotation))
                        .position(particle.position)
                        .opacity(particle.opacity)
                }
            }
            .onAppear {
                generateParticles(in: geometry.size)
                animateParticles(in: geometry.size)
            }
        }
    }

    private func generateParticles(in size: CGSize) {
        let colors: [Color] = [
            color,
            color.opacity(0.8),
            .recordingCoral,
            .orange,
            .yellow,
            .white.opacity(0.8)
        ]

        particles = (0..<40).map { _ in
            ConfettiParticle(
                position: CGPoint(
                    x: CGFloat.random(in: 0...size.width),
                    y: -20
                ),
                color: colors.randomElement() ?? color,
                size: CGFloat.random(in: 6...12),
                rotation: Double.random(in: 0...360),
                velocity: CGPoint(
                    x: CGFloat.random(in: -100...100),
                    y: CGFloat.random(in: 200...400)
                ),
                opacity: 1.0
            )
        }
    }

    private func animateParticles(in size: CGSize) {
        // Animate each particle
        for index in particles.indices {
            let duration = Double.random(in: 2.0...3.5)

            withAnimation(.easeOut(duration: duration)) {
                particles[index].position.y = size.height + 50
                particles[index].position.x += particles[index].velocity.x
                particles[index].rotation += Double.random(in: 180...540)
            }

            // Fade out at the end
            withAnimation(.easeOut(duration: duration).delay(duration * 0.7)) {
                particles[index].opacity = 0
            }
        }
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    let color: Color
    let size: CGFloat
    var rotation: Double
    let velocity: CGPoint
    var opacity: Double

    var shape: some Shape {
        let shapes: [AnyShape] = [
            AnyShape(Circle()),
            AnyShape(Rectangle()),
            AnyShape(RoundedRectangle(cornerRadius: 2))
        ]
        return shapes.randomElement()!
    }
}

struct AnyShape: Shape {
    private let _path: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        _path = { shape.path(in: $0) }
    }

    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

// MARK: - Glow Up Effect (for stats above average)

@available(macOS 14.0, *)
struct GlowUpEffect: View {

    let isActive: Bool
    let color: Color

    @State private var pulsePhase: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(0.15 * (reduceMotion ? 1 : (0.5 + 0.5 * Foundation.sin(Double(pulsePhase))))),
                            color.opacity(0.05),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 50,
                        endRadius: 200
                    )
                )
                .scaleEffect(isActive ? 1.0 : 0.8)
                .opacity(isActive ? 1.0 : 0)
                .animation(.easeOut(duration: 0.5), value: isActive)

            // Inner warm glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(0.2),
                            color.opacity(0.1),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 100
                    )
                )
                .scaleEffect(isActive ? 1.0 : 0.5)
                .opacity(isActive ? 1.0 : 0)
                .animation(.easeOut(duration: 0.3), value: isActive)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulsePhase = .pi * 2
            }
        }
    }
}

// MARK: - Achievement Manager

@available(macOS 14.0, *)
@MainActor
class AchievementManager: ObservableObject {

    static let shared = AchievementManager()

    @Published var pendingAchievement: Achievement?
    @Published var unlockedAchievements: Set<String> = []

    private let unlockedKey = "unlockedAchievements"

    init() {
        loadUnlockedAchievements()
    }

    private func loadUnlockedAchievements() {
        if let data = UserDefaults.standard.array(forKey: unlockedKey) as? [String] {
            unlockedAchievements = Set(data)
        }
    }

    private func saveUnlockedAchievements() {
        UserDefaults.standard.set(Array(unlockedAchievements), forKey: unlockedKey)
    }

    /// Check and trigger achievements based on current stats
    func checkAchievements(
        totalRecordings: Int,
        currentStreak: Int,
        totalActionItems: Int,
        totalHours: Double
    ) {
        // First recording
        if totalRecordings >= 1 && !isUnlocked(.firstRecording) {
            unlock(.firstRecording)
            return
        }

        // Streaks (check in reverse order for highest)
        if currentStreak >= 30 && !isUnlocked(.streak30) {
            unlock(.streak30)
            return
        }
        if currentStreak >= 14 && !isUnlocked(.streak14) {
            unlock(.streak14)
            return
        }
        if currentStreak >= 7 && !isUnlocked(.streak7) {
            unlock(.streak7)
            return
        }

        // Action items
        if totalActionItems >= 100 && !isUnlocked(.actionItems100) {
            unlock(.actionItems100)
            return
        }

        // Hours transcribed
        if totalHours >= 10 && !isUnlocked(.hoursTranscribed10) {
            unlock(.hoursTranscribed10)
            return
        }
    }

    private func isUnlocked(_ type: Achievement.AchievementType) -> Bool {
        unlockedAchievements.contains(type.rawValue)
    }

    private func unlock(_ type: Achievement.AchievementType) {
        let achievement: Achievement
        switch type {
        case .firstRecording: achievement = .firstRecording
        case .streak7: achievement = .streak7
        case .streak14: achievement = .streak14
        case .streak30: achievement = .streak30
        case .actionItems100: achievement = .actionItems100
        case .hoursTranscribed10: achievement = .hoursTranscribed10
        }

        unlockedAchievements.insert(type.rawValue)
        saveUnlockedAchievements()
        pendingAchievement = achievement
    }

    func dismissAchievement() {
        pendingAchievement = nil
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview("Achievement - First Recording") {
    ZStack {
        Color.panelCharcoal
            .ignoresSafeArea()

        AchievementView(achievement: .firstRecording) {}
    }
}

@available(macOS 14.0, *)
#Preview("Achievement - 30 Day Streak") {
    ZStack {
        Color.panelCharcoal
            .ignoresSafeArea()

        AchievementView(achievement: .streak30) {}
    }
}

@available(macOS 14.0, *)
#Preview("Glow Up Effect") {
    ZStack {
        Color.panelCharcoal
            .ignoresSafeArea()

        GlowUpEffect(isActive: true, color: .recordingCoral)
    }
}
