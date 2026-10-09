// SpeakerPeoplePrintSections.swift
// The saved people in Settings › Speakers, grouped by their voice print:
// "Named automatically · N" (full, glowing prints, with a glowing dot per
// person in the header), "Still learning" (partial prints), then any unnamed
// voices outside the open review card. Grouping and copy come from
// SpeakerPrintDirectory (Foundation-pure, tested); each row is SpeakerPersonRow.

import SwiftUI
import TranscriptedCore

struct SpeakerPrintSectionsView: View {
    /// Already searched and sorted (`SpeakerPeopleSettingsViewModel.directoryProfiles`).
    let profiles: [SpeakerProfile]
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @Binding var expandedPersonID: UUID?

    var body: some View {
        let sections = SpeakerPrintDirectory.sections(profiles) { model.namingStanding(for: $0) }
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections, id: \.section) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    SpeakerPrintSectionHeader(section: entry.section, members: entry.items)
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.items, id: \.id) { profile in
                            SpeakerPersonRow(profile: profile, model: model, expandedPersonID: $expandedPersonID)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct SpeakerPrintSectionHeader: View {
    let section: SpeakerPrintDirectory.Section
    let members: [SpeakerProfile]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if section == .namedAutomatically {
                HStack(spacing: 6) {
                    ForEach(members.prefix(SpeakerPrintDirectory.maximumHeaderDots), id: \.id) { profile in
                        let color = SpeakerPrintInk.color(for: profile.id, colorScheme: colorScheme)
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                            // Only dark surfaces glow, like the prints.
                            .shadow(color: colorScheme == .dark ? color.opacity(0.6) : .clear, radius: 3)
                    }
                }
                .accessibilityHidden(true)
            }

            Text(SpeakerPrintDirectory.title(section, count: members.count))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LibraryTokens.ink2)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, 6)
    }
}

/// A saved person's print color in Settings, where everyone keeps their own
/// preferred color (no per-call de-duplication): the palette's dark hex on a
/// dark window, its light hex on a light one.
enum SpeakerPrintInk {
    static func color(for id: UUID, colorScheme: ColorScheme) -> Color {
        let ink = VoicePrintInk.personColor(
            colorIndex: VoicePrintStyle(id: id).preferredColorIndex,
            tone: colorScheme == .dark ? .dark : .light
        )
        return Color(.sRGB, red: ink.red, green: ink.green, blue: ink.blue, opacity: ink.alpha)
    }

    /// The same hue for small text ("One more yes"): darker on a light window
    /// so it reads at 4.5:1 (`SpeakerPrintTextInk`, tested).
    static func hintColor(for id: UUID, colorScheme: ColorScheme) -> Color {
        let ink = SpeakerPrintTextInk.hint(
            colorIndex: VoicePrintStyle(id: id).preferredColorIndex,
            dark: colorScheme == .dark
        )
        return Color(.sRGB, red: ink.red, green: ink.green, blue: ink.blue, opacity: ink.alpha)
    }
}
