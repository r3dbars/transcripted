import SwiftUI

/// Preview step - Shows a realistic sample transcript to deliver the "aha moment"
/// Dark theme with staggered line reveal
@available(macOS 26.0, *)
struct PreviewStep: View {
    @State private var showContent = false
    @State private var visibleLines: Int = 0

    private let transcriptLines: [(timestamp: String, speaker: String, color: Color, text: String)] = [
        ("0:00", "Sarah", .recordingCoral, "Alright, let's kick off the standup. What did everyone work on yesterday?"),
        ("0:05", "Mike", .processingPurple, "I finished the API integration — all tests passing now."),
        ("0:12", "Sarah", .recordingCoral, "Nice. Any blockers on the frontend side?"),
        ("0:16", "Mike", .processingPurple, "Just waiting on the design specs for the settings page."),
        ("0:22", "Sarah", .recordingCoral, "I'll ping design after this. Let's move on to sprint goals."),
        ("0:28", "Mike", .processingPurple, "Sounds good. I can pick up the notification work today."),
    ]

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer()

            VStack(spacing: Spacing.xs) {
                Image(systemName: "text.quote")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.recordingCoral)
                    .symbolRenderingMode(.hierarchical)

                Text("Here's what your meetings will look like")
                    .font(.displayLarge)
                    .foregroundColor(.panelTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Transcripted turns conversations into searchable text")
                    .font(.bodyLarge)
                    .foregroundColor(.panelTextSecondary)
            }
            .opacity(showContent ? 1 : 0)

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
                    .fill(Color.panelCharcoalElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
            )
            .padding(.horizontal, Spacing.md)

            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                showContent = true
            }
            for i in 0..<transcriptLines.count {
                withAnimation(.easeInOut.delay(0.3 + Double(i) * 0.2)) {
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
                .foregroundColor(.panelTextMuted)
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
                    .foregroundColor(.panelTextPrimary)
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
        .frame(width: 640, height: 560)
        .background(Color.panelCharcoal)
}
#endif
