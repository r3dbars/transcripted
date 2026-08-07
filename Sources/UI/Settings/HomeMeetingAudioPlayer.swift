import AppKit
import SwiftUI

// Meeting-audio player components shared by the Home inline expansion.
// Extracted from HomeMeetingPreviewSheet.swift when the preview sheet was
// retired (quiet-library redesign): the expansion replaced the sheet, but
// the player and the speaker color palette remain shared UI.

struct HomeMeetingPodcastPlayer: View {
    let audio: MeetingAudioAttachment

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var selectedPlaybackChoiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meeting audio")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        Text(playback.compactTimeLabel(for: audio))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    MeetingAudioSourceMenu(
                        attachment: audio,
                        selectedChoiceID: selectedPlaybackChoiceBinding
                    ) { choice in
                        if playback.isActive(audio) {
                            playback.switchSource(audio, choice: choice)
                        }
                    }
                }

                HStack(spacing: 14) {
                    HomePodcastPlayerButton(
                        symbolName: "gobackward.15",
                        size: 34,
                        isPrimary: false,
                        isDisabled: !canSeek,
                        help: "Skip back 15 seconds",
                        automationIdentifier: "transcripted.home.meeting-preview.audio.skip-back"
                    ) {
                        playback.skip(audio, by: -15)
                    }

                    HomePodcastPlayerButton(
                        symbolName: playback.symbolName(for: audio, choice: selectedPlaybackChoice),
                        size: 46,
                        isPrimary: playback.isActive(audio, choice: selectedPlaybackChoice),
                        isDisabled: false,
                        help: "\(playback.buttonTitle(for: audio, choice: selectedPlaybackChoice)) meeting audio",
                        automationIdentifier: "transcripted.home.meeting-preview.audio.toggle"
                    ) {
                        playback.toggle(audio, choice: selectedPlaybackChoice)
                    }

                    HomePodcastPlayerButton(
                        symbolName: "goforward.15",
                        size: 34,
                        isPrimary: false,
                        isDisabled: !canSeek,
                        help: "Skip forward 15 seconds",
                        automationIdentifier: "transcripted.home.meeting-preview.audio.skip-forward"
                    ) {
                        playback.skip(audio, by: 15)
                    }
                }
            }

            MeetingAudioScrubber(
                attachment: audio,
                width: nil,
                showsTime: false
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    private var canSeek: Bool {
        playback.isActive(audio) && playback.duration > 0
    }

    private var selectedPlaybackChoice: MeetingAudioPlaybackChoice? {
        playback.activeChoice(for: audio) ?? audio.playbackChoice(id: selectedPlaybackChoiceID)
    }

    private var selectedPlaybackChoiceBinding: Binding<String?> {
        Binding(
            get: { selectedPlaybackChoice?.id },
            set: { selectedPlaybackChoiceID = $0 }
        )
    }
}

private struct HomePodcastPlayerButton: View {
    let symbolName: String
    let size: CGFloat
    let isPrimary: Bool
    let isDisabled: Bool
    let help: String
    let automationIdentifier: String
    let action: () -> Void

    private var hitTargetSize: CGFloat {
        max(size, HomeHitTarget.minimum)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(isPrimary ? 0.0 : 0.08), lineWidth: 1)
                    )

                Image(systemName: symbolName)
                    .font(.system(size: size >= 40 ? 15 : 12, weight: .bold))
                    .foregroundStyle(foreground)
                    .frame(width: size, height: size)
            }
            .frame(width: hitTargetSize, height: hitTargetSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier(automationIdentifier)
    }

    private var foreground: Color {
        if isPrimary { return .white }
        return .secondary
    }

    private var background: Color {
        if isPrimary { return Color.accentColor }
        return Color.primary.opacity(0.08)
    }
}

enum HomeMeetingSpeakerColor {
    static func color(for speaker: String) -> Color {
        let palette: [NSColor] = [
            .systemBlue,
            .systemGreen,
            .systemPurple,
            .systemOrange,
            .systemPink,
            .systemTeal,
            .systemRed,
            .systemIndigo,
        ]

        let index = HomeMeetingSpeakerPalette.slotIndex(for: speaker, slotCount: palette.count)
        return Color(nsColor: palette[index])
    }
}
