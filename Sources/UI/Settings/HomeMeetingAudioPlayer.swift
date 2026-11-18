import AppKit
import SwiftUI

// Meeting-audio controls for the Meetings page: the small round play button
// on every row that kept audio, and the opened card's thin scrubber with
// elapsed and total time (plus the Mix / You / Others picker when the
// meeting kept split tracks). Playback runs through
// `MeetingAudioPlayback.shared`, and transcript lines still play from their
// time. Rows never follow the playhead.

/// The round play/pause: drawn at 22 pt, hit at 40 pt. A closed row draws a
/// quiet outline; the opened card draws it filled. Playing is filled ink
/// with a pause glyph either way.
struct HomeMeetingPlayButton: View {
    enum Look {
        /// A closed row: hairline ring, grey triangle.
        case outline
        /// The opened card: filled ink.
        case filled
    }

    let audio: MeetingAudioAttachment
    var look: Look = .outline
    var automationIdentifier = "transcripted.home.meeting.play"

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    nonisolated static let size: CGFloat = 22
    private var size: CGFloat { Self.size }

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

    private var isFilled: Bool {
        !isUnavailable && (isPlaying || look == .filled)
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
                    .fill(isFilled ? LibraryTokens.ink : Color.clear)
                Circle()
                    .strokeBorder(
                        isFilled ? Color.clear : (isHovering ? LibraryTokens.ink2 : DesignTokens.hairlineStrong),
                        lineWidth: 1
                    )
                Image(systemName: isUnavailable ? "exclamationmark" : (isPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 8.5, weight: .bold))
                    .offset(x: isPlaying || isUnavailable ? 0 : 0.5)
                    .foregroundStyle(glyphColor)
            }
            .frame(width: Self.size, height: Self.size)
            .frame(width: hitTargetSize, height: hitTargetSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The 40 pt hit shape overhangs the row instead of growing it.
        .padding(-(hitTargetSize - Self.size) / 2)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isPlaying)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier(automationIdentifier)
    }

    private var glyphColor: Color {
        if isUnavailable { return LibraryTokens.attention }
        return isFilled ? DesignTokens.paper : LibraryTokens.ink2
    }
}

/// The opened card's scrubber: elapsed · thin bar · total, and the track
/// picker when there is more than one. Before the audio has loaded, the total
/// is the meeting's length and clicking the bar starts playing from there.
struct HomeMeetingScrubber: View {
    let audio: MeetingAudioAttachment
    /// The meeting's length, used until the audio itself says.
    let fallbackDuration: TimeInterval?

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var dragFraction: Double?

    private var isActive: Bool { playback.isActive(audio) }

    private var total: TimeInterval {
        if isActive, playback.duration > 0 { return playback.duration }
        return fallbackDuration ?? 0
    }

    var body: some View {
        let fraction = dragFraction ?? (isActive ? playback.progress(for: audio) : 0)
        HStack(spacing: 8) {
            Text(MeetingAudioPlayback.clockText(fraction * total))
                .frame(minWidth: 28, alignment: .leading)
            bar(fraction: fraction)
            Text(MeetingAudioPlayback.clockText(total))
            MeetingAudioSourceMenu(
                attachment: audio,
                selectedChoiceID: selectedChoiceBinding
            ) { choice in
                playback.switchSource(audio, choice: choice)
            }
        }
        .font(TextRole.small.font())
        .monospacedDigit()
        .foregroundStyle(LibraryTokens.ink3)
        .lineLimit(1)
    }

    private var selectedChoiceBinding: Binding<String?> {
        Binding(
            get: { (playback.activeChoice(for: audio) ?? playback.preferredChoice(for: audio))?.id },
            set: { playback.setPreferredChoiceID($0, for: audio) }
        )
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let clamped = CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.hairlineStrong)
                    .frame(height: 2)
                Capsule()
                    .fill(LibraryTokens.ink)
                    .frame(width: width * clamped, height: 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = Double(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        seek(to: Double(min(max(value.location.x / width, 0), 1)))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 12)
        .help("Click to play from there")
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(
            "\(MeetingAudioPlayback.clockText(fraction * total)) of \(MeetingAudioPlayback.clockText(total))"
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: skip(by: 15)
            case .decrement: skip(by: -15)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("transcripted.home.meeting.scrubber")
    }

    private func seek(to fraction: Double) {
        if isActive, playback.duration > 0 {
            playback.seek(audio, progress: fraction)
            if playback.isPaused { playback.resume() }
        } else if total > 0 {
            playback.play(audio, from: fraction * total)
        } else {
            playback.toggle(audio)
        }
    }

    private func skip(by seconds: TimeInterval) {
        if isActive {
            playback.skip(audio, by: seconds)
        } else if seconds > 0, total > 0 {
            playback.play(audio, from: min(seconds, total))
        }
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
