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
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                statusCluster
                    .glassEffect(.regular.interactive(), in: .rect(corners: .concentric(minimum: .fixed(14)), isUniform: true))
                    .glassEffectID("status", in: glassNamespace)

                ExperimentalListeningLevelView(level: model.audioLevel)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: .rect(corners: .concentric(minimum: .fixed(14)), isUniform: true))
                    .glassEffectID("meter", in: glassNamespace)

                Button(action: model.onStopRequested) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
                .tint(Color(nsColor: OverlayTokens.warningColor))
                .glassEffectID("stop", in: glassNamespace)
                .help("Stop dictation")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.clear)
    }

    private var statusCluster: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Listening")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Circle()
                .fill(Color(nsColor: OverlayTokens.accentColor))
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ExperimentalListeningLevelView: View {
    let level: CGFloat

    private let multipliers: [CGFloat] = [0.76, 1.0, 0.84, 1.08]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(multipliers.enumerated()), id: \.offset) { _, multiplier in
                let normalized = max(0.16, min(1.0, level * multiplier + 0.06))

                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.primary.opacity(0.28 + normalized * 0.34))
                    .frame(width: 3, height: 8 + normalized * 10)
            }
        }
        .frame(width: 24, alignment: .center)
        .animation(.easeInOut(duration: 0.16), value: level)
    }
}
