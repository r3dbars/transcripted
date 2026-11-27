import SwiftUI

/// The rail's precision scrubber: a 3 pt track that thickens to 5 pt under
/// the pointer, a faint ghost fill to the pointer, the played part in the
/// speaker's color (muted while paused), and a crisp playhead pip that is
/// subtly visible at rest and blooms to 11 pt on hover or drag. Hovering or
/// dragging floats "14:25 · Priya" over the pointer using pure coordinate
/// positioning so changing speaker names never cause layout feedback jitter.
struct HomeMeetingScrubRail: View {
    let time: TimeInterval
    let total: TimeInterval
    let accent: Color
    let isPlaying: Bool
    let timed: HomeMeetingTimedLines
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void
    let onSkip: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverX: CGFloat?
    @State private var isDragging = false

    private var isEngaged: Bool { hoverX != nil || isDragging }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = total > 0 ? CGFloat(min(max(time / total, 0), 1)) : 0
            let thumbX = width * fraction
            let trackHeight: CGFloat = isEngaged ? 5 : 3
            let thumbSize: CGFloat = isDragging ? 12 : (isEngaged ? 11 : 7)

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(HomeMeetingCardSurface.railTrack)
                    .frame(height: trackHeight)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isEngaged)

                // Hover ghost preview fill
                if let hoverX, !isDragging, total > 0 {
                    Capsule()
                        .fill(HomeMeetingCardSurface.railGhost)
                        .frame(width: min(max(hoverX, 0), width), height: trackHeight)
                }

                // Played progress fill
                if total > 0, thumbX > 0.5 {
                    Capsule()
                        .fill(isPlaying || isEngaged ? accent : accent.opacity(0.62))
                        .frame(width: max(thumbX, trackHeight), height: trackHeight)
                }

                // Playhead pip: always subtly visible when duration is known, blooms on hover/drag
                if total > 0 {
                    Circle()
                        .fill(isEngaged ? HomeMeetingCardSurface.thumb : accent)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(isEngaged ? 0.38 : 0.18), radius: isEngaged ? 2.5 : 1, y: 1)
                        .overlay {
                            if isDragging {
                                Circle()
                                    .strokeBorder(accent.opacity(0.28), lineWidth: 3.5)
                                    .padding(-3.5)
                            }
                        }
                        .offset(x: min(max(thumbX - thumbSize / 2, 0), max(0, width - thumbSize)))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isEngaged)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDragging)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if let pointer = isDragging ? thumbX : hoverX, total > 0 {
                    let clampedX = min(max(pointer, 44), max(44, width - 44))
                    hoverPill(at: pointer, width: width)
                        .position(x: clampedX, y: -12)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverX = min(max(location.x, 0), width)
                case .ended:
                    hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard total > 0 else { return }
                        isDragging = true
                        let frac = Double(min(max(value.location.x / width, 0), 1))
                        onDrag(frac)
                    }
                    .onEnded { value in
                        isDragging = false
                        guard total > 0 else { return }
                        let frac = Double(min(max(value.location.x / width, 0), 1))
                        onCommit(frac)
                    }
            )
        }
        .frame(minWidth: 90)
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(
            "\(MeetingAudioPlayback.clockText(time)) of \(MeetingAudioPlayback.clockText(total))"
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSkip(15)
            case .decrement: onSkip(-15)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("transcripted.home.meeting.scrubber")
    }

    private func hoverPill(at x: CGFloat, width: CGFloat) -> some View {
        let fraction = Double(min(max(x / width, 0), 1))
        let pointerTime = fraction * total
        let line = timed.speakingLine(at: pointerTime)
        let clock = MeetingAudioPlayback.clockText(pointerTime)
        return HStack(spacing: 5) {
            Text(clock)
                .foregroundStyle(Color.white.opacity(0.92))
            if let line, !line.speaker.isEmpty {
                Text("\u{00B7}")
                    .foregroundStyle(Color.white.opacity(0.4))
                Text(line.speaker)
                    .fontWeight(.semibold)
                    .foregroundStyle(HomeMeetingRailInk.accent(for: line))
                    .environment(\.colorScheme, .dark)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
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
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
