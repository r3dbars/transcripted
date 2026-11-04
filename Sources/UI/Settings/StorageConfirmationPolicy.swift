import Foundation

/// One of the Storage page's confirmation prompts.
///
/// They share a single `.alert` presenter. Stacking several alert modifiers on
/// one SwiftUI view shadows all but the last (see `HomeRootAlertPolicy`), and
/// that silently killed the "Delete meeting audio after" and "Keep dictation
/// audio" confirmations: the picker set its pending window, no alert appeared,
/// and the segment snapped back to the old value.
enum StorageConfirmationSlot: String, Equatable {
    case captureLibrary
    case meetingAudio
    case dictationAudio
    case freeUpSpace
}

/// Which Storage confirmation states are currently set.
struct StorageConfirmationStates: Equatable {
    var hasCaptureLibraryChoice: Bool = false
    var pendingMeetingAudioWindow: AudioRetentionWindow? = nil
    var pendingDictationAudioWindow: DictationAudioKeepWindow? = nil
    var wantsFreeUpSpace: Bool = false
}

/// Routing and copy for the single Storage presenter. Foundation-pure so the
/// priority, dismissal and wording can be tested without SwiftUI.
enum StorageConfirmationPolicy {
    /// The prompt that should present, in priority order. Normally only one is
    /// set. The capture-library choice comes first because the parent owns it
    /// and it can arrive while the page is open; the others come from a click
    /// on this page. This is also the one slot dismissal clears.
    static func activeSlot(_ states: StorageConfirmationStates) -> StorageConfirmationSlot? {
        if states.hasCaptureLibraryChoice { return .captureLibrary }
        if states.pendingMeetingAudioWindow != nil { return .meetingAudio }
        if states.pendingDictationAudioWindow != nil { return .dictationAudio }
        if states.wantsFreeUpSpace { return .freeUpSpace }
        return nil
    }

    /// True when picking `window` on the meeting row should ask first.
    /// Any finite window can delete audio already on disk; Never cannot.
    static func meetingChoiceNeedsConfirmation(
        from current: AudioRetentionWindow,
        to window: AudioRetentionWindow
    ) -> Bool {
        guard window != current else { return false }
        return window.days != nil
    }

    static func title(for slot: StorageConfirmationSlot, states: StorageConfirmationStates) -> String {
        switch slot {
        case .captureLibrary:
            return "Bring your saved captures along?"
        case .meetingAudio:
            return "Delete old meeting audio?"
        case .dictationAudio:
            return states.pendingDictationAudioWindow == .off
                ? "Delete kept dictation audio?"
                : "Delete old dictation audio?"
        case .freeUpSpace:
            return "Free up space?"
        }
    }

    /// Body copy for the meeting and dictation prompts. The capture-library and
    /// free-up-space prompts keep their own copy at the call site.
    static func meetingAudioMessage(for window: AudioRetentionWindow) -> String {
        "Your transcripts stay, and starred meetings keep their audio. Meeting audio older than \(window.title) is deleted now, and again automatically from then on."
    }

    static func dictationAudioMessage(for window: DictationAudioKeepWindow) -> String {
        window == .off
            ? "Your dictation text stays. All kept dictation audio is deleted now, and new dictations won't keep any."
            : "Your dictation text stays. Dictation audio older than \(window.title) is deleted now, and again automatically from then on."
    }
}
