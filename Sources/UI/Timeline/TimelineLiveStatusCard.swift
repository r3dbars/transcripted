import SwiftUI

struct TimelineLiveStatusCard: View {
    enum State {
        case generating
        case paused
        case ready

        var title: String {
            switch self {
            case .generating: return "Timeline is generating"
            case .paused: return "Timeline capture is paused"
            case .ready: return "Timeline preview"
            }
        }

        var detail: String {
            switch self {
            case .generating: return "Mock cards are standing in until the local analysis backend lands."
            case .paused: return "Screen capture will stay opt-in before this becomes the default Home."
            case .ready: return "UI-only preview, gated by a debug flag."
            }
        }

        var symbolName: String {
            switch self {
            case .generating: return "sparkles"
            case .paused: return "pause.circle.fill"
            case .ready: return "rectangle.stack.fill"
            }
        }
    }

    let state: State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .background(TimelineTokens.insetFill, in: RoundedRectangle(cornerRadius: TimelineTokens.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TimelineTokens.panelCornerRadius, style: .continuous)
                .stroke(TimelineTokens.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("transcripted.timeline.live-status")
    }
}
