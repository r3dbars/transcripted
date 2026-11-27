import Foundation

/// When the meeting live transcript's launch prewarm loads its model, given
/// what the dictation preview (which loads the same EOU model) is doing.
/// The point: never compile a second EOU copy alongside the dictation
/// model's own compile or a take, but never wait forever either, so the
/// first meeting isn't cold. Plain values in, a step out.
enum LiveTranscriptPrewarmPolicy {
    /// The dictation preview's state. `notAttached` covers the preview being
    /// off (`TRANSCRIPTED_DICTATION_PREVIEW=off`) or an automated launch.
    enum Preview: Equatable, Sendable {
        case notAttached
        case off
        case preparing
        case ready
        case unavailable
    }

    /// The dictation model, as far as the preview's own load is concerned.
    enum Dictation: Equatable, Sendable {
        /// Downloading or loading: the preview loads once it's done.
        case loading
        /// Loaded (a take may be holding it): the preview loads once idle.
        case loaded
        /// Not loading, cached, or failed: nothing to wait for.
        case other
    }

    enum Step: Equatable, Sendable {
        /// The preview holds the model; its compile is cached.
        case skip
        case wait(Duration)
        case load
    }

    enum Outcome: Equatable, Sendable {
        case skipped
        case cancelled
        case load
    }

    /// How long the prewarm waits on the dictation model before loading
    /// anyway. A cold dictation-model compile on a base M1 fits well inside.
    static let dictationWaitLimit: Duration = .seconds(180)
    static let previewPreparingInterval: Duration = .seconds(1)
    static let dictationWaitInterval: Duration = .seconds(5)

    static func step(preview: Preview, dictation: Dictation, waited: Duration) -> Step {
        switch preview {
        case .ready:
            return .skip
        case .preparing:
            return .wait(previewPreparingInterval)
        case .off:
            guard dictation != .other, waited < dictationWaitLimit else { return .load }
            return .wait(dictationWaitInterval)
        case .notAttached, .unavailable:
            return .load
        }
    }

    /// Runs the policy until it settles. `sleep` and `isCancelled` are
    /// injected so tests drive it on a virtual clock.
    @MainActor
    static func settle(
        state: () -> (preview: Preview, dictation: Dictation),
        sleep: (Duration) async -> Void,
        isCancelled: () -> Bool
    ) async -> Outcome {
        var waited: Duration = .zero
        while !isCancelled() {
            let current = state()
            switch step(preview: current.preview, dictation: current.dictation, waited: waited) {
            case .skip:
                return .skipped
            case .load:
                return .load
            case .wait(let interval):
                await sleep(interval)
                // Only the dictation wait counts toward its limit; the
                // preview's own load is waited out as before.
                if current.preview == .off { waited += interval }
            }
        }
        return .cancelled
    }
}
