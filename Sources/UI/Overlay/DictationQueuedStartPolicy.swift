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

/// The wait behind a remembered press. It used to check every 50 ms; now it
/// checks when the last take's state changes (the controller's `isDictating`
/// or the router's `isTranscribing`), plus once when the wait's budget runs
/// out. Decisions and the 2 s budget are unchanged.
@MainActor
enum DictationQueuedStartWait {
    struct Steps {
        /// The decision for this many seconds waited, or nil when the press
        /// (or its controller) is gone.
        var evaluate: @MainActor (_ secondsWaited: Double) -> DictationQueuedStartPolicy.Decision?
        /// Calls `wake` on every change of the last take's state; returns the
        /// cancel. `wake` may run inside a `@Published` willSet, so it must
        /// only wake, never read state: the check runs on a later turn.
        var watchChanges: @MainActor (_ wake: @escaping @Sendable () -> Void) -> @MainActor () -> Void
        /// Seconds on the clock `requestedAt` is on (`systemUptime`).
        var now: @MainActor () -> Double
        var requestedAt: Double
        /// Sleeps up to this many nanoseconds. It may return early (or on
        /// cancel); the wait re-checks and re-arms when time is left.
        var sleep: @Sendable (_ nanoseconds: UInt64) async -> Void
    }

    /// Waits until the decision is no longer `.keepWaiting` and returns it,
    /// or returns nil when the task is cancelled or the press is gone.
    static func run(_ steps: Steps) async -> DictationQueuedStartPolicy.Decision? {
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stopWatching = steps.watchChanges { wake.yield() }
        var deadline: Task<Void, Never>?
        defer {
            stopWatching()
            deadline?.cancel()
            wake.finish()
        }
        var iterator = wakes.makeAsyncIterator()
        while !Task.isCancelled {
            let waited = steps.now() - steps.requestedAt
            guard let decision = steps.evaluate(waited) else { return nil }
            guard decision == .keepWaiting else { return decision }
            // Re-armed every pass: a sleep that ends early just re-checks.
            deadline?.cancel()
            let remaining = max(0, DictationQueuedStartPolicy.waitSeconds - waited)
            let nanos = UInt64((remaining * 1_000_000_000).rounded(.up))
            let sleep = steps.sleep
            deadline = Task {
                await sleep(nanos)
                if !Task.isCancelled { wake.yield() }
            }
            guard await iterator.next(isolation: #isolation) != nil else { return nil }
        }
        return nil
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
