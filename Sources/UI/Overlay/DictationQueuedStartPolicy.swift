import Foundation

/// A dictation press that lands while the previous take is still being
/// transcribed or pasted.
///
/// That press used to be refused with "Still finishing the last dictation.
/// Try again in a moment." Now the press is remembered and the new take starts
/// the moment the last one finishes, as long as that happens within a short
/// wait. Past the wait it falls back to the old message.
enum DictationQueuedStartPolicy {
    /// How long a remembered press waits for the last take to finish.
    static let waitSeconds: Double = 2
    /// How often the wait checks whether the last take has finished.
    static let pollIntervalNanos: UInt64 = 50_000_000

    /// Shown in the transcribing pill while the press waits, so it doesn't
    /// look ignored.
    static let waitingNotice = "Next dictation starts after this"

    enum Decision: Equatable {
        case keepWaiting
        case start
        case giveUp
    }

    static func decision(previousStillFinishing: Bool, secondsWaited: Double) -> Decision {
        if !previousStillFinishing { return .start }
        return secondsWaited >= waitSeconds ? .giveUp : .keepWaiting
    }

    /// Only a real press of a start shortcut is remembered. A menu click or an
    /// overlay button keeps the old "still finishing" message, since there is
    /// no held key or toggle for the person to expect a start from.
    static func remembersPress(shortcutMode: DictationShortcutMode?) -> Bool {
        shortcutMode != nil
    }
}
