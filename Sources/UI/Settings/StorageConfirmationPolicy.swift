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
        "Your transcripts and saved voices stay, and starred meetings keep their audio. Meeting audio older than \(window.title) is deleted now, and again automatically from then on."
    }

    static func dictationAudioMessage(for window: DictationAudioKeepWindow) -> String {
        window == .off
            ? "Your dictation text stays. All kept dictation audio is deleted now, and new dictations won't keep any."
            : "Your dictation text stays. Dictation audio older than \(window.title) is deleted now, and again automatically from then on."
    }
}

/// The one audio-window change a Storage pick or prompt answer makes. A meeting
/// choice can only ever produce `.applyMeeting` and a dictation choice only
/// `.applyDictation`, so one row can't change the other's window.
enum StorageRetentionEffect: Equatable {
    case none
    case applyMeeting(AudioRetentionWindow)
    case applyDictation(DictationAudioKeepWindow)

    /// Hands the window to the matching setting's apply callback, and only that one.
    func perform(
        applyMeeting: (AudioRetentionWindow) -> Void,
        applyDictation: (DictationAudioKeepWindow) -> Void
    ) {
        switch self {
        case .none:
            break
        case .applyMeeting(let window):
            applyMeeting(window)
        case .applyDictation(let window):
            applyDictation(window)
        }
    }
}

/// The Storage page's pending "Delete meeting audio after" and "Keep dictation
/// audio" choices, each in its own slot. Foundation-pure so the pick → prompt →
/// Delete/Cancel flow can be tested without SwiftUI.
struct StorageRetentionPrompts: Equatable {
    private(set) var pendingMeeting: AudioRetentionWindow?
    private(set) var pendingDictation: DictationAudioKeepWindow?

    init(pendingMeeting: AudioRetentionWindow? = nil, pendingDictation: DictationAudioKeepWindow? = nil) {
        self.pendingMeeting = pendingMeeting
        self.pendingDictation = pendingDictation
    }

    /// A pick on the meeting row. A window that can delete audio waits for the
    /// prompt; any other change applies right away.
    mutating func pickMeeting(_ window: AudioRetentionWindow, current: AudioRetentionWindow) -> StorageRetentionEffect {
        guard window != current else { return .none }
        if StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(from: current, to: window) {
            pendingMeeting = window
            return .none
        }
        return .applyMeeting(window)
    }

    /// A pick on the dictation row. A shorter window (or Don't keep) can
    /// delete audio already kept, so it waits for the prompt.
    mutating func pickDictation(_ window: DictationAudioKeepWindow, current: DictationAudioKeepWindow) -> StorageRetentionEffect {
        guard window != current else { return .none }
        if current.deletesKeptAudio(switchingTo: window) {
            pendingDictation = window
            return .none
        }
        return .applyDictation(window)
    }

    /// What the destructive button on `slot`'s prompt applies. It reads only
    /// that slot, and is built with the alert so it doesn't depend on whether
    /// SwiftUI runs the button before or after dismissal.
    func confirmEffect(for slot: StorageConfirmationSlot) -> StorageRetentionEffect {
        switch slot {
        case .meetingAudio:
            return pendingMeeting.map(StorageRetentionEffect.applyMeeting) ?? .none
        case .dictationAudio:
            return pendingDictation.map(StorageRetentionEffect.applyDictation) ?? .none
        case .captureLibrary, .freeUpSpace:
            return .none
        }
    }

    /// The prompt for `slot` closed (either button). Clears only that slot.
    mutating func dismiss(_ slot: StorageConfirmationSlot) {
        switch slot {
        case .meetingAudio:
            pendingMeeting = nil
        case .dictationAudio:
            pendingDictation = nil
        case .captureLibrary, .freeUpSpace:
            break
        }
    }

    /// The presenter's view of these prompts, merged with the page's others.
    func states(hasCaptureLibraryChoice: Bool = false, wantsFreeUpSpace: Bool = false) -> StorageConfirmationStates {
        StorageConfirmationStates(
            hasCaptureLibraryChoice: hasCaptureLibraryChoice,
            pendingMeetingAudioWindow: pendingMeeting,
            pendingDictationAudioWindow: pendingDictation,
            wantsFreeUpSpace: wantsFreeUpSpace
        )
    }
}
