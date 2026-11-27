import AppKit
import SwiftUI

// The opened Meetings card's player (owner-approved milled rail, 2026-11-27):
// one 38 pt recessed matte well between the summary and the unified scrollable
// transcript below it: -15 s, a 26 pt play disc, +15 s, the precision scrub
// rail, the clickable two-tone clock, a hairline, the speed button and, when
// split tracks were kept, Mix / You / Others.
//
// Interactive buttons (-15 s, Play/Pause, +15 s, Speed, Source) sit OUTSIDE
// TimelineView(.animation) so high-frequency playhead updates never rebuild
// their hit-testing or drop hover/click events. Played color follows the
// active speaker's VoicePrint color (paper ink for You or silence).

// MARK: - Surfaces

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
    static let onAccent = dyn(rgb(0x171719, 1), rgb(0xF7F7F5, 1))
    static let tooltipFill = Color(nsColor: DesignTokens.rgb(0x141416))
    static let shadow = dyn(rgb(0x000000, 0), rgb(0x000000, 0.06))
    static let openShadow = dyn(rgb(0x000000, 0.22), rgb(0x000000, 0.08))
}

// MARK: - Timed lines

struct HomeMeetingTimedLines: Equatable {
    let lines: [HomeMeetingTranscriptLine]
    let starts: [TimeInterval?]

    init(_ lines: [HomeMeetingTranscriptLine]) {
        self.lines = lines
        starts = lines.map(\.startSeconds)
    }

    static let empty = HomeMeetingTimedLines([])

    var hasTimedLines: Bool { starts.contains { $0 != nil } }

    var lastTimestamp: TimeInterval? {
        starts.compactMap { $0 }.max()
    }

    func activeIndex(at time: TimeInterval) -> Int? {
        HomeMeetingRailPresentation.activeLineIndex(starts: starts, at: time)
    }

    func speakingLine(at time: TimeInterval) -> HomeMeetingTranscriptLine? {
        HomeMeetingRailPresentation.speakingLineIndex(starts: starts, at: time).map { lines[$0] }
    }
}

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

// MARK: - The recessed milled rail

struct HomeMeetingInstrumentShell: View {
    let audio: MeetingAudioAttachment
    let fallbackDuration: TimeInterval?
    let timed: HomeMeetingTimedLines
    /// Only updates when a scrub drag crosses into a different transcript line,
    /// avoiding 60–120 Hz redraws of the card and transcript.
    @Binding var scrubActiveLineIndex: Int?

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var showsRemaining = false
    @State private var dragFraction: Double?

    private var isActive: Bool { playback.isActive(audio) }
    private var isPlayingHere: Bool { isActive && playback.isPlaying }

    private var total: TimeInterval {
        let probed = playback.knownDuration(for: audio, fallback: fallbackDuration)
        if probed > 0 { return probed }
        if let last = timed.lastTimestamp, last > 0 { return last + 5 }
        return 0
    }

    /// Published (quarter-second / drag) time for stable button chrome so
    /// transport buttons never rebuild at 60–120 Hz.
    private var stableTime: TimeInterval {
        if let dragFraction, total > 0 { return dragFraction * total }
        return isActive ? playback.currentTime : 0
    }

    private var activeAccent: Color {
        let line = timed.speakingLine(at: stableTime) ?? timed.activeIndex(at: stableTime).map { timed.lines[$0] }
        return HomeMeetingRailInk.accent(for: line)
    }

    private var canSkipBack: Bool {
        isActive && stableTime > 0.5
    }

    private var canSkipForward: Bool {
        total > 0
    }

    var body: some View {
        HStack(spacing: 0) {
            HomeRailSkipButton(seconds: -15, isDisabled: !canSkipBack) {
                skip(by: -15)
            }

            HomeRailPlayDisc(
                audio: audio,
                fallbackDuration: total > 0 ? total : fallbackDuration,
                accent: activeAccent,
                isPlaying: isPlayingHere
            )
            .padding(.horizontal, 3)

            HomeRailSkipButton(seconds: 15, isDisabled: !canSkipForward) {
                skip(by: 15)
            }

            HomeMeetingLiveScrubCluster(
                audio: audio,
                total: total,
                isActive: isActive,
                isPlayingHere: isPlayingHere,
                timed: timed,
                showsRemaining: $showsRemaining,
                dragFraction: $dragFraction,
                onDragChanged: { fraction in
                    dragFraction = fraction
                    let nextLine = fraction.flatMap { total > 0 ? timed.activeIndex(at: $0 * total) : nil }
                    if scrubActiveLineIndex != nextLine {
                        scrubActiveLineIndex = nextLine
                    }
                },
                onCommit: { fraction in
                    seek(to: fraction)
                    dragFraction = nil
                    if scrubActiveLineIndex != nil {
                        scrubActiveLineIndex = nil
                    }
                },
                onSkip: skip(by:)
            )
            .padding(.leading, 10)

            Rectangle()
                .fill(LibraryTokens.hairline)
                .frame(width: 1, height: 14)
                .padding(.leading, 10)
                .padding(.trailing, 6)

            HomeRailSpeedButton(rate: playback.playbackRate, accent: activeAccent) {
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HomeMeetingCardSurface.wellFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isPlayingHere ? activeAccent.opacity(0.32) : HomeMeetingCardSurface.wellBorder, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .animation(.easeOut(duration: 0.22), value: isPlayingHere)
        .onAppear {
            playback.probeDurationIfNeeded(for: audio)
        }
        .task(id: audio.id) {
            playback.probeDurationIfNeeded(for: audio)
        }
        .onDisappear {
            dragFraction = nil
            if scrubActiveLineIndex != nil {
                scrubActiveLineIndex = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.meeting.player")
    }

    private var selectedChoiceBinding: Binding<String?> {
        Binding(
            get: { (playback.activeChoice(for: audio) ?? playback.preferredChoice(for: audio))?.id },
            set: { playback.setPreferredChoiceID($0, for: audio) }
        )
    }

    // MARK: Actions

    private func seek(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        if isActive {
            playback.seek(audio, progress: clamped)
            if playback.isPaused { playback.resume() }
        } else if total > 0 {
            playback.play(
                audio,
                from: clamped * total,
                fallbackDuration: total,
                rejectsStartPastEnd: false
            )
        } else {
            playback.toggle(audio, fallbackDuration: fallbackDuration)
        }
    }

    private func skip(by seconds: TimeInterval) {
        if isActive {
            playback.skip(audio, by: seconds)
        } else if seconds > 0, total > 0 {
            playback.play(
                audio,
                from: min(seconds, total),
                fallbackDuration: total,
                rejectsStartPastEnd: false
            )
        }
    }
}

// MARK: - Isolated live scrub + clock cluster

/// Only this view ticks with `TimelineView(.animation)`, keeping every button
/// on the rail completely immune to high-frequency rebuilds.
private struct HomeMeetingLiveScrubCluster: View {
    let audio: MeetingAudioAttachment
    let total: TimeInterval
    let isActive: Bool
    let isPlayingHere: Bool
    let timed: HomeMeetingTimedLines
    @Binding var showsRemaining: Bool
    @Binding var dragFraction: Double?
    let onDragChanged: (Double?) -> Void
    let onCommit: (Double) -> Void
    let onSkip: (TimeInterval) -> Void

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var clockHovered = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlayingHere || dragFraction != nil)) { _ in
            let time: TimeInterval = {
                if let dragFraction { return dragFraction * total }
                return isActive ? playback.currentPlaybackTime(for: audio) : 0
            }()
            let activeLine = timed.speakingLine(at: time) ?? timed.activeIndex(at: time).map { timed.lines[$0] }
            let accent = HomeMeetingRailInk.accent(for: activeLine)

            HStack(spacing: 12) {
                HomeMeetingScrubRail(
                    time: time,
                    total: total,
                    accent: accent,
                    isPlaying: isPlayingHere,
                    timed: timed,
                    onDragChanged: onDragChanged,
                    onCommit: onCommit,
                    onSkip: onSkip
                )

                if total > 0 {
                    clockButton(time: time, accent: accent)
                }
            }
        }
    }

    private func clockButton(time: TimeInterval, accent: Color) -> some View {
        let texts = HomeMeetingRailPresentation.clockTexts(elapsed: time, total: total, showsRemaining: showsRemaining)
        return Button {
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
            .frame(minWidth: 86, alignment: .trailing)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(clockHovered ? DesignTokens.fillStrong : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { clockHovered = $0 }
        .padding(.horizontal, -5)
        .help(showsRemaining ? "Show the meeting's length" : "Show time left")
        .accessibilityLabel(Text(showsRemaining ? "Time left" : "Elapsed and length"))
        .accessibilityValue(Text("\(texts.elapsed), \(texts.trailing)"))
        .accessibilityIdentifier("transcripted.home.meeting.clock")
    }
}

// MARK: - Transport controls (static, outside TimelineView)

private struct HomeRailPlayDisc: View {
    let audio: MeetingAudioAttachment
    let fallbackDuration: TimeInterval?
    let accent: Color
    let isPlaying: Bool

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
            playback.toggle(audio, choice: selectedChoice, fallbackDuration: fallbackDuration)
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
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isPlaying)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier("transcripted.home.meeting.play")
    }
}

private struct HomeRailSkipButton: View {
    let seconds: Int
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: seconds < 0 ? "gobackward.15" : "goforward.15")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(
                    isDisabled
                        ? LibraryTokens.ink3.opacity(0.45)
                        : (isHovering ? LibraryTokens.ink : LibraryTokens.ink2)
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(!isDisabled && isHovering ? DesignTokens.fillStrong : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .help(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds")
        .accessibilityLabel(Text(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds"))
        .accessibilityIdentifier(seconds < 0 ? "transcripted.home.meeting.skip-back" : "transcripted.home.meeting.skip-forward")
    }
}

private struct HomeRailSpeedButton: View {
    let rate: Float
    let accent: Color
    let action: () -> Void

    @State private var isHovering = false
    private var isFast: Bool { rate > 1.01 }

    var body: some View {
        Button(action: action) {
            Text(HomeMeetingRailPresentation.speedLabel(rate))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isFast ? accent : (isHovering ? LibraryTokens.ink : LibraryTokens.ink2))
                .frame(width: 38, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isFast ? accent.opacity(0.14) : (isHovering ? DesignTokens.fillStrong : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isFast ? accent.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isFast)
        .help("Playback speed")
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(HomeMeetingRailPresentation.speedLabel(rate)))
        .accessibilityIdentifier("transcripted.home.meeting.speed")
    }
}

// MARK: - Shared button style

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
