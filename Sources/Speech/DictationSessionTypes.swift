// DictationSessionTypes.swift
// Pure, TranscriptedAppState-free types for DictationSession: the class
// declaration itself, the wait-loop status/outcome value types, and the
// StartPathDecision policy.
//
// Split out of DictationSession.swift so the fast test runner
// (run-tests.sh) can compile and exercise these directly without pulling in
// TranscriptedAppState's whole-app dependency graph — the same constraint
// that keeps DictationSessionController itself out of the fast-test
// APP_SOURCES list (see the comment at the top of
// Tests/DictationSessionCapTests.swift). Everything that actually touches
// TranscriptedAppState/STTRouter lives in Sources/Speech/DictationSession.swift
// as an extension on the class declared here.

import Foundation

@MainActor
final class DictationSession: ObservableObject {
    /// Correlates the engine-start failure with its owning overlay attempt.
    var telemetryContext: [String: String] = [:]

    /// How this start prepared the process, for the diagnostics this type
    /// emits. `DictationSessionController.startDictation` sets it once per
    /// session, before any audio work, from `DictationStartReadinessPolicy`.
    /// Defaults to the foreground plan so a caller that never sets it behaves
    /// exactly as before issue #1743.
    var startReadinessProfile: DictationStartReadinessProfile = .foreground

    // NOTE: this type deliberately does NOT publish its own lifecycle/state
    // enum. `DictationSessionController.isDictating` plus the overlay's own
    // state remain the single source of truth for "is a dictation session
    // active right now" — an earlier version of this file added a parallel
    // `@Published var state` that only the wait-loop paths mutated (never
    // the fast start path, never stop/cancel), and nothing in production
    // read it. That's exactly the mirrored-mutable-state problem this
    // extraction is trying to avoid, so it was removed. If a real owner
    // for session state emerges later (e.g. once `stopDictationAndPaste`
    // moves here too and can route through it), reintroduce it then with
    // every lifecycle path — including the fast start/stop/cancel paths —
    // routed through it, not just the recovery wait loop.

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
        /// The model isn't loaded yet (files cached, still loading, or still
        /// downloading) — open the mic now and load the model concurrently.
        /// The stop path checkpoints the audio and then waits for the model
        /// before transcribing, so nothing said is lost to the wait.
        case concurrentWarmupThenImmediate
        /// The last load failed — retry it and show a clear error before
        /// opening the mic, instead of recording audio that can't be read.
        case fullWarmupRequired

        static func decide(
            isRecordingModelLoaded: Bool,
            recordingModelLoadFailed: Bool
        ) -> StartPathDecision {
            if isRecordingModelLoaded {
                return .immediate
            }
            if recordingModelLoadFailed {
                return .fullWarmupRequired
            }
            // Includes a first-run download: holding the start until the
            // model lands made a brand-new user's first dictation wait (and
            // a push-to-talk release cancel it) while ~600 MB downloaded.
            return .concurrentWarmupThenImmediate
        }
    }
}

/// Shared by fast and recovery starts. Recovery may prepare another attempt;
/// only the actual microphone start result can report recording success.
@MainActor
enum DictationRecordingStartAttempt {
    static func run(
        start: () async -> Bool,
        onFailure: (() async -> Void)? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let started = await start()
        if !started, !Task.isCancelled {
            await onFailure?()
        }
        return started
    }
}
