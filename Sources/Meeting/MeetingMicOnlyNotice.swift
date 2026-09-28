import Foundation

/// What the recording pill says while a meeting records only the user's mic.
///
/// After one Don't Allow, later meetings skip the question and record just
/// the mic (`MeetingMicOnlyChoicePreference`), and a mic-only meeting is not
/// marked degraded. Without this note nothing on screen says the other side
/// of a call isn't being recorded. It is a quiet label on the pill, never a
/// prompt: someone recording an in-person meeting by choice isn't nagged.
enum MeetingMicOnlyNotice: Equatable {
    /// Call audio is off for this recording. Tapping the note is the fix:
    /// the macOS box when macOS hasn't asked yet, System Settings otherwise.
    case callAudioOff
    /// Call audio was turned on while this recording ran. This recording
    /// stays mic only (it never built the system-audio tap); the next
    /// meeting records both sides.
    case callAudioOnForNextMeeting

    var diagnosticName: String {
        switch self {
        case .callAudioOff: return "call_audio_off"
        case .callAudioOnForNextMeeting: return "call_audio_on_next_meeting"
        }
    }
}

enum MeetingMicOnlyNoticePolicy {
    /// What tapping the "Mic only" note does, from macOS's current answer.
    enum TapAction: Equatable {
        /// macOS hasn't asked yet, so its own allow box can still appear.
        case showMacOSBox
        /// macOS already said no (or its answer can't be read). It won't
        /// ask twice, so the only way back is the System Settings pane.
        case openSettings
        /// Already on. Nothing to open; just show that it worked.
        case alreadyOn
    }

    /// Only a recording that never built the system-audio tap gets the note.
    /// "Turn It On" with no answer from macOS keeps the tap, so that one
    /// isn't mic only yet.
    static func initialNotice(capturesSystemAudio: Bool) -> MeetingMicOnlyNotice? {
        capturesSystemAudio ? nil : .callAudioOff
    }

    /// "Turn It On" with no answer from macOS keeps the tap, which can still
    /// raise the macOS box. If macOS reads denied once the recording is
    /// live, the tap hears nothing: say mic only, same as a chosen one.
    static func noticeAfterStart(
        current: MeetingMicOnlyNotice?,
        mayHaveRaisedMacOSBox: Bool,
        status: SystemAudioCaptureTCCStatus
    ) -> MeetingMicOnlyNotice? {
        guard current == nil, mayHaveRaisedMacOSBox, status == .denied else { return current }
        return .callAudioOff
    }

    /// The detected-call prompt only promises "only your side" when Record
    /// really will start mic only without asking: macOS said no and the
    /// user already picked Record Just My Mic. A denial without that choice
    /// still gets the question, which explains itself.
    static func detectedCallPromptSaysMicOnly(
        status: SystemAudioCaptureTCCStatus,
        micOnlyRemembered: Bool
    ) -> Bool {
        status == .denied && micOnlyRemembered
    }

    static func tapAction(for status: SystemAudioCaptureTCCStatus) -> TapAction {
        switch status {
        case .authorized: return .alreadyOn
        case .notDetermined: return .showMacOSBox
        case .denied, .unavailable: return .openSettings
        }
    }

    /// Folds a fresh read of macOS's answer into the note. Only an "on"
    /// answer changes it, and it never goes back: once access is on, the
    /// next meeting records both sides even if this one can't.
    static func notice(
        current: MeetingMicOnlyNotice?,
        afterStatus status: SystemAudioCaptureTCCStatus
    ) -> MeetingMicOnlyNotice? {
        guard current == .callAudioOff, status == .authorized else { return current }
        return .callAudioOnForNextMeeting
    }

    /// Re-read macOS's answer while the person may be in System Settings.
    /// Stops on its own once access is on or the recording ends.
    static func shouldKeepCheckingAccess(
        notice: MeetingMicOnlyNotice?,
        isRecording: Bool
    ) -> Bool {
        isRecording && notice == .callAudioOff
    }

    static let accessRecheckIntervalNanoseconds: UInt64 = 2_000_000_000
    /// About ten minutes of re-checks after a click.
    static let maxAccessRechecks = 300
}

/// Words for the note. Plain, short, and says what is and isn't recorded.
enum MeetingMicOnlyNoticeCopy {
    static func title(for notice: MeetingMicOnlyNotice) -> String {
        switch notice {
        case .callAudioOff: return "Mic only"
        case .callAudioOnForNextMeeting: return "Call audio on"
        }
    }

    static func tooltip(for notice: MeetingMicOnlyNotice) -> String {
        switch notice {
        case .callAudioOff:
            return "Only your mic is recording. Click to turn on call audio."
        case .callAudioOnForNextMeeting:
            return "Call audio is on. Your next meeting records everyone."
        }
    }

    static func accessibilityHelp(for notice: MeetingMicOnlyNotice) -> String {
        switch notice {
        case .callAudioOff:
            return "Turns on call audio: asks macOS, or opens System Audio Recording in System Settings."
        case .callAudioOnForNextMeeting:
            return "Nothing to do. Your next meeting records everyone."
        }
    }

    static func accessibilityLabel(for notice: MeetingMicOnlyNotice) -> String {
        switch notice {
        case .callAudioOff:
            return "Mic only. The other side of the call isn't being recorded. Turn on call audio."
        case .callAudioOnForNextMeeting:
            return "Call audio is on. This recording stays mic only. Your next meeting records everyone."
        }
    }

    /// The detected-call prompt says it before the meeting starts, in place
    /// of its usual detail line.
    static let detectedCallPromptDetail = "Call audio is off, so only your side will be recorded."

    /// Title and detail for the mid-meeting "not verified" / "unavailable"
    /// warning's Check Access button.
    static let checkAccessTitle = "Check Access"
    static let checkAccessAccessibilityLabel = "Open System Audio Recording settings"
    static let checkAccessTooltip = "Opens System Audio Recording in System Settings"
}

/// Which mid-meeting system-audio warnings get a Check Access button. Silence
/// alone is normal on a quiet call, and a recovered stream needs nothing.
/// When macOS says access is already on, the Settings pane would only show a
/// switch that's on, so the button isn't offered then.
enum MeetingSystemAudioCheckAccessPolicy {
    static func offersCheckAccess(
        for warning: MeetingSystemAudioDegradationWarning,
        status: SystemAudioCaptureTCCStatus
    ) -> Bool {
        guard status != .authorized else { return false }
        switch (warning.cause, warning.phase) {
        case (.unverified, _):
            return true
        case (.failure, .recovering), (.failure, .degraded):
            return true
        // This path only runs when macOS doesn't say access is on, and a tap
        // without access hears zeros: exactly what Check Access fixes.
        case (.unheardPlayback, .recovering), (.unheardPlayback, .degraded):
            return true
        case (.failure, .recovered), (.unheardPlayback, .recovered), (.silence, _), (.interruption, _):
            return false
        }
    }
}
