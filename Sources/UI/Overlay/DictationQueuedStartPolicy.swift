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
        /// The last take ended with a message (a failure, or "press ⌘V").
        /// Leave it up instead of starting over it.
        case dropForMessage
    }

    static func decision(
        previousStillFinishing: Bool,
        previousLeftMessage: Bool,
        secondsWaited: Double
    ) -> Decision {
        if !previousStillFinishing {
            return previousLeftMessage ? .dropForMessage : .start
        }
        return secondsWaited >= waitSeconds ? .giveUp : .keepWaiting
    }

    /// Only a real press of a start shortcut is remembered. A menu click or an
    /// overlay button keeps the old "still finishing" message, since there is
    /// no held key or toggle for the person to expect a start from.
    static func remembersPress(shortcutMode: DictationShortcutMode?) -> Bool {
        shortcutMode != nil
    }
}

extension DictationQueuedStartPolicy {
    /// The last take left a message the next take must not start over: a
    /// failure, or a "press ⌘V" notice with its Transcribe It or Paste It
    /// button. A passing note (no speech heard, press Return to send) can
    /// give way.
    static func previousLeftMessage(
        isDrafting: Bool,
        errorMessage: String,
        messageCanGiveWayToNextStart: Bool
    ) -> Bool {
        isDrafting && !errorMessage.isEmpty && !messageCanGiveWayToNextStart
    }

    /// While the last take is still on screen transcribing, an error would
    /// cover its pill (and can hide it and turn off Esc), so a dropped press
    /// only says "still finishing" once nothing is dictating.
    static func showsDropMessage(requested: Bool, isDictating: Bool) -> Bool {
        requested && !isDictating
    }

    static let droppedFailureKind = "previous_dictation_transcribing"

    /// Forgets a remembered press. It's counted then as a refused start, the
    /// same as the old "still finishing" refusal was, so a press that waited
    /// and never started is never lost from the start funnel.
    struct DropSteps {
        var countRequest: () -> Void
        var countRefusal: (_ failureKind: String) -> Void
        var showStillFinishing: () -> Void
    }

    static func drop(showMessage: Bool, isDictating: Bool, _ steps: DropSteps) {
        steps.countRequest()
        steps.countRefusal(droppedFailureKind)
        if showsDropMessage(requested: showMessage, isDictating: isDictating) {
            steps.showStillFinishing()
        }
    }
}

/// Keeps a press from queueing a new take while Quit waits for the current
/// one to finish.
///
/// `DictationTerminationFinisher` shuts it when Quit starts. Once Quit is
/// admitted it stays shut until the app is gone; a refused Quit opens it
/// again so presses can queue.
struct DictationQueuedStartGate {
    private(set) var isTerminating = false

    func admitsPress(shortcutMode: DictationShortcutMode?, previousIsFinishing: () -> Bool) -> Bool {
        guard !isTerminating,
              DictationQueuedStartPolicy.remembersPress(shortcutMode: shortcutMode) else { return false }
        return previousIsFinishing()
    }

    mutating func setTerminating(_ shut: Bool) {
        isTerminating = shut
    }
}
