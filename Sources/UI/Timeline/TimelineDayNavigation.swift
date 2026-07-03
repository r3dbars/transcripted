import SwiftUI

struct TimelineDayNavigation: View {
    let selectedDay: Date
    let onPreviousDay: () -> Void
    let onToday: () -> Void
    let onNextDay: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPreviousDay) {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(TimelineIconButtonStyle())
            .help("Previous day")

            VStack(alignment: .leading, spacing: 1) {
                Text(dayTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(daySubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 132, alignment: .leading)

            Button(action: onNextDay) {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(TimelineIconButtonStyle())
            .help("Next day")

            Button(action: onToday) {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
            }
            .buttonStyle(TimelineCapsuleButtonStyle())

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("transcripted.timeline.day-navigation")
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(selectedDay) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(selectedDay) {
            return "Yesterday"
        }
        return Self.titleFormatter.string(from: selectedDay)
    }

    private var daySubtitle: String {
        Self.subtitleFormatter.string(from: selectedDay)
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let subtitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

private struct TimelineIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(0.82))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.10) : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TimelineTokens.hairline, lineWidth: 1)
            )
    }
}

private struct TimelineCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(0.86))
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.11) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(TimelineTokens.hairline, lineWidth: 1)
            )
    }
}
