import AppKit
import SwiftUI

// The opened Meetings card's player (owner-approved milled rail, 2026-11-27):
// one recessed matte well between the summary and "Full transcript". Its top
// is a 38 pt rail: -15 s, a 26 pt play disc, +15 s, the scrub rail, the
// two-tone clock, a hairline, the speed button and, when split tracks were
// kept, Mix / You / Others. Once the card's audio has been played, scrubbed
// or skipped, a mini transcript unfurls under the rail and follows the
// playhead (`HomeMeetingMiniTranscript`). Played color is the speaker's own
// print color (paper ink for You or silence); never the live green. The full
// transcript below still never follows the playhead. Rules and words:
// `HomeMeetingRailPresentation`.

// MARK: - Surfaces

/// The Meetings card's own surfaces: the matte card, its lift on hover, the
/// recessed well, and the rail's parts, in both appearances.
enum HomeMeetingCardSurface {
    private static func dyn(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: DesignTokens.dynamic(dark: dark, light: light))
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        DesignTokens.rgb(hex, alpha: alpha)
    }

    static let fill = dyn(rgb(0x2A2A2D, 1), rgb(0xFFFFFF, 1))
    static let liftedFill = dyn(rgb(0x2E2E32, 1), rgb(0xFCFCFB, 1))
    static let wellFill = dyn(rgb(0x202023, 1), rgb(0xF1F1EE, 1))
    static let wellBorder = dyn(rgb(0xFFFFFF, 0.065), rgb(0x1A1A19, 0.075))
    static let playIdleFill = dyn(rgb(0xFFFFFF, 0.10), rgb(0x1A1A19, 0.075))
    static let playIdleHover = dyn(rgb(0xFFFFFF, 0.17), rgb(0x1A1A19, 0.13))
    static let playIdleBorder = dyn(rgb(0xFFFFFF, 0.09), rgb(0x1A1A19, 0.07))
    static let railTrack = dyn(rgb(0xFFFFFF, 0.11), rgb(0x1A1A19, 0.11))
    static let railGhost = dyn(rgb(0xFFFFFF, 0.17), rgb(0x1A1A19, 0.14))
    static let thumb = dyn(rgb(0xFFFFFF, 1), rgb(0x1A1A19, 1))
    /// The glyph on a filled play disc: dark on the bright dark-mode hues,
    /// light on the deeper light-mode ones.
    static let onAccent = dyn(rgb(0x171719, 1), rgb(0xF7F7F5, 1))
    static let tooltipFill = Color(nsColor: DesignTokens.rgb(0x141416))
    /// Light cards carry a whisper of shadow; dark ones lift by fill alone.
    static let shadow = dyn(rgb(0x000000, 0), rgb(0x000000, 0.06))
    static let openShadow = dyn(rgb(0x000000, 0.22), rgb(0x000000, 0.08))
}

// MARK: - Timed lines

/// The open card's transcript lines with their start times worked out once,
/// so a view redrawing every frame never re-parses a clock string.
struct HomeMeetingTimedLines: Equatable {
    let lines: [HomeMeetingTranscriptLine]
    let starts: [TimeInterval?]

    init(_ lines: [HomeMeetingTranscriptLine]) {
        self.lines = lines
        starts = lines.map(\.startSeconds)
    }

    static let empty = HomeMeetingTimedLines([])

    var hasTimedLines: Bool { starts.contains { $0 != nil } }

    func activeIndex(at time: TimeInterval) -> Int? {
        HomeMeetingRailPresentation.activeLineIndex(starts: starts, at: time)
    }

    func speakingLine(at time: TimeInterval) -> HomeMeetingTranscriptLine? {
        HomeMeetingRailPresentation.speakingLineIndex(starts: starts, at: time).map { lines[$0] }
    }
}

/// The speaker color a line plays in: their print's color, paper ink for
/// You or nobody.
enum HomeMeetingRailInk {
    static func accent(for line: HomeMeetingTranscriptLine?) -> Color {
        guard let line, !line.speaker.isEmpty, !SpeakerNameSelectionPolicy.isOwnerLabel(line.speaker) else {
            return LibraryTokens.ink
        }
        return HomeMeetingPersonInk.ring(colorIndex(for: line))
    }

    static func text(for line: HomeMeetingTranscriptLine) -> Color {
        guard !line.speaker.isEmpty, !SpeakerNameSelectionPolicy.isOwnerLabel(line.speaker) else {
            return LibraryTokens.ink
        }
        return HomeMeetingSpeakerColor.color(for: line.identity)
    }

    private static func colorIndex(for line: HomeMeetingTranscriptLine) -> Int {
        HomeMeetingSpeakerPalette.colorIndex(
            persistentSpeakerID: line.identity.persistentSpeakerID,
            stableID: line.identity.stableID
        )
    }
}

// MARK: - The shell

/// The recessed well: the rail on top, the mini transcript under it once
/// the audio has been started.
struct HomeMeetingInstrumentShell: View {
    let audio: MeetingAudioAttachment
    /// The meeting's length, used until the audio itself says.
    let fallbackDuration: TimeInterval?
    let timed: HomeMeetingTimedLines

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Played, scrubbed or skipped since this card opened.
    @State private var hasStarted = false
    @State private var showsRemaining = false
    @State private var dragFraction: Double?

    private var isActive: Bool { playback.isActive(audio) }
    private var isPlayingHere: Bool { isActive && playback.isPlaying }

    private var total: TimeInterval {
        if isActive, playback.duration > 0 { return playback.duration }
        return fallbackDuration ?? 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlayingHere || dragFraction != nil)) { _ in
            let time = currentTime
            let activeLine = timed.speakingLine(at: time) ?? timed.activeIndex(at: time).map { timed.lines[$0] }
            let accent = HomeMeetingRailInk.accent(for: activeLine)
            shell(time: time, accent: accent)
        }
        .onChange(of: isActive) { _, active in
            if active { hasStarted = true }
        }
        .onAppear {
            if isActive { hasStarted = true }
        }
    }

    private var currentTime: TimeInterval {
        if let dragFraction { return dragFraction * total }
        return isActive ? playback.currentPlaybackTime(for: audio) : 0
    }

    private var showsMini: Bool {
        HomeMeetingRailPresentation.showsMiniTranscript(
            hasStarted: hasStarted,
            isActive: isActive,
            hasLines: timed.hasTimedLines
        )
    }

    private func shell(time: TimeInterval, accent: Color) -> some View {
        VStack(spacing: 0) {
            rail(time: time, accent: accent)
            if showsMini {
                HomeMeetingMiniTranscript(timed: timed, time: time) { start in
                    jump(to: start)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HomeMeetingCardSurface.wellFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isPlayingHere ? accent.opacity(0.32) : HomeMeetingCardSurface.wellBorder, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: showsMini)
        .animation(.easeOut(duration: 0.24), value: isPlayingHere)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.meeting.player")
    }

    // MARK: Rail

    private func rail(time: TimeInterval, accent: Color) -> some View {
        HStack(spacing: 0) {
            HomeRailSkipButton(seconds: -15) { skip(by: -15) }
            HomeRailPlayDisc(audio: audio, accent: accent, isPlaying: isPlayingHere) {
                hasStarted = true
            }
            .padding(.horizontal, 2)
            HomeRailSkipButton(seconds: 15) { skip(by: 15) }

            HomeMeetingScrubRail(
                time: time,
                total: total,
                accent: accent,
                isPlaying: isPlayingHere,
                timed: timed,
                onDrag: { fraction in
                    hasStarted = true
                    dragFraction = fraction
                },
                onCommit: { fraction in
                    seek(to: fraction)
                    dragFraction = nil
                },
                onSkip: skip(by:)
            )
            .padding(.leading, 10)
            .padding(.trailing, 12)

            clock(time: time, accent: accent)

            Rectangle()
                .fill(LibraryTokens.hairline)
                .frame(width: 1, height: 14)
                .padding(.leading, 10)
                .padding(.trailing, 6)

            HomeRailSpeedButton(rate: playback.playbackRate, accent: accent) {
                playback.cyclePlaybackRate()
            }

            MeetingAudioSourceMenu(
                attachment: audio,
                selectedChoiceID: selectedChoiceBinding
            ) { choice in
                playback.switchSource(audio, choice: choice)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .frame(height: 38)
    }

    @ViewBuilder
    private func clock(time: TimeInterval, accent: Color) -> some View {
        if total > 0 {
            let texts = HomeMeetingRailPresentation.clockTexts(elapsed: time, total: total, showsRemaining: showsRemaining)
            Button {
                showsRemaining.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text(texts.elapsed)
                        .fontWeight(.medium)
                        .foregroundStyle(dragFraction != nil ? accent : (isPlayingHere ? LibraryTokens.ink : LibraryTokens.ink2))
                    Text("/")
                        .foregroundStyle(LibraryTokens.ink3.opacity(0.6))
                    Text(texts.trailing)
                        .foregroundStyle(LibraryTokens.ink3)
                }
                .font(.system(size: 11.5))
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 88, alignment: .trailing)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(HomeRailHoverFillStyle(cornerRadius: 6))
            .padding(.horizontal, -5)
            .help(showsRemaining ? "Show the meeting's length" : "Show time left")
            .accessibilityLabel(Text(showsRemaining ? "Time left" : "Elapsed and length"))
            .accessibilityValue(Text("\(texts.elapsed), \(texts.trailing)"))
            .accessibilityIdentifier("transcripted.home.meeting.clock")
        }
    }

    private var selectedChoiceBinding: Binding<String?> {
        Binding(
            get: { (playback.activeChoice(for: audio) ?? playback.preferredChoice(for: audio))?.id },
            set: { playback.setPreferredChoiceID($0, for: audio) }
        )
    }

    // MARK: Actions

    private func seek(to fraction: Double) {
        hasStarted = true
        if isActive, playback.duration > 0 {
            playback.seek(audio, progress: fraction)
            if playback.isPaused { playback.resume() }
        } else if total > 0 {
            playback.play(audio, from: fraction * total)
        } else {
            playback.toggle(audio)
        }
    }

    /// Skips the playing audio; on an idle card +15 s starts 15 s in, and
    /// -15 s has nowhere to go.
    private func skip(by seconds: TimeInterval) {
        if isActive {
            hasStarted = true
            playback.skip(audio, by: seconds)
        } else if seconds > 0, total > 0 {
            hasStarted = true
            playback.play(audio, from: min(seconds, total))
        }
    }

    private func jump(to start: TimeInterval) {
        hasStarted = true
        playback.play(audio, from: start)
    }
}

// MARK: - Transport

/// The 26 pt play disc: a quiet tonal circle at rest, filled with the
/// speaker's color while playing, with a crisp pause glyph. No pulsing ring.
private struct HomeRailPlayDisc: View {
    let audio: MeetingAudioAttachment
    let accent: Color
    let isPlaying: Bool
    let onPlay: () -> Void

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var isHovering = false

    private var selectedChoice: MeetingAudioPlaybackChoice? {
        playback.activeChoice(for: audio) ?? playback.preferredChoice(for: audio)
    }

    private var isUnavailable: Bool { playback.isUnavailable(audio, choice: selectedChoice) }

    private var help: String {
        if isUnavailable { return "This meeting's audio couldn't be played" }
        return isPlaying ? "Pause" : "Play"
    }

    var body: some View {
        Button {
            onPlay()
            playback.toggle(audio, choice: selectedChoice)
        } label: {
            ZStack {
                Circle()
                    .fill(isPlaying ? accent : (isHovering ? HomeMeetingCardSurface.playIdleHover : HomeMeetingCardSurface.playIdleFill))
                Circle()
                    .strokeBorder(isPlaying ? Color.clear : HomeMeetingCardSurface.playIdleBorder, lineWidth: 1)
                Image(systemName: isUnavailable ? "exclamationmark" : (isPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 10, weight: .bold))
                    .offset(x: isPlaying || isUnavailable ? 0 : 1)
                    .foregroundStyle(isUnavailable ? LibraryTokens.attention : (isPlaying ? HomeMeetingCardSurface.onAccent : LibraryTokens.ink))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(HomeRailPressStyle(scale: 0.92))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.22), value: isPlaying)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier("transcripted.home.meeting.play")
    }
}

/// -15 s and +15 s: SF Symbols with a hover fill and a little kick on press.
private struct HomeRailSkipButton: View {
    let seconds: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: seconds < 0 ? "gobackward.15" : "goforward.15")
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomeRailSkipStyle(direction: seconds < 0 ? -1 : 1))
        .help(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds")
        .accessibilityLabel(Text(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds"))
        .accessibilityIdentifier(seconds < 0 ? "transcripted.home.meeting.skip-back" : "transcripted.home.meeting.skip-forward")
    }
}

/// 1×, 1.25×, 1.5×, 2×: quiet at 1×, tinted with the speaker color above it.
private struct HomeRailSpeedButton: View {
    let rate: Float
    let accent: Color
    let action: () -> Void

    private var isFast: Bool { rate > 1.01 }

    var body: some View {
        Button(action: action) {
            Text(HomeMeetingRailPresentation.speedLabel(rate))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isFast ? accent : LibraryTokens.ink2)
                .frame(width: 38, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isFast ? accent.opacity(0.14) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isFast ? accent.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(HomeRailHoverFillStyle(cornerRadius: 6, isEnabled: !isFast))
        .animation(.easeOut(duration: 0.18), value: isFast)
        .help("Playback speed")
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(HomeMeetingRailPresentation.speedLabel(rate)))
        .accessibilityIdentifier("transcripted.home.meeting.speed")
    }
}

// MARK: - Button styles

/// Hover fill and ink lift for the rail's quiet buttons.
struct HomeRailHoverFillStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var isEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        HomeRailHoverFillBody(configuration: configuration, cornerRadius: cornerRadius, showsFill: isEnabled)
    }
}

private struct HomeRailHoverFillBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let showsFill: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovering ? LibraryTokens.ink : LibraryTokens.ink2)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(showsFill && isHovering ? DesignTokens.fillStrong : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { isHovering = $0 }
    }
}

private struct HomeRailPressStyle: ButtonStyle {
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HomeRailSkipStyle: ButtonStyle {
    let direction: Double

    func makeBody(configuration: Configuration) -> some View {
        HomeRailHoverFillBody(configuration: configuration, cornerRadius: 6, showsFill: true)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? 14 * direction : 0))
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
