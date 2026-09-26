// NotchIslandPresentation.swift
// What the notch island shows for every dictation, meeting and call-prompt
// state. Plain data in, plain data out: the controllers describe their state
// (NotchIsland*Content), `NotchIslandPresentation.layout` decides the two
// wings and the drop-down, and NotchIslandView draws the result. Kept free of
// AppKit so the fast tests can cover every combination.

import Foundation

// MARK: - What each surface reports

struct NotchIslandDictationContent: Equatable {
    enum Phase: Equatable {
        /// The key is down and the mic is still opening.
        case starting
        /// Waiting on the voice model or a settling mic.
        case loading(title: String, detail: String, progress: Double?)
        case listening
        /// Released; the words are being written.
        case writing
        case success(title: String)
        case message(Message)
    }

    struct Message: Equatable {
        enum Tone: Equatable {
            case error
            /// The text is safe on the clipboard.
            case notice
            /// Saved to Markdown, just not pasted.
            case saved
            /// Nothing was heard; the next take may replace it.
            case noSpeech
        }

        var tone: Tone
        var text: String
        var actionTitle: String?
    }

    var phase: Phase
    /// The Esc-confirm prompt or the 5-minute cap countdown, while listening.
    var notice: String = ""
    var targetAppName: String?
    var microphoneName: String?
}

struct NotchIslandMeetingContent: Equatable {
    enum Phase: Equatable {
        /// Nothing is recording; only a prompt is up (the missed-call nudge).
        case none
        case preparing(title: String, detail: String)
        case recording
        case transcribing(progress: Double?, detail: String)
        case saved(title: String?)
        case error(title: String, message: String, canOpen: Bool)
    }

    struct Prompt: Equatable {
        var title: String
        var detail: String
        var countdown: String
        var primaryTitle: String
        var secondaryTitle: String
        var tertiaryTitle: String?
    }

    enum CallAudioNote: Equatable {
        /// Only your mic is recording. Tapping it turns call audio on.
        case off
        /// Turned on mid-meeting; the next meeting records both sides.
        case onForNextMeeting
    }

    var phase: Phase
    var prompt: Prompt?
    var duration: TimeInterval = 0
    var callAudioNote: CallAudioNote?
    var systemAudioUnverified = false

    var isRecording: Bool { phase == .recording }

    /// Preparing, recording or transcribing: the meeting owns the island.
    var isBusy: Bool {
        switch phase {
        case .preparing, .recording, .transcribing:
            return true
        case .none, .saved, .error:
            return false
        }
    }
}

struct NotchIslandCallPromptContent: Equatable {
    var title: String
    var detail: String
    var secondsLeft: Int
}

/// The dictation that just landed. The island lingers on it for a moment so a
/// hover can offer Copy and Paste again.
struct NotchIslandRecentInsert: Equatable {
    var title: String
    var text: String?

    var words: Int { NotchIslandPresentation.wordCount(text) }
}

// MARK: - What the island draws

enum NotchIslandSymbol: String, Equatable {
    case mic = "mic.fill"
    case check = "checkmark"
    case clipboard = "doc.on.clipboard"
    case video = "video.fill"
    case warning = "exclamationmark.circle.fill"
    case saved = "tray.and.arrow.down.fill"
}

enum NotchIslandTint: Equatable {
    case accent
    case primary
    case secondary
    case warning
}

enum NotchIslandTextStyle: Equatable {
    case title
    case secondary
    case warning
}

/// Text that changes every second without changing the layout.
enum NotchIslandLiveValue: Equatable {
    case dictationTimer
    case meetingTimer
    case loadingPercent
    case callSeconds
}

enum NotchIslandChipStyle: Equatable {
    case plain
    case accent
    case destructive
    case warning
}

enum NotchIslandAction: Equatable {
    case dictationStop
    case dictationCancel
    case dictationMessageAction
    case dictationDismissMessage
    case copyLastDictation
    case pasteLastDictation
    case meetingStop
    case meetingPrimary
    case meetingSecondary
    case meetingTertiary
    case meetingCallAudio
    case meetingOpen
    case meetingDismissError
    case callRecord
    case callDismiss
    case callRemind

    enum Owner: Equatable {
        case dictation
        case meeting
        case callPrompt
        case island
    }

    var owner: Owner {
        switch self {
        case .dictationStop, .dictationCancel, .dictationMessageAction, .dictationDismissMessage:
            return .dictation
        case .copyLastDictation, .pasteLastDictation:
            return .island
        case .meetingStop, .meetingPrimary, .meetingSecondary, .meetingTertiary,
             .meetingCallAudio, .meetingOpen, .meetingDismissError:
            return .meeting
        case .callRecord, .callDismiss, .callRemind:
            return .callPrompt
        }
    }
}

enum NotchIslandItem: Equatable {
    case symbol(NotchIslandSymbol, NotchIslandTint)
    case text(String, NotchIslandTextStyle)
    case live(NotchIslandLiveValue, NotchIslandTextStyle)
    case dictationBars(count: Int)
    case meetingMeters
    case dots
    case shimmer
    case spinner
    case transcriptionRing
    case loadingRing
    case recordingDot
    case accentDot
    case chip(String, NotchIslandChipStyle, NotchIslandAction)
}

enum NotchIslandDrop: Equatable {
    case dictationTarget(appName: String?, microphone: String?)
    case dictationLoading(title: String, detail: String)
    case dictationMessage(NotchIslandDictationContent.Message)
    case justInserted(text: String, words: Int)
    case meetingPreparing(title: String, detail: String)
    case meetingControls(callAudioNote: NotchIslandMeetingContent.CallAudioNote?, systemAudioUnverified: Bool)
    case meetingPrompt(NotchIslandMeetingContent.Prompt)
    case meetingSaved(title: String?)
    case meetingError(title: String, message: String, canOpen: Bool)
    case callPrompt(title: String, detail: String)

    /// Identifies an auto-opened drop-down, so closing one keeps it closed
    /// until something new needs saying.
    var stickyKey: String {
        switch self {
        case .dictationMessage(let message): return "dictation-message:\(message.text)"
        case .meetingPrompt(let prompt): return "meeting-prompt:\(prompt.title)"
        case .meetingError(let title, let message, _): return "meeting-error:\(title)|\(message)"
        case .callPrompt(let title, _): return "call:\(title)"
        case .dictationTarget, .dictationLoading, .justInserted, .meetingPreparing,
             .meetingControls, .meetingSaved:
            return ""
        }
    }
}

struct NotchIslandLayout: Equatable {
    var left: [NotchIslandItem] = []
    var right: [NotchIslandItem] = []
    var drop: NotchIslandDrop?
    /// The drop-down opened by itself because something needs an answer.
    var dropIsSticky = false
    /// Transcription progress runs along the island's lower edge.
    var showsEdgeProgress = false

    var isEmpty: Bool { left.isEmpty && right.isEmpty && drop == nil }
}

/// The call-detected prompt's side of the island. A protocol so the capture
/// pill (compiled into the fast tests) does not pull the AppKit island in.
@MainActor
protocol NotchIslandCallPromptPresenting: AnyObject {
    var callActionHandler: ((NotchIslandAction) -> Void)? { get set }
    func updateCallPrompt(_ content: NotchIslandCallPromptContent?)
    func updateCallPromptSeconds(_ secondsLeft: Int)
}

// MARK: - The rules

enum NotchIslandPresentation {
    /// The auto-opened drop-down that is due right now, if any, ignoring
    /// whether the person closed it.
    static func stickyKey(
        dictation: NotchIslandDictationContent?,
        meeting: NotchIslandMeetingContent?,
        callPrompt: NotchIslandCallPromptContent?
    ) -> String? {
        stickyDrop(dictation: dictation, meeting: meeting, callPrompt: callPrompt)?.stickyKey
    }

    /// Composes the island from whatever is active. Dictation owns the right
    /// wing and the drop-down while it runs; a live meeting keeps the left
    /// wing. Messages and prompts open the drop-down by themselves unless the
    /// person closed that one (`collapsedStickyKey`).
    static func layout(
        dictation: NotchIslandDictationContent?,
        meeting: NotchIslandMeetingContent?,
        callPrompt: NotchIslandCallPromptContent?,
        recentInsert: NotchIslandRecentInsert?,
        expanded: Bool,
        collapsedStickyKey: String? = nil
    ) -> NotchIslandLayout {
        var result = NotchIslandLayout()

        let sticky = stickyDrop(dictation: dictation, meeting: meeting, callPrompt: callPrompt)
        if let sticky, sticky.stickyKey != collapsedStickyKey || expanded {
            result.drop = sticky
            result.dropIsSticky = true
        } else if expanded {
            result.drop = onDemandDrop(dictation: dictation, meeting: meeting, recentInsert: recentInsert)
        }

        let dropIsOpen = result.drop != nil
        if let dictation, let meeting, meeting.isRecording {
            result.left = meetingLeading
            result.right = dictationMini(dictation)
        } else if let dictation {
            (result.left, result.right) = dictationWings(dictation)
        } else if callPrompt != nil, !(meeting?.isBusy ?? false) {
            result.left = [.symbol(.video, .accent), .text("Call", .title)]
            result.right = dropIsOpen
                ? [.live(.callSeconds, .secondary)]
                : [.chip("Record", .destructive, .callRecord)]
        } else if let meeting {
            (result.left, result.right) = meetingWings(meeting, dropIsOpen: dropIsOpen)
        } else if let recentInsert {
            result.left = [.symbol(.check, .accent), .text(recentInsert.title, .title)]
            let words = recentInsert.words
            result.right = words > 0 ? [.text(words == 1 ? "1 word" : "\(words) words", .secondary)] : []
        }

        if dropIsOpen {
            // The drop-down carries the buttons; the wings only report status,
            // so nothing is offered twice.
            result.left = result.left.map(statusOnly)
            result.right = result.right.map(statusOnly)
        }
        if case .transcribing? = meeting?.phase, dictation == nil, !dropIsOpen {
            result.showsEdgeProgress = true
        }
        return result
    }

    static func wordCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    static func timerText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// A short wing label for a dictation message; the drop-down has the rest.
    static func messageLabel(_ message: NotchIslandDictationContent.Message) -> String {
        switch message.tone {
        case .error:
            return "Dictation"
        case .notice:
            return message.text.hasPrefix("Pasted") ? "Pasted" : "Copied"
        case .saved:
            return "Saved"
        case .noSpeech:
            return "No speech"
        }
    }

    // MARK: Drops

    private static func stickyDrop(
        dictation: NotchIslandDictationContent?,
        meeting: NotchIslandMeetingContent?,
        callPrompt: NotchIslandCallPromptContent?
    ) -> NotchIslandDrop? {
        if let dictation, case .message(let message) = dictation.phase {
            return .dictationMessage(message)
        }
        // A prompt waits while a dictation runs; it opens once the words land.
        guard dictation == nil else { return nil }
        if let callPrompt {
            return .callPrompt(title: callPrompt.title, detail: callPrompt.detail)
        }
        if let prompt = meeting?.prompt {
            return .meetingPrompt(prompt)
        }
        if case .error(let title, let message, let canOpen)? = meeting?.phase {
            return .meetingError(title: title, message: message, canOpen: canOpen)
        }
        return nil
    }

    private static func onDemandDrop(
        dictation: NotchIslandDictationContent?,
        meeting: NotchIslandMeetingContent?,
        recentInsert: NotchIslandRecentInsert?
    ) -> NotchIslandDrop? {
        if let dictation {
            switch dictation.phase {
            case .starting, .listening:
                return .dictationTarget(appName: dictation.targetAppName, microphone: dictation.microphoneName)
            case .loading(let title, let detail, _):
                return .dictationLoading(title: title, detail: detail)
            case .writing, .success, .message:
                return nil
            }
        }
        if let recentInsert, let text = recentInsert.text, !text.isEmpty {
            return .justInserted(text: text, words: recentInsert.words)
        }
        guard let meeting else { return nil }
        switch meeting.phase {
        case .recording:
            return .meetingControls(
                callAudioNote: meeting.callAudioNote,
                systemAudioUnverified: meeting.systemAudioUnverified
            )
        case .preparing(let title, let detail):
            return .meetingPreparing(title: title, detail: detail)
        case .saved(let title):
            return .meetingSaved(title: title)
        case .none, .transcribing, .error:
            return nil
        }
    }

    // MARK: Wings

    private static func dictationWings(
        _ dictation: NotchIslandDictationContent
    ) -> ([NotchIslandItem], [NotchIslandItem]) {
        switch dictation.phase {
        case .starting:
            return ([.accentDot], [])
        case .loading(let title, _, let progress):
            let right: [NotchIslandItem] = progress == nil ? [] : [.live(.loadingPercent, .secondary)]
            return ([progress == nil ? .spinner : .loadingRing, .text(title, .title)], right)
        case .listening:
            let notice = dictation.notice
            if notice.isEmpty {
                return ([.symbol(.mic, .accent), .text("Listening", .title)],
                        [.dictationBars(count: 9), .live(.dictationTimer, .secondary)])
            }
            if DictationSessionCapWarningPolicy.isCapNotice(notice) {
                let countdown = notice.components(separatedBy: " · ").first ?? notice
                return ([.symbol(.mic, .accent), .text("Listening", .title)],
                        [.dictationBars(count: 9), .text(countdown, .warning)])
            }
            return ([.symbol(.warning, .warning), .text(notice, .warning)], [.dictationBars(count: 9)])
        case .writing:
            return ([.dots, .text("Writing", .title)], [.shimmer])
        case .success(let title):
            return ([.symbol(.check, .accent), .text(title, .title)], [])
        case .message(let message):
            return ([messageSymbol(message.tone), .text(messageLabel(message), .title)], [])
        }
    }

    private static func dictationMini(_ dictation: NotchIslandDictationContent) -> [NotchIslandItem] {
        switch dictation.phase {
        case .starting, .loading:
            return [.accentDot]
        case .listening:
            return [.symbol(.mic, .accent), .dictationBars(count: 6)]
        case .writing:
            return [.dots]
        case .success:
            return [.symbol(.check, .accent)]
        case .message(let message):
            return [messageSymbol(message.tone)]
        }
    }

    private static func messageSymbol(_ tone: NotchIslandDictationContent.Message.Tone) -> NotchIslandItem {
        switch tone {
        case .error, .noSpeech:
            return .symbol(.warning, .warning)
        case .notice:
            return .symbol(.clipboard, .accent)
        case .saved:
            return .symbol(.saved, .accent)
        }
    }

    private static let meetingLeading: [NotchIslandItem] = [.recordingDot, .live(.meetingTimer, .title)]

    private static func meetingWings(
        _ meeting: NotchIslandMeetingContent,
        dropIsOpen: Bool
    ) -> ([NotchIslandItem], [NotchIslandItem]) {
        switch meeting.phase {
        case .none:
            return ([.symbol(.video, .accent), .text("Meeting", .title)], [])
        case .preparing(let title, _):
            return ([.spinner, .text(title, .title)], [])
        case .recording:
            var right: [NotchIslandItem]
            if meeting.systemAudioUnverified {
                right = [.text("Audio unverified", .warning)]
            } else {
                switch meeting.callAudioNote {
                case .off?:
                    right = [.chip("Mic only", .warning, .meetingCallAudio)]
                case .onForNextMeeting?:
                    right = [.text("Call audio on", .secondary)]
                case nil:
                    right = [.meetingMeters]
                }
            }
            if meeting.prompt != nil, !dropIsOpen {
                right.insert(.symbol(.warning, .warning), at: 0)
            }
            return (meetingLeading, right)
        case .transcribing(let progress, let detail):
            let right: [NotchIslandItem] = detail.isEmpty ? [] : [.text(detail, .secondary)]
            return ([progress == nil ? .spinner : .transcriptionRing, .text("Transcribing", .title)], right)
        case .saved:
            return ([.symbol(.check, .accent), .text("Saved", .title)], [.chip("Open", .plain, .meetingOpen)])
        case .error:
            return ([.symbol(.warning, .warning), .text("Meeting not saved", .title)], [])
        }
    }

    private static func statusOnly(_ item: NotchIslandItem) -> NotchIslandItem {
        guard case .chip(let title, let style, _) = item else { return item }
        return .text(title, style == .warning || style == .destructive ? .warning : .secondary)
    }
}
