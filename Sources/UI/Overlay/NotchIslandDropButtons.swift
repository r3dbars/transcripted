// NotchIslandDropButtons.swift
// Which buttons each drop-down offers, in order, and what each one means.
// Plain data, so the fast tests can check every prompt's roles without
// drawing; NotchIslandDropView turns them into NotchIslandButtons.
//
// The rule on the black island: the primary is the white pill (one per
// drop-down at most), everything else is a quiet grey pill, and red is only
// the confirm step of something destructive. The recording drop-down is the
// one quiet exception: its Stop is still the primary but drawn as a dark
// translucent pill, and Copy / Mute are borderless round icons.

import Foundation

struct NotchIslandDropButton: Equatable {
    enum Placement: Equatable {
        case leading
        case trailing
    }

    /// How the button is drawn. Most are pills; the recording drop-down
    /// uses round icons and a translucent Stop so nothing glares.
    enum Look: Equatable {
        case pill
        /// A borderless round icon (`symbol`), its `title` only for VoiceOver.
        case icon
        /// A dark translucent pill with a thin light border.
        case quietPill
    }

    var title: String
    var role: NotchIslandPromptButtonRole
    var action: NotchIslandAction
    var placement: Placement = .trailing
    var symbol: String? = nil
    var accessibilityLabel: String? = nil
    /// The ring on the button that fires when time runs out.
    var countdown: NotchIslandCountdownRing? = nil
    /// "Insert into Slack" carries the app's own icon.
    var showsTargetAppIcon = false
    var look: Look = .pill
    /// The hover tip, for buttons that show only an icon.
    var toolTip: String? = nil
}

/// The amber pill on a recording's footer: shown only when something is
/// wrong (mic muted, call audio not connected or unconfirmed). Pressing it
/// runs `action` when there is one ("Call audio is off" turns it on).
struct NotchIslandMeetingWarning: Equatable {
    var text: String
    var action: NotchIslandAction? = nil
    var toolTip: String? = nil
}

enum NotchIslandDropButtons {
    /// What closes a notice without acting on it, everywhere but the call
    /// prompt (which says Skip).
    static let dismissTitle = "Dismiss"

    static func buttons(for drop: NotchIslandDrop, callSecondsLeft: Int = 0) -> [NotchIslandDropButton] {
        switch drop {
        case .dictationTarget(let appName, _, let isWriting):
            // Released: the words are being written; there's nothing to press.
            guard !isWriting else { return [] }
            return [
                .init(title: "Cancel", role: .standard, action: .dictationCancel),
                .init(title: insertTitle(appName: appName), role: .primary, action: .dictationStop,
                      showsTargetAppIcon: appName != nil),
            ]
        case .dictationLoading, .dictationNote, .meetingPreparing, .speakerReview:
            return []
        case .dictationMessage(let message):
            // One shape for every "your words didn't land" notice: Dismiss
            // with the ring, then the one way to get the words in.
            let ring = message.dismissSeconds.map {
                NotchIslandCountdownRing(button: .secondary, secondsLeft: $0, totalSeconds: $0, holdsWhileHovered: true)
            }
            var buttons = [NotchIslandDropButton(title: dismissTitle, role: .standard,
                                                 action: .dictationDismissMessage, countdown: ring)]
            if let title = message.actionTitle ?? (message.preview != nil ? "Paste" : nil) {
                buttons.append(.init(title: title, role: .primary, action: .dictationMessageAction))
            }
            return buttons
        case .justInserted:
            return [
                .init(title: "Copy", role: .standard, action: .copyLastDictation),
                .init(title: "Paste again", role: .primary, action: .pasteLastDictation),
            ]
        case .meetingControls(_, _, let showsTranscript, let recordingID, let micAction):
            // Call audio's Turn on lives on the warning pill (`meetingWarning`).
            var buttons: [NotchIslandDropButton] = []
            if showsTranscript {
                buttons.append(.init(title: "Copy", role: .standard, action: .meetingCopyTranscript,
                                     placement: .leading, symbol: "doc.on.doc",
                                     accessibilityLabel: copyTranscriptTip, look: .icon, toolTip: copyTranscriptTip))
            }
            if let micAction {
                let muted: Bool
                if case .meetingMicUnmute = micAction { muted = true } else { muted = false }
                let verb = muted ? "Unmute" : "Mute"
                // With the transcript, Copy and Mute sit together on the left;
                // in the strip, Mute sits by Stop on the right.
                buttons.append(.init(title: verb, role: .standard, action: micAction,
                                     placement: showsTranscript ? .leading : .trailing,
                                     symbol: muted ? "mic.slash" : "mic",
                                     accessibilityLabel: "\(verb) Transcripted meeting microphone",
                                     look: .icon, toolTip: "\(verb) microphone"))
            }
            // Stop saves and transcribes: the safe primary, not red, drawn as
            // the quiet translucent pill. It names the recording it was drawn
            // for, so a late click can't stop another.
            if let recordingID {
                buttons.append(.init(title: "Stop", role: .primary, action: .meetingStop(recordingID),
                                     symbol: "stop.fill", look: .quietPill))
            }
            return buttons
        case .meetingPrompt(let prompt):
            guard let identity = prompt.identity else { return [] }
            var buttons: [NotchIslandDropButton] = []
            func ring(_ button: MeetingIslandPromptButton) -> NotchIslandCountdownRing? {
                prompt.countdownRing?.button == button ? prompt.countdownRing : nil
            }
            if let tertiary = prompt.tertiaryTitle, !tertiary.isEmpty {
                buttons.append(.init(title: tertiary, role: prompt.tertiaryRole, action: .meetingPrompt(.tertiary, identity),
                                     placement: .leading, accessibilityLabel: prompt.tertiaryAccessibilityLabel,
                                     countdown: ring(.tertiary)))
            }
            if !prompt.secondaryTitle.isEmpty {
                buttons.append(.init(title: prompt.secondaryTitle, role: prompt.secondaryRole,
                                     action: .meetingPrompt(.secondary, identity),
                                     accessibilityLabel: prompt.secondaryAccessibilityLabel, countdown: ring(.secondary)))
            }
            if !prompt.primaryTitle.isEmpty {
                buttons.append(.init(title: prompt.primaryTitle, role: prompt.primaryRole,
                                     action: .meetingPrompt(.primary, identity),
                                     accessibilityLabel: prompt.primaryAccessibilityLabel, countdown: ring(.primary)))
            }
            return buttons
        case .meetingSaved:
            return [.init(title: "Open", role: .primary, action: .meetingOpen)]
        case .meetingError(_, _, let canOpen, let grantsSystemAudio, let grantsMicrophone):
            var buttons = [NotchIslandDropButton(title: dismissTitle, role: .standard, action: .meetingDismissError)]
            if grantsSystemAudio || grantsMicrophone {
                // The meeting overlay's primary action opens the matching
                // Settings pane while the start's denial is on screen.
                buttons.append(.init(title: "Open Settings", role: .primary, action: .meetingOpen))
            } else if canOpen {
                buttons.append(.init(title: "Open", role: .primary, action: .meetingOpen))
            }
            return buttons
        case .callPrompt:
            // The countdown is the ring around Skip, which is what happens
            // when it runs out; it holds while the pointer is on the island.
            let seconds = Double(max(1, callSecondsLeft))
            return [
                .init(title: "Skip", role: .standard, action: .callDismiss,
                      countdown: .init(button: .secondary, secondsLeft: seconds, totalSeconds: seconds, holdsWhileHovered: true)),
                .init(title: "Remind me", role: .standard, action: .callRemind),
                .init(title: "Record", role: .primary, action: .callRecord, symbol: "record.circle.fill"),
            ]
        case .meetingCallAudioAsk:
            return [
                .init(title: dismissTitle, role: .standard, action: .meetingCallAudioDismiss),
                .init(title: "Turn on", role: .primary, action: .meetingCallAudio, accessibilityLabel: "Turn on call audio"),
            ]
        }
    }

    static let copyTranscriptTip = "Copy live transcript"

    /// The recording footer's amber pill, or nil when all is well. One at
    /// most: call audio trouble first, then a muted mic.
    static func meetingWarning(for drop: NotchIslandDrop) -> NotchIslandMeetingWarning? {
        guard case .meetingControls(let note, let unverified, _, _, let micAction) = drop else { return nil }
        if unverified { return .init(text: NotchIslandMeetingCopy.cantConfirmCallAudio) }
        switch note {
        case .off?:
            return .init(text: NotchIslandMeetingCopy.callAudioOff, action: .meetingCallAudio, toolTip: "Turn on call audio")
        case .onForNextMeeting?:
            return .init(text: NotchIslandMeetingCopy.callAudioNextMeeting)
        case nil:
            break
        }
        if case .meetingMicUnmute? = micAction { return .init(text: NotchIslandMeetingCopy.micMuted) }
        return nil
    }

    /// What VoiceOver hears on a button with a countdown ring: what happens
    /// by itself when the ring runs out, and when.
    static func countdownAccessibilityValue(for action: NotchIslandAction, secondsLeft: Int) -> String {
        let seconds = max(0, secondsLeft)
        let when = "in \(seconds) \(seconds == 1 ? "second" : "seconds")"
        switch action {
        case .meetingPrompt(_, .inactivity(_, _)):
            return "Stops \(when)"
        case .meetingPrompt(_, .discardConfirm(_)):
            return "Keeps recording \(when)"
        case .callDismiss:
            return "Skips \(when)"
        case .dictationDismissMessage, .meetingPrompt(_, .missedCall(_)):
            return "Closes \(when)"
        default:
            return "Goes ahead by itself \(when)"
        }
    }

    static func insertTitle(appName: String?) -> String {
        guard let appName, !appName.isEmpty else { return "Insert now" }
        return "Insert into \(appName)"
    }
}
