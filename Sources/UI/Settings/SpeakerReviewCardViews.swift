// SpeakerReviewCardViews.swift
// SpeakerNameChipButton: a one-tap name on Speakers' voice rows; someone
// already saved shows their small print and "4 of 5", since picking them is a
// yes for them. The "Who spoke?" cards themselves are SpeakerWhoSpokeCards.

import SwiftUI
import TranscriptedCore

// MARK: - One-tap names

/// A name offered on a voice: a calendar invitee, someone already saved, or
/// both. `person` is set when the name is exactly one saved person.
struct SpeakerNameChip: Identifiable {
    let name: String
    let person: SpeakerProfile?
    let standing: SpeakerNamingStanding?
    /// Shown as "on the calendar invite" in the tooltip.
    let isInvitee: Bool

    var id: String { person.map { $0.id.uuidString } ?? "invitee:\(name)" }

    /// "4 of 5" for someone still learning; nothing once they're named on
    /// their own, or for a name nobody has saved.
    var progressNote: String? {
        guard let standing, standing.tier != .auto else { return nil }
        return "\(standing.confirmedMeetings) of \(standing.requiredMeetings)"
    }
}

struct SpeakerNameChipButton: View {
    let chip: SpeakerNameChip
    var isDisabled = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let person = chip.person {
                    let style = VoicePrintStyle(id: person.id)
                    VoicePrintRepresentable(
                        model: VoicePrintView.Model(
                            style: style,
                            colorIndex: style.preferredColorIndex,
                            litRings: litRings,
                            surface: colorScheme == .dark ? .settingsDark : .settingsLight
                        ),
                        diameter: 18
                    )
                    .frame(width: 18, height: 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Text(chip.name)
                if let note = chip.progressNote {
                    Text(note)
                        .foregroundStyle(LibraryTokens.ink3)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var litRings: Int {
        guard let standing = chip.standing else { return 0 }
        return SpeakerNamingTierPresentation.filledSegments(
            confirmed: standing.confirmedMeetings,
            required: standing.requiredMeetings,
            tier: standing.tier
        )
    }

    private var helpText: String {
        if chip.person != nil {
            return "Picking \(chip.name) counts as a yes for them."
        }
        return chip.isInvitee ? "\(chip.name) was on the calendar invite." : chip.name
    }

    private var accessibilityText: String {
        guard let note = chip.progressNote else { return chip.name }
        return "\(chip.name), \(note) meetings confirmed"
    }
}
