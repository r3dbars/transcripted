import SwiftUI

/// Welcome step - Value proposition with benefit cards
/// Combines welcome + how it works into a single compelling screen
@available(macOS 26.0, *)
struct WelcomeStep: View {
    @State private var showContent = false
    @State private var showCards = [false, false, false]

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer()

            // App Icon with subtle glow
            ZStack {
                Circle()
                    .fill(Color.terracotta.opacity(0.15))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.terracotta, Color.terracotta.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolRenderingMode(.hierarchical)
            }
            .scaleEffect(showContent ? 1.0 : 0.8)
            .opacity(showContent ? 1 : 0)

            // Welcome text
            VStack(spacing: Spacing.xs) {
                Text("Welcome to Transcripted")
                    .font(.displayLarge)
                    .foregroundColor(.charcoal)

                Text("Private, local meeting transcription")
                    .font(.bodyLarge)
                    .foregroundColor(.softCharcoal)
            }
            .opacity(showContent ? 1 : 0)
            .offset(y: showContent ? 0 : 10)

            // Benefit cards
            VStack(spacing: Spacing.sm) {
                BenefitCard(
                    icon: "waveform",
                    iconColor: .terracotta,
                    title: "Transcribe Meetings",
                    description: "Record any conversation and get accurate text, locally on your Mac"
                )
                .opacity(showCards[0] ? 1 : 0)
                .offset(y: showCards[0] ? 0 : 12)

                BenefitCard(
                    icon: "person.2.fill",
                    iconColor: .processingPurple,
                    title: "Identify Speakers",
                    description: "Know who said what with automatic speaker labels"
                )
                .opacity(showCards[1] ? 1 : 0)
                .offset(y: showCards[1] ? 0 : 12)

                BenefitCard(
                    icon: "lock.shield.fill",
                    iconColor: .successGreen,
                    title: "Completely Private",
                    description: "Everything stays on your Mac. No cloud, no data leaves your device"
                )
                .opacity(showCards[2] ? 1 : 0)
                .offset(y: showCards[2] ? 0 : 12)
            }
            .padding(.horizontal, Spacing.md)

            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .onAppear {
            withAnimation(.smooth.delay(0.1)) {
                showContent = true
            }
            // Staggered card animations
            for i in 0..<3 {
                withAnimation(.smooth.delay(0.3 + Double(i) * 0.12)) {
                    showCards[i] = true
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    WelcomeStep()
        .frame(width: 720, height: 680)
        .background(Color.cream)
}
#endif
