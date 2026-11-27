import AppKit
import SwiftUI

// Who was on a meeting, drawn on the Meetings card's second row with small
// voice prints in each person's own color (the Speakers page and island
// palette, `VoicePrintStyle`). Up to three people are listed by name; a
// bigger call folds into overlapping prints and "You + 6 others". Hovering
// the stack fans the prints out (a spring, plain with Reduce Motion), and
// hovering one print names that person. Only a click opens the People
// popover; hover never does. Closed cards know only the scanned names, so a
// name is matched to a saved person to take their color; anyone else gets a
// color from their name.

// MARK: - People

/// One person on a meeting, ready to draw.
struct HomeMeetingPerson: Identifiable, Equatable {
    let name: String
    let isYou: Bool
    /// Palette index; nil for You, who draws in plain ink.
    let colorIndex: Int?
    /// The print's ring gaps.
    let style: VoicePrintStyle
    /// Meetings the saved person has been in, when they're saved.
    let meetingCount: Int?

    var id: String { name.lowercased() }

    /// The names as the card lists them, matched to saved people by name.
    static func resolve(_ names: [String], knownPeople: [SpeakerNameChoice]) -> [HomeMeetingPerson] {
        var saved: [String: SpeakerNameChoice] = [:]
        for person in knownPeople {
            let key = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if saved[key] == nil { saved[key] = person }
        }
        return names.map { name in
            let key = name.lowercased()
            if key == "you" {
                return HomeMeetingPerson(
                    name: name, isYou: true, colorIndex: nil,
                    style: VoicePrintStyle(seedString: "you"), meetingCount: nil
                )
            }
            if let match = saved[key] {
                let style = VoicePrintStyle(id: match.id)
                return HomeMeetingPerson(
                    name: name, isYou: false, colorIndex: style.preferredColorIndex,
                    style: style, meetingCount: match.callCount
                )
            }
            let style = VoicePrintStyle(seedString: key)
            return HomeMeetingPerson(name: name, isYou: false, colorIndex: style.preferredColorIndex, style: style, meetingCount: nil)
        }
    }
}

/// A person's colors on the Meetings page, light or dark window.
enum HomeMeetingPersonInk {
    /// The print's ring color.
    static func ring(_ colorIndex: Int?) -> Color {
        guard let colorIndex else { return youInk }
        return Color(nsColor: DesignTokens.dynamic(
            dark: ns(VoicePrintInk.personColor(colorIndex: colorIndex, tone: .dark)),
            light: ns(VoicePrintInk.personColor(colorIndex: colorIndex, tone: .light))
        ))
    }

    /// The same hue at a strength small text can be read in.
    static func text(_ colorIndex: Int?) -> Color {
        guard let colorIndex else { return LibraryTokens.ink }
        return Color(nsColor: DesignTokens.dynamic(
            dark: ns(SpeakerPrintTextInk.hint(colorIndex: colorIndex, dark: true)),
            light: ns(SpeakerPrintTextInk.hint(colorIndex: colorIndex, dark: false))
        ))
    }

    /// You, on the mic track: a quiet paper ink rather than a hue.
    static let youInk = Color(nsColor: DesignTokens.dynamic(
        dark: DesignTokens.rgb(0xD6D6D2),
        light: DesignTokens.rgb(0x383835)
    ))

    private static func ns(_ rgba: VoicePrintRGBA) -> NSColor {
        NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

// MARK: - Mini print

/// A small voice print: three rings (four at 20 pt and up) with the
/// person's gaps, drawn crisp in SwiftUI. `isDashed` draws the quiet,
/// unlit print of a voice nobody has named yet.
struct HomeMiniVoicePrint: View {
    let style: VoicePrintStyle
    let color: Color
    var size: CGFloat = 14
    var isDashed = false

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            if isDashed {
                for (radius, width, dash, opacity) in [(9.5, 1.85, [3.2, 2.8], 0.92), (5.0, 1.6, [2.4, 2.4], 0.58)] {
                    let rect = CGRect(x: center.x - radius * scale, y: center.y - radius * scale,
                                      width: radius * 2 * scale, height: radius * 2 * scale)
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(color.opacity(opacity)),
                        style: StrokeStyle(lineWidth: width * scale, dash: dash.map { $0 * scale })
                    )
                }
                return
            }
            let radii: [Double] = size >= 20 ? [4.2, 6.1, 8.0, 9.9] : [3.4, 6.5, 9.6]
            let lineWidth = (size >= 20 ? 1.45 : 1.75) * scale
            for (index, radius) in radii.enumerated() {
                let start = style.gapAngles[index % style.gapAngles.count]
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius * scale,
                    startAngle: .degrees(start),
                    endAngle: .degrees(start + 360 * 0.78),
                    clockwise: false
                )
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Row 2 people

/// The card's people: names for a small call, the folded stack for a big one.
struct HomeMeetingPeopleView: View {
    let people: [HomeMeetingPerson]
    /// The card is hovered or open: the stack's discs sit on its lifted fill.
    var cardIsLifted = false

    var body: some View {
        switch HomeMeetingRailPresentation.peopleLayout(people.map(\.name)) {
        case .none:
            EmptyView()
        case .list:
            HStack(spacing: 10) {
                ForEach(people) { person in
                    HStack(spacing: 5) {
                        HomeMiniVoicePrint(style: person.style, color: HomeMeetingPersonInk.ring(person.colorIndex))
                        Text(person.name)
                            .lineLimit(1)
                    }
                    .help(person.name)
                }
            }
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(people.map(\.name).joined(separator: ", ")))
        case .stack(let rings, let label):
            HomeMeetingPeopleStack(
                people: people,
                ringCount: rings.count,
                label: label,
                cardIsLifted: cardIsLifted
            )
        }
    }
}

/// Overlapping prints and "You + 6 others". Hover fans them out and names
/// each print; a click opens "People on this call".
private struct HomeMeetingPeopleStack: View {
    let people: [HomeMeetingPerson]
    let ringCount: Int
    let label: String
    let cardIsLifted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var hoveredPersonID: String?
    @State private var isShowingPeople = false

    private static let disc: CGFloat = 19
    private static let foldedSpacing: CGFloat = -7.5
    private static let fannedSpacing: CGFloat = 2.5

    private var isFanned: Bool { isHovering || isShowingPeople }

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: isFanned ? Self.fannedSpacing : Self.foldedSpacing) {
                ForEach(Array(people.prefix(ringCount).enumerated()), id: \.element.id) { index, person in
                    disc(person)
                        .zIndex(hoveredPersonID == person.id ? 10 : Double(ringCount - index))
                }
            }
            Text(label)
                .font(LibraryTokens.meta.weight(.medium))
                .foregroundStyle(isFanned ? LibraryTokens.ink : LibraryTokens.ink2)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(LibraryTokens.ink3)
                .rotationEffect(.degrees(isShowingPeople ? 180 : 0))
                .opacity(isFanned ? 0.85 : 0)
        }
        .padding(.vertical, 3)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .background(
            Capsule(style: .continuous)
                .fill(isFanned ? DesignTokens.fill : Color.clear)
        )
        .padding(.vertical, -3)
        .padding(.leading, -4)
        .padding(.trailing, -8)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            isHovering = hovering
            if !hovering { hoveredPersonID = nil }
        }
        .onTapGesture { isShowingPeople.toggle() }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: isFanned)
        .popover(isPresented: $isShowingPeople, arrowEdge: .bottom) {
            HomeMeetingPeoplePopover(people: people)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label): \(people.map(\.name).joined(separator: ", "))"))
        .accessibilityHint(Text("Shows everyone on this call"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isShowingPeople.toggle() }
        .accessibilityIdentifier("transcripted.home.meeting.people")
    }

    private func disc(_ person: HomeMeetingPerson) -> some View {
        let isHovered = hoveredPersonID == person.id
        return HomeMiniVoicePrint(
            style: person.style,
            color: HomeMeetingPersonInk.ring(person.colorIndex),
            size: Self.disc - 4
        )
        .frame(width: Self.disc, height: Self.disc)
        // The card's own fill, a little past the disc, so overlapping
        // prints read as separate coins.
        .background(
            Circle()
                .fill(cardIsLifted ? HomeMeetingCardSurface.liftedFill : HomeMeetingCardSurface.fill)
                .padding(-1.6)
        )
        .scaleEffect(isFanned ? (isHovered ? 1.16 : 1.07) : 1)
        .overlay(alignment: .top) {
            if isHovered && isFanned {
                HomeMeetingNameBadge(text: person.name, color: HomeMeetingPersonInk.text(person.colorIndex))
                    .fixedSize()
                    .offset(y: -26)
                    .transition(.opacity.combined(with: .offset(y: 3)))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Circle())
        .onHover { hovering in
            if hovering {
                hoveredPersonID = person.id
            } else if hoveredPersonID == person.id {
                hoveredPersonID = nil
            }
        }
        .help(person.name)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

/// The floating name over a hovered print: a dark pill, like the rail's.
struct HomeMeetingNameBadge: View {
    let text: String
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(HomeMeetingCardSurface.tooltipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 9, y: 4)
            .environment(\.colorScheme, .dark)
    }
}

/// "People on this call": everyone with their print, name and meetings.
private struct HomeMeetingPeoplePopover: View {
    let people: [HomeMeetingPerson]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomeMeetingRailPresentation.peoplePopoverTitle.uppercased())
                .font(LibraryTokens.label)
                .tracking(LibraryTokens.labelTracking)
                .foregroundStyle(LibraryTokens.ink3)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)
            Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(people) { person in
                        HomeMeetingPeoplePopoverRow(person: person)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(10)
        .frame(width: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(HomeMeetingRailPresentation.peoplePopoverTitle))
        .accessibilityIdentifier("transcripted.home.meeting.people.popover")
    }
}

private struct HomeMeetingPeoplePopoverRow: View {
    let person: HomeMeetingPerson
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            HomeMiniVoicePrint(style: person.style, color: HomeMeetingPersonInk.ring(person.colorIndex), size: 20)
            Text(person.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LibraryTokens.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(HomeMeetingRailPresentation.peopleRoleLine(isYou: person.isYou, meetingCount: person.meetingCount))
                .font(LibraryTokens.small)
                .foregroundStyle(LibraryTokens.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? DesignTokens.fill : Color.clear)
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}
