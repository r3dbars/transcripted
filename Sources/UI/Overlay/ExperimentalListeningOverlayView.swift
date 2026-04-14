import AppKit
import SwiftUI

@MainActor
final class ExperimentalListeningOverlayModel: ObservableObject {
    @Published var audioLevel: CGFloat = 0
    var onStopRequested: () -> Void = {}
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

struct ExperimentalListeningOverlayView: View {
    @ObservedObject var model: ExperimentalListeningOverlayModel

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: OverlayTokens.accentColor))

                    Text("Listening")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    ExperimentalListeningLevelView(level: model.audioLevel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(
                    .regular
                        .tint(Color(nsColor: OverlayTokens.accentColor).opacity(0.18))
                        .interactive(),
                    in: Capsule()
                )

                Button(action: model.onStopRequested) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(Color(nsColor: OverlayTokens.warningColor))
                .help("Stop dictation")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.clear)
    }
}

private struct ExperimentalListeningLevelView: View {
    let level: CGFloat

    private let multipliers: [CGFloat] = [0.72, 1.0, 0.86, 1.12, 0.78]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(multipliers.enumerated()), id: \.offset) { _, multiplier in
                let normalized = max(0.18, min(1.0, level * multiplier + 0.08))

                Capsule()
                    .fill(.primary.opacity(0.24 + normalized * 0.42))
                    .frame(width: 4, height: 8 + normalized * 12)
            }
        }
        .frame(width: 38, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: level)
    }
}
