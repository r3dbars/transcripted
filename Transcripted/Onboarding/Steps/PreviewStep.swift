import SwiftUI

/// Preview step - Shows a realistic sample transcript to deliver the "aha moment"
/// before asking for permissions. Animated lines appear one by one.
@available(macOS 26.0, *)
struct PreviewStep: View {
    @State private var showHeader = false
    @State private var visibleLines: Int = 0

    private let transcriptLines: [(timestamp: String, speaker: String, color: Color, text: String)] = [
        ("0:00", "Sarah", .terracotta, "Alright, let's kick off the standup. What did everyone work on yesterday?"),
        ("0:05", "Mike", .processingPurple, "I finished the API integration — all tests passing now."),
        ("0:12", "Sarah", .terracotta, "Nice. Any blockers on the frontend side?"),
        ("0:16", "Mike", .processingPurple, "Just waiting on the design specs for the settings page."),
        ("0:22", "Sarah", .terracotta, "I'll ping design after this. Let's move on to sprint goals."),
        ("0:28", "Mike", .processingPurple, "Sounds good. I can pick up the notification work today."),
    ]

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer()

            // Header
            VStack(spacing: Spacing.xs) {
                Image(systemName: "text.quote")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.terracotta)
                    .symbolRenderingMode(.hierarchical)

                Text("Here's what your meetings will look like")
                    .font(.displayLarge)
                    .foregroundColor(.charcoal)
                    .multilineTextAlignment(.center)

                Text("Transcripted turns conversations into searchable text")
                    .font(.bodyLarge)
                    .foregroundColor(.softCharcoal)
            }
            .opacity(showHeader ? 1 : 0)
            .offset(y: showHeader ? 0 : 10)

            // Sample transcript
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(0..<transcriptLines.count, id: \.self) { index in
                    if index < visibleLines {
                        TranscriptLineView(
                            timestamp: transcriptLines[index].timestamp,
                            speaker: transcriptLines[index].speaker,
                            color: transcriptLines[index].color,
                            text: transcriptLines[index].text
                        )
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(Color.warmCream)
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            )
            .padding(.horizontal, Spacing.md)

            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .onAppear {
            withAnimation(.smooth.delay(0.1)) {
                showHeader = true
            }
            // Staggered line animations
            for i in 0..<transcriptLines.count {
                withAnimation(.smooth.delay(0.4 + Double(i) * 0.3)) {
                    visibleLines = i + 1
                }
            }
        }
    }
}

// MARK: - Transcript Line View

@available(macOS 26.0, *)
private struct TranscriptLineView: View {
    let timestamp: String
    let speaker: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(timestamp)
                .font(.caption)
                .foregroundColor(.softCharcoal.opacity(0.5))
                .frame(width: 32, alignment: .trailing)
                .monospacedDigit()

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(speaker)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)

                Text(text)
                    .font(.body)
                    .foregroundColor(.charcoal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    PreviewStep()
        .frame(width: 720, height: 680)
        .background(Color.cream)
}
#endif
