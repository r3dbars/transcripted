import SwiftUI

/// Welcome step - Simple, clean first impression
/// Logo + Welcome + one tagline - nothing more
@available(macOS 26.0, *)
struct WelcomeStep: View {
    @State private var showContent = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            // App Icon with subtle glow
            ZStack {
                Circle()
                    .fill(Color.terracotta.opacity(0.15))
                    .frame(width: 140, height: 140)
                    .blur(radius: 25)

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 80))
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
            Text("Welcome to Transcripted")
                .font(.displayLarge)
                .foregroundColor(.charcoal)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 10)

            // Single tagline
            Text("Never miss a word")
                .font(.headingMedium)
                .foregroundColor(.softCharcoal)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 8)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Spacing.xxl)
        .onAppear {
            withAnimation(.smooth.delay(0.1)) {
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
        .frame(width: 720, height: 680)
        .background(Color.cream)
}
#endif
