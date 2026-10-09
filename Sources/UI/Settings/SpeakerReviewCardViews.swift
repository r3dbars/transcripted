// SpeakerReviewCardViews.swift
// Pieces of Settings › Speakers' "Review and name these people" stack, drawn
// with voice prints like the island's review:
//   - SpeakerReviewSummaryCard: the closed stack ("3 voices to name", Review);
//   - SpeakerNameChipButton: a one-tap name; someone already saved shows their
//     small print and "4 of 5", since picking them is a yes for them;
//   - SpeakerReviewNamedRow: a voice just named on the card, whose print plays
//     the match animation (VoicePrintView.celebrate) up to its new ring count,
//     with the island's line under the name once the print lands;
//   - SpeakerReviewDoneFooter: "Weekly sync is done · 2 voices named" + Next call.
// Copy and ring counts: SpeakerReviewCardProgress (Foundation-pure, tested).

import SwiftUI
import TranscriptedCore

// MARK: - Summary (closed stack)

struct SpeakerReviewSummaryCard: View {
    let calls: [SpeakerPendingMeetingGroup]
    let onReview: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var voices: [SpeakerPendingVoiceGroup] { calls.flatMap(\.voices) }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: -10) {
                ForEach(Array(voices.prefix(3).enumerated()), id: \.element.id) { _, voice in
                    VoicePrintRepresentable(
                        model: VoicePrintView.Model(
                            style: VoicePrintStyle(id: voice.id),
                            colorIndex: VoicePrintStyle(id: voice.id).preferredColorIndex,
                            litRings: 0,
                            surface: colorScheme == .dark ? .settingsDark : .settingsLight
                        ),
                        diameter: 30
                    )
                    .frame(width: 30, height: 30)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(SpeakerReviewCardProgress.summaryTitle(voiceCount: voices.count))
                    .font(.system(size: 14, weight: .semibold))
                if let source = SpeakerReviewCardProgress.summarySource(callTitles: calls.map(\.meetingTitle)) {
                    Text(source)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button("Review", action: onReview)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("transcripted.speakers.review.open")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

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

// MARK: - A voice just named

struct SpeakerReviewNamedRow: View {
    let voice: SpeakerReviewNamedVoice
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @ObservedObject private var playback = SpeakerClipPlayback.shared

    @Environment(\.colorScheme) private var colorScheme
    @State private var litRings: Int
    @State private var celebrateToken = 0
    @State private var showsHint = false

    static let printDiameter: CGFloat = 36

    init(voice: SpeakerReviewNamedVoice, model: SpeakerPeopleSettingsViewModel) {
        self.voice = voice
        self.model = model
        _litRings = State(initialValue: SpeakerReviewCardProgress.litRingsBefore(voice))
    }

    var body: some View {
        let style = VoicePrintStyle(id: voice.personID)
        let clipURL = model.clipURL(for: voice.personID)
        HStack(spacing: 14) {
            VoicePrintRepresentable(
                model: VoicePrintView.Model(
                    style: style,
                    colorIndex: style.preferredColorIndex,
                    litRings: litRings,
                    surface: colorScheme == .dark ? .settingsDark : .settingsLight
                ),
                diameter: Self.printDiameter,
                isPlaying: clipURL.map(playback.isPlaying) ?? false,
                accessibilityName: voice.name,
                celebrateToken: celebrateToken,
                onPlay: clipURL == nil ? nil : { model.playSample(for: voice.personID) }
            )
            .frame(width: Self.printDiameter, height: Self.printDiameter)

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let hint = SpeakerReviewCardProgress.hint(voice) {
                    Text(hint.text)
                        .font(LibraryTokens.meta.weight(.medium))
                        .foregroundStyle(hint.usesPersonColor
                            ? SpeakerPrintInk.hintColor(for: voice.personID, colorScheme: colorScheme)
                            : LibraryTokens.ink2)
                        .opacity(showsHint ? 1 : 0)
                        .offset(y: showsHint ? 0 : 3)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .onAppear(perform: celebrate)
    }

    /// Lights the earned ring with the island's match animation, then shows
    /// the line under the name once the print has landed.
    private func celebrate() {
        let reduceMotion = AccessibilityDisplayPolicy.reduceMotion
        DispatchQueue.main.async {
            litRings = SpeakerReviewCardProgress.litRingsAfter(voice)
            celebrateToken += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : VoicePrintCascadePlan.landedDelay)) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { showsHint = true }
        }
    }
}

// MARK: - Done

struct SpeakerReviewDoneFooter: View {
    let callTitle: String
    let namedCount: Int
    let callsAfterThis: Int
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(LibraryTokens.ink2)
                .accessibilityHidden(true)
            Text(SpeakerReviewCardProgress.doneLine(callTitle: callTitle, namedCount: namedCount))
                .font(LibraryTokens.body)
                .foregroundStyle(LibraryTokens.ink2)
            Spacer(minLength: 8)
            Button(SpeakerReviewCardProgress.nextTitle(callsAfterThis: callsAfterThis), action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("transcripted.speakers.call-review.next")
        }
        .padding(.top, 10)
    }
}
