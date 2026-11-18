import AppKit
import SwiftUI

// Meeting-audio controls for the Meetings card bar, built like the
// Dictations card (`DictationPlaybackBar.swift`): a small round play button,
// and while that meeting's audio is open, current time · scrubber · total and
// the source picker (Mix, You, Others) when the meeting kept split tracks.
// There is no separate player block any more; playback still runs through
// `MeetingAudioPlayback.shared`, and transcript times still play from there.

/// The card bar's round play/pause: drawn at 22 pt, hit at 40 pt. Green
/// while it plays (played audio is "live"), quiet fill at rest.
struct HomeMeetingPlayButton: View {
    let audio: MeetingAudioAttachment
    var automationIdentifier = "transcripted.home.meeting.play"

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private let size: CGFloat = 22

    private var hitTargetSize: CGFloat {
        HomeHitTarget.hitSize(forVisibleSize: size)
    }

    private var selectedChoice: MeetingAudioPlaybackChoice? {
        playback.activeChoice(for: audio) ?? playback.preferredChoice(for: audio)
    }

    private var isPlaying: Bool {
        playback.isActive(audio) && playback.isPlaying
    }

    private var isUnavailable: Bool {
        playback.isUnavailable(audio, choice: selectedChoice)
    }

    private var help: String {
        if isUnavailable { return "This meeting's audio couldn't be played" }
        return isPlaying ? "Pause" : "Play meeting"
    }

    var body: some View {
        Button {
            playback.toggle(audio, choice: selectedChoice)
        } label: {
            ZStack {
                Circle()
                    .fill(isPlaying ? LibraryTokens.accent : (isHovering ? DesignTokens.hairlineStrong : DesignTokens.fillStrong))
                Image(systemName: isUnavailable ? "exclamationmark" : (isPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 8.5, weight: .bold))
                    .offset(x: isPlaying || isUnavailable ? 0 : 0.5)
                    .foregroundStyle(isPlaying ? DesignTokens.paper : (isUnavailable ? LibraryTokens.attention : LibraryTokens.ink))
            }
            .frame(width: size, height: size)
            .frame(width: hitTargetSize, height: hitTargetSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The 40 pt hit shape overhangs the bar instead of growing it.
        .padding(-(hitTargetSize - size) / 2)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isPlaying)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier(automationIdentifier)
    }
}

/// Current time · scrubber · total · source, shown in the bar while this
/// meeting's audio is open (playing or paused). Rows never follow the
/// playhead; only this bar moves.
struct HomeMeetingInlinePlayer: View {
    let audio: MeetingAudioAttachment

    static let trackWidth: CGFloat = 110

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var dragFraction: Double?

    var body: some View {
        if playback.isActive(audio) {
            let fraction = dragFraction ?? playback.progress(for: audio)
            HStack(spacing: 7) {
                Text(MeetingAudioPlayback.clockText(fraction * playback.duration))
                    .foregroundStyle(LibraryTokens.accent)
                    .frame(minWidth: 28, alignment: .trailing)
                track(fraction: fraction)
                Text(MeetingAudioPlayback.clockText(playback.duration))
                MeetingAudioSourceMenu(
                    attachment: audio,
                    selectedChoiceID: selectedChoiceBinding
                ) { choice in
                    playback.switchSource(audio, choice: choice)
                }
            }
            .font(LibraryTokens.meta)
            .monospacedDigit()
            .foregroundStyle(LibraryTokens.ink3)
            .lineLimit(1)
            .transition(.opacity)
        }
    }

    private var selectedChoiceBinding: Binding<String?> {
        Binding(
            get: { (playback.activeChoice(for: audio) ?? playback.preferredChoice(for: audio))?.id },
            set: { playback.setPreferredChoiceID($0, for: audio) }
        )
    }

    private func track(fraction: Double) -> some View {
        let width = Self.trackWidth
        let x = width * CGFloat(min(max(fraction, 0), 1))
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(DesignTokens.fillStrong)
                .frame(width: width, height: 3)
            Capsule()
                .fill(LibraryTokens.accent)
                .frame(width: max(0, x), height: 3)
            Circle()
                .fill(DesignTokens.paper)
                .overlay(Circle().stroke(DesignTokens.hairlineStrong, lineWidth: 1))
                .frame(width: 10, height: 10)
                .offset(x: x - 5)
        }
        .frame(width: width, height: 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragFraction = Double(min(max(value.location.x / width, 0), 1))
                }
                .onEnded { value in
                    playback.seek(audio, progress: Double(min(max(value.location.x / width, 0), 1)))
                    dragFraction = nil
                }
        )
        .padding(.horizontal, 2)
        .help("Drag to move through the meeting")
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(
            "\(MeetingAudioPlayback.clockText(fraction * playback.duration)) of \(MeetingAudioPlayback.clockText(playback.duration))"
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.skip(audio, by: 15)
            case .decrement: playback.skip(audio, by: -15)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("transcripted.home.meeting.scrubber")
    }
}

/// A speaker's color in a meeting transcript: the same voice-print palette
/// (`VoicePrintStyle`) the Speakers page and the island use, so a saved person
/// is one color everywhere. A saved person is keyed by their profile ID, like
/// their print; an unsaved voice by its transcript key. Text takes the darker
/// readable shade on light windows (`SpeakerPrintTextInk`).
enum HomeMeetingSpeakerColor {
    static func color(for identity: HomeMeetingSpeakerIdentity) -> Color {
        Color(nsColor: nsColor(colorIndex: HomeMeetingSpeakerPalette.colorIndex(
            persistentSpeakerID: identity.persistentSpeakerID,
            stableID: identity.stableID
        )))
    }

    private static func nsColor(colorIndex: Int) -> NSColor {
        func make(_ ink: VoicePrintRGBA) -> NSColor {
            NSColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha)
        }
        return DesignTokens.dynamic(
            dark: make(SpeakerPrintTextInk.hint(colorIndex: colorIndex, dark: true)),
            light: make(SpeakerPrintTextInk.hint(colorIndex: colorIndex, dark: false))
        )
    }
}
