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
        /// The words of a dictation that didn't paste, shown so the user
        /// knows what ⌘V will put in.
        var preview: String? = nil
        /// Seconds until the message closes on its own, drawn as a ring
        /// around Dismiss.
        var dismissSeconds: Double? = nil
        /// The line under the words; nil reads "Click where it goes, then
        /// press ⌘V."
        var hint: String? = nil

        /// A dictation that didn't paste: its words ride along as the preview.
        struct NotPasted: Equatable {
            var text: String
            var actionTitle: String
            var hint: String?
            var dismissSeconds: Double
        }

        /// Builds the message for a finished dictation. With a not-pasted
        /// dictation, the words become the preview and the not-pasted action,
        /// hint and countdown replace the plain error action.
        static func make(tone: Tone, text: String, errorActionTitle: String?, notPasted: NotPasted?) -> Message {
            guard let notPasted else {
                return Message(tone: tone, text: text, actionTitle: errorActionTitle)
            }
            return Message(
                tone: tone,
                text: text,
                actionTitle: notPasted.actionTitle,
                preview: nil,
                dismissSeconds: notPasted.dismissSeconds,
                hint: notPasted.hint
            )
        }
    }

    var phase: Phase
    /// The Esc-confirm prompt or the 15-minute cap countdown, while listening.
    var notice: String = ""
    var targetAppName: String?
    /// The live preview is streaming this take, so the hover shows the
    /// words as they're spoken (set by the island from
    /// `LiveDictationCaptions`).
    var showsLivePreview = false
}

struct NotchIslandMeetingContent: Equatable {
    enum Phase: Equatable {
        /// Nothing is recording; only a prompt is up (the missed-call nudge).
        case none
        case preparing(title: String, detail: String)
        case recording
        case transcribing(progress: Double?, detail: String)
        case saved(title: String?)
        /// `grantsSystemAudio`: the start failed on a confirmed System Audio
        /// Recording denial, so the drop-down offers the Settings pane.
        case error(title: String, message: String, canOpen: Bool, grantsSystemAudio: Bool = false)
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
    /// The island skipped the "can't hear the other side" question so the
    /// meeting could start at once; ask it now, from the island, once.
    var asksAboutCallAudio = false
    /// "Live transcript" is on: the recording drop-down shows the
    /// conversation so far instead of the level lanes.
    var showsLiveTranscript = false

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

/// A finished meeting asking who was on it. The rows, typing and playback
/// live in `NotchIslandSpeakerReviewView`; this only says which review is up
/// and whether it is still asking or showing its result.
struct NotchIslandSpeakerReviewContent: Equatable {
    enum Stage: Equatable {
        case naming
        /// Names were saved. `leftForLater` voices wait in Speakers.
        case done(leftForLater: Int)
    }

    var reviewID: UUID
    var meetingTitle: String?
    var stage: Stage
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
    case meetingCallAudioDismiss
    case meetingOpen
    case meetingDismissError
    /// Copy all on the live transcript.
    case meetingCopyTranscript
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
        case .copyLastDictation, .pasteLastDictation, .meetingCopyTranscript:
            return .island
        case .meetingStop, .meetingPrimary, .meetingSecondary, .meetingTertiary,
             .meetingCallAudio, .meetingCallAudioDismiss, .meetingOpen, .meetingDismissError:
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
    /// Hovering a dictation: the words so far (when the live preview is
    /// streaming), then Cancel and "Insert into <app>". While the words are
    /// being written only the words stay.
    case dictationTarget(appName: String?, showsPreview: Bool, isWriting: Bool = false)
    case dictationLoading(title: String, detail: String)
    case dictationMessage(NotchIslandDictationContent.Message)
    case justInserted(text: String, words: Int)
    case meetingPreparing(title: String, detail: String)
    case meetingControls(callAudioNote: NotchIslandMeetingContent.CallAudioNote?, systemAudioUnverified: Bool, showsTranscript: Bool = false)
    case meetingPrompt(NotchIslandMeetingContent.Prompt)
    case meetingSaved(title: String?)
    case meetingError(title: String, message: String, canOpen: Bool, grantsSystemAudio: Bool = false)
    case callPrompt(title: String, detail: String)
    case speakerReview(NotchIslandSpeakerReviewContent)
    /// Recording already started with only the mic; offer call audio.
    case meetingCallAudioAsk

    /// Identifies an auto-opened drop-down, so closing one keeps it closed
    /// until something new needs saying.
    var stickyKey: String {
        switch self {
        case .dictationMessage(let message): return "dictation-message:\(message.text)\(message.preview.map { "|\($0)" } ?? "")"
        case .meetingPrompt(let prompt): return "meeting-prompt:\(prompt.title)"
        case .meetingError(let title, let message, _, _): return "meeting-error:\(title)|\(message)"
        case .callPrompt(let title, _): return "call:\(title)"
        case .speakerReview(let review): return "speaker-review:\(review.reviewID.uuidString)"
        case .meetingCallAudioAsk: return "meeting-call-audio-ask"
        case .dictationTarget, .dictationLoading, .justInserted, .meetingPreparing,
             .meetingControls, .meetingSaved:
            return ""
        }
    }

    /// The dictation hover's drop-down while the take is still spoken. The
    /// island keeps that one built between hovers, so each hover only puts
    /// it back; every other drop-down is built when it opens.
    var staysBuiltBetweenHovers: Bool {
        if case .dictationTarget(_, _, false) = self { return true }
        return false
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

    /// "Who was on this call?" is on screen (not waiting behind a dictation,
    /// a call prompt, or a meeting that is starting or recording).
    var showsSpeakerReview: Bool {
        if case .speakerReview? = drop { return true }
        return false
    }
}

/// The call-detected prompt's side of the island. A protocol so the capture
/// pill (compiled into the fast tests) does not pull the AppKit island in.
@MainActor
protocol NotchIslandCallPromptPresenting: AnyObject {
    var callActionHandler: ((NotchIslandAction) -> Void)? { get set }
    /// The pointer entered or left the island while the call prompt is up,
    /// so the prompt's own timeout can pause with the ring around Not now.
    var callHoverHandler: ((Bool) -> Void)? { get set }
    /// The call prompt went on or off screen (it waits behind a dictation),
    /// so its timeout only runs while someone can see it.
    var callVisibilityHandler: ((Bool) -> Void)? { get set }
    func updateCallPrompt(_ content: NotchIslandCallPromptContent?)
    func updateCallPromptSeconds(_ secondsLeft: Int)
}

// MARK: - The rules

/// How a new meeting snapshot differs from the one on screen.
enum NotchIslandMeetingUpdate: Equatable {
    case unchanged
    /// Only the elapsed time moved. The layout never reads it (the timer
    /// text comes from the live values), so no rebuild is needed.
    case durationOnly
    case full
}

enum NotchIslandPresentation {
    /// Whether a meeting snapshot needs a full island render or only a
    /// timer refresh.
    static func meetingUpdate(
        from old: NotchIslandMeetingContent?,
        to new: NotchIslandMeetingContent?
    ) -> NotchIslandMeetingUpdate {
        guard old != new else { return .unchanged }
        guard var old, let new else { return .full }
        old.duration = new.duration
        return old == new ? .durationOnly : .full
    }

    /// The auto-opened drop-down that is due right now, if any, ignoring
    /// whether the person closed it.
    static func stickyKey(
        dictation: NotchIslandDictationContent?,
        meeting: NotchIslandMeetingContent?,
        callPrompt: NotchIslandCallPromptContent?,
        speakerReview: NotchIslandSpeakerReviewContent? = nil
    ) -> String? {
        stickyDrop(dictation: dictation, meeting: meeting, callPrompt: callPrompt, speakerReview: speakerReview)?.stickyKey
    }

    /// The call prompt is on screen unless a dictation (or its message) has
    /// the island; it waits behind one and comes back once the words land.
    static func callPromptIsOnScreen(
        dictation: NotchIslandDictationContent?,
        callPrompt: NotchIslandCallPromptContent?
    ) -> Bool {
        callPrompt != nil && dictation == nil
    }

    /// The island keeps the keyboard only while "Who was on this call?" is
    /// asking for names and is on screen. Once naming ends, the review is
    /// replaced, or something else covers it, the keyboard goes back to the
    /// app the person was typing in.
    static func speakerReviewKeepsKeyboard(
        _ speakerReview: NotchIslandSpeakerReviewContent?,
        onScreen: Bool
    ) -> Bool {
        speakerReview?.stage == .naming && onScreen
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
        collapsedStickyKey: String? = nil,
        speakerReview: NotchIslandSpeakerReviewContent? = nil
    ) -> NotchIslandLayout {
        var result = NotchIslandLayout()

        let sticky = stickyDrop(dictation: dictation, meeting: meeting, callPrompt: callPrompt, speakerReview: speakerReview)
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
        } else if let speakerReview, !(meeting?.isBusy ?? false) {
            result.left = [.symbol(.check, .accent), .text(speakerReview.meetingTitle ?? "Saved", .title)]
            result.right = []
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
            // A notice with the words ("Not pasted", "Maybe pasted") names itself.
            if message.preview != nil { return message.text }
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
        callPrompt: NotchIslandCallPromptContent?,
        speakerReview: NotchIslandSpeakerReviewContent?
    ) -> NotchIslandDrop? {
        if let dictation, case .message(let message) = dictation.phase {
            return .dictationMessage(message)
        }
        // A prompt waits while a dictation runs; it opens once the words land.
        guard dictation == nil else { return nil }
        if let callPrompt {
            return .callPrompt(title: callPrompt.title, detail: callPrompt.detail)
        }
        // Who was on the call asks once the meeting is saved, never while a
        // new one is starting or recording.
        if let speakerReview, !(meeting?.isBusy ?? false) {
            return .speakerReview(speakerReview)
        }
        if let prompt = meeting?.prompt {
            return .meetingPrompt(prompt)
        }
        if case .error(let title, let message, let canOpen, let grantsSystemAudio)? = meeting?.phase {
            return .meetingError(title: title, message: message, canOpen: canOpen, grantsSystemAudio: grantsSystemAudio)
        }
        if let meeting, meeting.isRecording, meeting.asksAboutCallAudio, meeting.callAudioNote == .off {
            return .meetingCallAudioAsk
        }
        return nil
    }

    private static func onDemandDrop(
        dictation: NotchIslandDictationContent?,
        meeting: NotchIslandMeetingContent?,
        recentInsert: NotchIslandRecentInsert?
    ) -> NotchIslandDrop? {
        // A recording meeting owns the hover: a dictation inside it, and the
        // dictation that just landed, never take it over.
        let meetingRecords = meeting?.isRecording == true
        if let dictation, !meetingRecords {
            switch dictation.phase {
            case .starting, .listening:
                return .dictationTarget(appName: dictation.targetAppName, showsPreview: dictation.showsLivePreview)
            case .loading(let title, let detail, _):
                return .dictationLoading(title: title, detail: detail)
            case .writing, .success:
                // The words stay while they're written, then turn into the
                // real text.
                return dictation.showsLivePreview
                    ? .dictationTarget(appName: dictation.targetAppName, showsPreview: true, isWriting: true)
                    : nil
            case .message:
                return nil
            }
        }
        if !meetingRecords, let recentInsert, let text = recentInsert.text, !text.isEmpty {
            return .justInserted(text: text, words: recentInsert.words)
        }
        guard let meeting else { return nil }
        switch meeting.phase {
        case .recording:
            return .meetingControls(
                callAudioNote: meeting.callAudioNote,
                systemAudioUnverified: meeting.systemAudioUnverified,
                showsTranscript: meeting.showsLiveTranscript
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
            return ([.symbol(.video, .accent), .text("Missed call", .title)], [])
        case .preparing(let title, _):
            return ([.spinner, .text(title, .title)], [])
        case .recording:
            var right: [NotchIslandItem]
            if meeting.systemAudioUnverified {
                right = [.text("Can't confirm call", .warning)]
            } else {
                switch meeting.callAudioNote {
                case .off?:
                    right = [.chip("Mic only", .warning, .meetingCallAudio)]
                case .onForNextMeeting?:
                    right = [.text("Call audio next time", .secondary)]
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
            return ([.symbol(.warning, .warning), .text("Meeting failed", .title)], [])
        }
    }

    private static func statusOnly(_ item: NotchIslandItem) -> NotchIslandItem {
        guard case .chip(let title, let style, _) = item else { return item }
        return .text(title, style == .warning || style == .destructive ? .warning : .secondary)
    }
}

// MARK: - Live transcript while the drop-down is closed

extension NotchIslandPresentation {
    /// How often a closed drop-down's live transcript catches up.
    static let hiddenTranscriptFlushInterval: TimeInterval = 5

    /// Whether a closed drop-down's live transcript applies this update now.
    /// At most every 5 s, so opening lays out at most 5 s of text. A trim
    /// rebuilds the whole text, so that one still waits for the open.
    static func flushesHiddenTranscript(
        now: TimeInterval,
        lastFlush: TimeInterval?,
        trimGeneration: Int,
        renderedTrimGeneration: Int
    ) -> Bool {
        guard trimGeneration == renderedTrimGeneration else { return false }
        guard let lastFlush else { return true }
        return now - lastFlush >= hiddenTranscriptFlushInterval
    }
}
