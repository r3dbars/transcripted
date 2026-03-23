import SwiftUI

/// Welcome step - Value proposition with benefit cards
/// Dark theme matching the floating pill aesthetic
@available(macOS 26.0, *)
struct WelcomeStep: View {
    @State private var showContent = false

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.recordingCoral)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: Spacing.xs) {
                Text("Welcome to Transcripted")
                    .font(.displayLarge)
                    .foregroundColor(.panelTextPrimary)

                Text("Private, local meeting transcription")
                    .font(.bodyLarge)
                    .foregroundColor(.panelTextSecondary)
            }

            VStack(spacing: Spacing.sm) {
                BenefitCard(
                    icon: "waveform",
                    iconColor: .recordingCoral,
                    title: "Transcribe Meetings",
                    description: "Record any conversation and get accurate text, locally on your Mac"
                )

                BenefitCard(
                    icon: "person.2.fill",
                    iconColor: .processingPurple,
                    title: "Identify Speakers",
                    description: "Know who said what with automatic speaker labels"
                )

                BenefitCard(
                    icon: "lock.shield.fill",
                    iconColor: .attentionGreen,
                    title: "Completely Private",
                    description: "Everything stays on your Mac. No cloud, no data leaves your device"
                )
            }
            .padding(.horizontal, Spacing.md)

            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .opacity(showContent ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                showContent = true
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    WelcomeStep()
        .frame(width: 640, height: 560)
        .background(Color.panelCharcoal)
}
#endif
