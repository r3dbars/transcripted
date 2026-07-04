import SwiftUI

struct TimelineHomeView: View {
    @State private var selectedDay: Date
    @State private var cards: [TimelineCardPresentation]
    @State private var selectedCardID: TimelineCardPresentation.ID?

    init(
        selectedDay: Date = Date(),
        cards: [TimelineCardPresentation]? = nil
    ) {
        let sampleCards = cards ?? TimelineHomeSampleData.cards(now: selectedDay)
        _selectedDay = State(initialValue: selectedDay)
        _cards = State(initialValue: sampleCards)
        _selectedCardID = State(initialValue: sampleCards.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            TimelineLiveStatusCard(state: .ready)

            HStack(alignment: .top, spacing: 16) {
                timelineCanvas
                    .frame(minWidth: 430, idealWidth: 560, maxWidth: .infinity, alignment: .topLeading)

                TimelineDetailPanel(card: selectedCard)
                    .frame(width: 260, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transcripted.timeline.home")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Timeline")
                        .font(.system(size: 28, weight: .semibold))
                    Text("A preview of meetings, dictations, and activity in one day.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                TimelineDayNavigation(
                    selectedDay: selectedDay,
                    onPreviousDay: { moveDay(by: -1) },
                    onToday: { setDay(Date()) },
                    onNextDay: { moveDay(by: 1) }
                )
                .frame(width: 310)
            }

            HStack(spacing: 10) {
                stat("\(cards.count)", "cards")
                stat(totalDurationText, "captured")
                stat("4 AM", "day boundary")
            }
        }
        .padding(.top, 8)
    }

    private var timelineCanvas: some View {
        let layout = TimelineCanvasLayout(
            day: selectedDay,
            pixelsPerHour: TimelineTokens.canvasPixelsPerHour
        )

        return HStack(alignment: .top, spacing: 12) {
            TimelineHourRail(layout: layout)
                .frame(width: 44, height: layout.height, alignment: .top)

            ZStack(alignment: .topLeading) {
                TimelineCanvasGrid(layout: layout)

                ForEach(cards) { card in
                    TimelineCanvasCard(
                        card: card,
                        isSelected: selectedCardID == card.id,
                        action: { selectedCardID = card.id }
                    )
                    .frame(height: layout.height(for: card))
                    .offset(y: layout.yOffset(for: card.start))
                }
            }
            .frame(height: layout.height, alignment: .topLeading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: TimelineTokens.panelCornerRadius, style: .continuous)
                .fill(TimelineTokens.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TimelineTokens.panelCornerRadius, style: .continuous)
                .stroke(TimelineTokens.quietStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("transcripted.timeline.canvas")
    }

    private var selectedCard: TimelineCardPresentation? {
        guard let selectedCardID else { return cards.first }
        return cards.first { $0.id == selectedCardID } ?? cards.first
    }

    private var totalDurationText: String {
        let minutes = cards.reduce(0) { $0 + $1.durationMinutes }
        let hours = minutes / 60
        let remainder = minutes % 60
        guard hours > 0 else { return "\(minutes)m" }
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.9))
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private func moveDay(by days: Int) {
        let nextDay = Calendar.current.date(byAdding: .day, value: days, to: selectedDay) ?? selectedDay
        setDay(nextDay)
    }

    private func setDay(_ day: Date) {
        selectedDay = day
        cards = TimelineHomeSampleData.cards(now: day)
        selectedCardID = cards.first?.id
    }
}

private struct TimelineHourRail: View {
    let layout: TimelineCanvasLayout

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(0...24, id: \.self) { hour in
                Text(label(for: hour))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .offset(y: CGFloat(hour) * layout.pixelsPerHour - 6)
            }
        }
    }

    private func label(for hour: Int) -> String {
        let value = (4 + hour) % 24
        if value == 0 { return "12a" }
        if value < 12 { return "\(value)a" }
        if value == 12 { return "12p" }
        return "\(value - 12)p"
    }
}

private struct TimelineCanvasGrid: View {
    let layout: TimelineCanvasLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { hour in
                Rectangle()
                    .fill(hour % 4 == 0 ? Color.primary.opacity(0.08) : Color.primary.opacity(0.045))
                    .frame(height: 1)
                    .offset(y: CGFloat(hour) * layout.pixelsPerHour)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        TimelineHomeView()
            .padding(28)
            .frame(width: 860)
    }
}
#endif
