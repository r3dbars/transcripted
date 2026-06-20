// Meeting/MeetingArmedPromptCopy.swift
// Pure copy + chime policy for the gentle calendar "armed" prompt.
//
// docs/MEETING_CAPTURE_PROMPTING.md §3.3 specifies a new "armed" pill surface:
// a silent pre-arm card a minute before a scheduled meeting ("Starts in 1 min"),
// flipping to a single gentle nudge at the meeting's start ("Starting now —
// tap to record") with one soft chime. The live app expresses this on the
// existing meeting-overlay prompt card (MeetingOverlayController.OverlayState
// .prompt) rather than a separate state machine, so this file owns only the
// words and the one-shot chime decision — kept Foundation-pure so the
// transitions are unit-tested without AppKit.
//
// Load-bearing invariant: this type NEVER starts a recording. It only decides
// what the card says. A recording still begins only on the explicit Record tap
// (MeetingOverlayController.onPromptRecord → MeetingSessionController.startRecording).

import Foundation

/// Which phase of the armed calendar prompt the card is showing.
enum MeetingArmedPromptPhase: Equatable {
    /// Silent pre-arm: the meeting is still ahead. Shows "Starts in N min".
    case preArm
    /// The single gentle nudge: the meeting has reached its start time.
    case startingNow
}

/// Resolved copy for the armed calendar prompt plus the one-shot chime decision.
struct MeetingArmedPromptCopy: Equatable {
    let title: String
    let subtext: String
    let phase: MeetingArmedPromptPhase
    /// True while the card is showing the T−0 "starting now" nudge. The overlay
    /// plays one soft chime when this first becomes true for a given meeting
    /// (deduped by candidate id) and never again — never a silent auto-start.
    let shouldChimeOnStartNudge: Bool
}

enum MeetingArmedPromptCopyPolicy {
    /// Generic label shown whenever the real event title must be hidden.
    static let genericTitle = "Meeting"

    /// The single gentle nudge line shown at the meeting's start time.
    static let startNudgeSubtext = "Starting now — tap to record"

    /// Resolves the title shown on the floating pill. Returns the generic label
    /// when the user opted out of real titles OR a screen-share / system-audio
    /// capture is detected (the shoulder-surf default from §4.2 B5); otherwise
    /// the trimmed event title, falling back to the generic label when the event
    /// has no usable title.
    static func displayTitle(
        eventTitle: String?,
        showRealTitles: Bool,
        isScreenShareLikely: Bool
    ) -> String {
        guard showRealTitles, !isScreenShareLikely else { return genericTitle }
        let trimmed = (eventTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? genericTitle : trimmed
    }

    static func phase(secondsUntilStart: TimeInterval) -> MeetingArmedPromptPhase {
        secondsUntilStart > 0 ? .preArm : .startingNow
    }

    /// "Starts in N min" while the meeting is still ahead (rounded up, minimum
    /// one minute so a 40-second lead never reads "Starts in 0 min"); the single
    /// "Starting now — tap to record" line once the start time has arrived.
    static func subtext(secondsUntilStart: TimeInterval) -> String {
        guard secondsUntilStart > 0 else { return startNudgeSubtext }
        let minutes = max(1, Int(ceil(secondsUntilStart / 60)))
        return "Starts in \(minutes) min"
    }

    static func make(
        eventTitle: String?,
        startDate: Date,
        now: Date,
        showRealTitles: Bool,
        isScreenShareLikely: Bool
    ) -> MeetingArmedPromptCopy {
        let secondsUntilStart = startDate.timeIntervalSince(now)
        let resolvedPhase = phase(secondsUntilStart: secondsUntilStart)
        return MeetingArmedPromptCopy(
            title: displayTitle(
                eventTitle: eventTitle,
                showRealTitles: showRealTitles,
                isScreenShareLikely: isScreenShareLikely
            ),
            subtext: subtext(secondsUntilStart: secondsUntilStart),
            phase: resolvedPhase,
            shouldChimeOnStartNudge: resolvedPhase == .startingNow
        )
    }
}
