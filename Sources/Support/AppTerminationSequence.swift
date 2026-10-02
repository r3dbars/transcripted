import Foundation

/// The order of the app's async Quit cleanup, once AppKit has been told
/// `.terminateLater`.
///
/// Dictation goes first. If it can't promise its audio is saved, Quit is
/// refused: cleanup admission resets so a later Quit can try again, every
/// pending request gets `false`, and nothing else shuts down. Otherwise the
/// meeting is prepared, app state shuts down, the persistent dictation input
/// is restored, and buffered local events are flushed, all before AppKit hears
/// `true`.
///
/// `TranscriptedAppDelegate.applicationShouldTerminate` builds the steps from
/// the real controllers.
@MainActor
enum AppTerminationSequence {
    struct Steps {
        var finishDictationForTermination: @MainActor () async -> Bool
        var resetCleanupAdmission: @MainActor () -> Void
        var prepareMeetingForTermination: @MainActor () async -> Void
        var shutDownAppState: @MainActor () -> Void
        var stopAndRestorePersistentInput: @MainActor () async -> Void
        var flushLocalEvents: @MainActor () async -> Void
        var markCleanupFinished: @MainActor () -> Void
        var replyToPendingRequests: @MainActor (_ shouldTerminate: Bool) -> Void
    }

    /// Returns whether Quit went ahead.
    @discardableResult
    static func run(_ steps: Steps) async -> Bool {
        guard await steps.finishDictationForTermination() else {
            // An unresolved audio checkpoint may be the only copy of this
            // recording. Leave stop/finalization in flight and let a later
            // Quit re-enter after replying to every pending request.
            steps.resetCleanupAdmission()
            steps.replyToPendingRequests(false)
            return false
        }
        await steps.prepareMeetingForTermination()
        steps.shutDownAppState()
        await steps.stopAndRestorePersistentInput()
        await steps.flushLocalEvents()
        steps.markCleanupFinished()
        steps.replyToPendingRequests(true)
        return true
    }
}
