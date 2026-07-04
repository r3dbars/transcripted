import SwiftUI

struct TimelineDetailPanel: View {
    let card: TimelineCardPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let card {
                header(for: card)

                Text(card.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !card.decisions.isEmpty {
                    detailGroup(title: "Decisions", values: card.decisions, symbolName: "checkmark.circle.fill")
                }

                if !card.appSites.isEmpty {
                    detailGroup(title: "Apps", values: card.appSites, symbolName: "app.fill")
                }
            } else {
                emptyState
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: TimelineTokens.panelCornerRadius, style: .continuous)
                .fill(TimelineTokens.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TimelineTokens.panelCornerRadius, style: .continuous)
                .stroke(TimelineTokens.quietStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("transcripted.timeline.detail")
    }

    private func header(for card: TimelineCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: card.kind.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TimelineTokens.color(for: card.category))

                Text(card.kind.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                TimelineTokens.categoryLabel(card.category)
            }

            Text(card.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(timeFormatter.string(from: card.start))-\(timeFormatter.string(from: card.end))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func detailGroup(title: String, values: [String], symbolName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Select a card")
                .font(.headline)
            Text("Timeline details stay here, without taking over the home screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
