// NotchIslandDropButtons.swift
// Which buttons each drop-down offers, in order, and what each one means.
// Plain data, so the fast tests can check every prompt's roles without
// drawing; NotchIslandDropView turns them into NotchIslandButtons.
//
// The rule on the black island: the primary is the white pill (one per
// drop-down at most), everything else is a quiet grey pill, and red is only
// the confirm step of something destructive.

import Foundation

struct NotchIslandDropButton: Equatable {
    enum Placement: Equatable {
        case leading
        case trailing
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
        case .meetingControls(let note, _, let showsTranscript, let micAction):
            var buttons: [NotchIslandDropButton] = []
            if showsTranscript {
                buttons.append(.init(title: "Copy all", role: .standard, action: .meetingCopyTranscript,
                                     placement: .leading, symbol: "doc.on.doc"))
            }
            if note == .off {
                buttons.append(.init(title: "Turn on", role: .standard, action: .meetingCallAudio,
                                     placement: .leading, accessibilityLabel: "Turn on call audio"))
            }
            if let micAction {
                let verb: String
                if case .meetingMicUnmute = micAction { verb = "Unmute" } else { verb = "Mute" }
                buttons.append(.init(title: "\(verb) mic", role: .standard, action: micAction,
                                     accessibilityLabel: "\(verb) Transcripted meeting microphone"))
            }
            // Stop saves and transcribes: the safe primary, not red.
            buttons.append(.init(title: "Stop", role: .primary, action: .meetingStop, symbol: "stop.fill"))
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
        case .meetingError(_, _, let canOpen, let grantsSystemAudio):
            var buttons = [NotchIslandDropButton(title: dismissTitle, role: .standard, action: .meetingDismissError)]
            if grantsSystemAudio {
                // The meeting overlay's primary action opens the audio-only
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

    static func insertTitle(appName: String?) -> String {
        guard let appName, !appName.isEmpty else { return "Insert now" }
        return "Insert into \(appName)"
    }
}
