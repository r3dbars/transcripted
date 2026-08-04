// DictationSessionTypes.swift
// Pure, TranscriptedAppState-free types for DictationSession: the class
// declaration itself, the observable session-state enum, the wait-loop
// status/outcome value types, and the StartPathDecision policy.
//
// Split out of DictationSession.swift so the fast test runner
// (run-tests.sh) can compile and exercise these directly without pulling in
// TranscriptedAppState's whole-app dependency graph — the same constraint
// that keeps DictationSessionController itself out of the fast-test
// APP_SOURCES list (see the comment at the top of
// Tests/DictationSessionCapTests.swift). Everything that actually touches
// TranscriptedAppState/STTRouter lives in Sources/Speech/DictationSession.swift
// as an extension on the class declared here.
//
// `state` is intentionally plain `@Published var`, not `private(set)`:
// Swift's `private`/`fileprivate` access control is file-scoped, and the
// wait-loop extension that owns the real state transitions lives in the
// sibling DictationSession.swift file.

import Foundation

@MainActor
final class DictationSession: ObservableObject {
    /// Coarse, observable phase of the engine-facing half of a dictation
    /// session. This is intentionally coarser than `FloatingOverlayController
    /// .OverlayState` — it reflects engine control-flow, not panel
    /// presentation, and only covers the phases this type itself decides.
    enum State: Equatable {
        case idle
        case waitingForEngineRecovery
        case recording
        case failed
    }

    @Published var state: State = .idle

    /// Marks the start of a fresh session. Callers reset this whenever a new
    /// `startDictation` request begins, mirroring the controller's own
    /// `currentDictationSessionID` reset.
    func reset() {
        state = .idle
    }

    /// Snapshot of the recovery wait loop's progress, published at the same
    /// point the loop used to call `overlayController.showLoadingState`
    /// directly. The controller turns this into a `LoadingPresentation`.
    struct WaitStatus: Equatable {
        let elapsed: TimeInterval
        let deviceName: String
        let isRecovering: Bool
        let inputFormatReady: Bool
        let startAttempts: Int
    }

    /// Result of `waitForEngineAndStart`. `.aborted` covers every place the
    /// original loop silently `return`ed (task cancelled, session no longer
    /// active, or a start attempt succeeded but the session already ended
    /// while it was in flight) — the controller does nothing further for it.
    enum StartOutcome {
        case started(StartedInfo)
        case timedOut(TimedOutInfo)
        case aborted
    }

    struct StartedInfo: Equatable {
        let isRecoveryAttempt: Bool
        let waitedMs: Int
        let requestToRecordingMs: Int
        let startAttempts: Int
        let readinessRefreshes: Int
    }

    struct TimedOutInfo {
        let startAttempts: Int
        let readinessRefreshes: Int
        let recoveryStartAttempts: Int
        let forcedReadinessRecoveries: Int
        let cleanupPlan: DictationRecordingStartFailureCleanupPlan
    }

    /// Outcome of `waitForModelAndStart`. `.aborted` mirrors the original
    /// inline loop's early-return guard (`!Task.isCancelled && isDictating`)
    /// — the caller must not mutate its own task bookkeeping for it, since a
    /// superseding session may already have replaced it.
    enum ModelWarmupOutcome {
        case ready
        case failed(String)
        case timedOut
        case aborted
    }

    /// Which path `continueDictationStart` should take, classified purely
    /// from live `STTRouter` model-readiness reads. `decide` is a pure
    /// function of those two booleans so it is directly fast-testable —
    /// `startPathDecision(appState:)` in DictationSession.swift is just the
    /// STTRouter-reading convenience wrapper call sites use.
    enum StartPathDecision: Equatable {
        /// The recording model is already loaded — start the mic immediately.
        case immediate
        /// The model isn't loaded, but its files are already on disk — open
        /// the mic now and load the model concurrently.
        case concurrentWarmupThenImmediate
        /// Neither is true — wait out the full warmup before opening the mic.
        case fullWarmupRequired

        static func decide(
            isRecordingModelLoaded: Bool,
            selectedModelFilesAvailableLocally: Bool
        ) -> StartPathDecision {
            if isRecordingModelLoaded {
                return .immediate
            }
            if selectedModelFilesAvailableLocally {
                return .concurrentWarmupThenImmediate
            }
            return .fullWarmupRequired
        }
    }
}
