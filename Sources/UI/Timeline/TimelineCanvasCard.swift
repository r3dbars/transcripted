import SwiftUI

struct TimelineCanvasCard: View {
    let card: TimelineCardPresentation
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(TimelineTokens.color(for: card.category))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: card.kind.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TimelineTokens.color(for: card.category))

                        Text(timeRange)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 6)

                        Text("\(card.durationMinutes)m")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(card.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 9)
                .padding(.trailing, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
            .overlay(stroke)
            .clipShape(RoundedRectangle(cornerRadius: TimelineTokens.cardCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TimelineTokens.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.01 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel("\(card.title), \(card.kind.label), \(timeRange)")
        .accessibilityIdentifier("transcripted.timeline.card.\(card.id)")
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: TimelineTokens.cardCornerRadius, style: .continuous)
            .fill(isSelected ? TimelineTokens.selectedFill : TimelineTokens.softFill)
    }

    private var stroke: some View {
        RoundedRectangle(cornerRadius: TimelineTokens.cardCornerRadius, style: .continuous)
            .stroke(isSelected ? Color.accentColor.opacity(0.42) : TimelineTokens.quietStroke, lineWidth: 1)
    }

    private var timeRange: String {
        "\(Self.timeFormatter.string(from: card.start))-\(Self.timeFormatter.string(from: card.end))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()
}
