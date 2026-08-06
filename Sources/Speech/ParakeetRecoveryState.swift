import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct ParakeetRecoveryState: Equatable {
    private var epoch = SupersessionEpoch()
    private(set) var isRecovering: Bool = false
    private(set) var inputFormatReady: Bool = true

    var generation: UInt64 {
        epoch.snapshot().rawValue
    }

    var canStartRecording: Bool {
        !isRecovering && inputFormatReady
    }

    mutating func beginConfigChange() -> UInt64 {
        let generation = epoch.begin().rawValue
        isRecovering = true
        inputFormatReady = false
        return generation
    }

    mutating func markFormatUnready() {
        inputFormatReady = false
    }

    mutating func markStartFailed() {
        inputFormatReady = false
    }

    /// Marks the engine as ready without generation gating. Use only from non-Task
    /// contexts where no stale-generation race is possible (e.g. after a successful
    /// synchronous prewarm or after recording starts on the current generation).
    mutating func markFormatReady() {
        isRecovering = false
        inputFormatReady = true
    }

    mutating func reset() {
        epoch.invalidate()
        isRecovering = false
        inputFormatReady = true
    }

    mutating func cancelRecovery(generation: UInt64) -> Bool {
        guard currentToken(matching: generation) != nil, isRecovering else { return false }
        reset()
        return true
    }

    mutating func finishRecovery(success: Bool, generation: UInt64) -> Bool {
        guard let token = currentToken(matching: generation), epoch.finishIfCurrent(token) else {
            return false
        }
        isRecovering = false
        inputFormatReady = success
        return true
    }

    mutating func timeoutRecovery(generation: UInt64) -> Bool {
        guard let token = currentToken(matching: generation), isRecovering,
              epoch.supersedeIfCurrent(token) else { return false }
        isRecovering = false
        inputFormatReady = false
        return true
    }

    func isStale(generation: UInt64) -> Bool {
        currentToken(matching: generation) == nil
    }

    private func currentToken(matching generation: UInt64) -> SupersessionEpoch.Token? {
        let token = epoch.snapshot()
        guard token.rawValue == generation else { return nil }
        return token
    }
}

struct ParakeetCategoricalAudioRoute: Equatable {
    let inputDeviceClass: String
    let outputDeviceClass: String
    let routeShape: String
}

/// Exact, process-local route identity used only for recovery admission. Raw
/// device identity never leaves the app; analytics continue to use the coarse
/// categorical route above.
struct ParakeetAudioRouteIdentity: Equatable {
    let defaultInputID: UInt32
    let defaultInputUID: String?
    let selectedInputID: UInt32
    let selectedInputUID: String?
    let defaultOutputID: UInt32?
    let defaultOutputUID: String?
    let selectionReason: DictationInputDeviceSelectionReason

    init(selection: DictationInputDeviceSelection) {
        defaultInputID = selection.defaultInput.id
        defaultInputUID = selection.defaultInput.uid
        selectedInputID = selection.selectedInput.id
        selectedInputUID = selection.selectedInput.uid
        defaultOutputID = selection.defaultOutput?.id
        defaultOutputUID = selection.defaultOutput?.uid
        selectionReason = selection.reason
    }

    /// The actual endpoints owned by the AVAudioEngine graph. The system
    /// default input and selection reason can churn while Transcripted keeps
    /// the same explicitly selected mic and output.
    func matchesGraphEndpoints(_ other: ParakeetAudioRouteIdentity) -> Bool {
        selectedInputID == other.selectedInputID
            && selectedInputUID == other.selectedInputUID
            && defaultOutputID == other.defaultOutputID
            && defaultOutputUID == other.defaultOutputUID
    }
}

/// Coalesces noisy CoreAudio notifications into one categorical route transition.
/// The side-effecting recovery path still runs for every debounced config-change
/// burst; this state only decides whether that burst is new analytics signal.
struct ParakeetRouteTransitionDebounceState: Equatable {
    private(set) var stableRoute: ParakeetCategoricalAudioRoute?
    private(set) var pendingRoute: ParakeetCategoricalAudioRoute?

    mutating func seedStableRouteIfNeeded(_ route: ParakeetCategoricalAudioRoute) {
        guard stableRoute == nil else { return }
        stableRoute = route
    }

    mutating func observe(_ route: ParakeetCategoricalAudioRoute) {
        pendingRoute = route
    }

    mutating func commitPendingRoute() -> ParakeetCategoricalAudioRoute? {
        guard let pendingRoute else { return nil }
        self.pendingRoute = nil

        guard let stableRoute else {
            self.stableRoute = pendingRoute
            return nil
        }
        guard pendingRoute != stableRoute else { return nil }

        self.stableRoute = pendingRoute
        return pendingRoute
    }

    mutating func discardPendingRoute() {
        pendingRoute = nil
    }
}

enum ParakeetZombieRecoveryStage: String, Equatable {
    case detected
    case reset
    case settle
    case restart
}

enum ParakeetZombieRecoveryResult: String, Equatable {
    case succeeded
    case failed
    case cancelled
}

struct ParakeetZombieRecoveryTerminal: Equatable {
    let generation: UInt64
    let stage: ParakeetZombieRecoveryStage
    let result: ParakeetZombieRecoveryResult
    let failureKind: String
}

/// Generation-gated lifecycle for the single bounded zombie-engine retry.
/// `finish` consumes the active attempt so every generation can produce at most
/// one terminal telemetry result, even when cancellation races a late callback.
struct ParakeetZombieRecoveryState: Equatable {
    private struct Attempt: Equatable {
        let generation: UInt64
        let failureKind: String
        var stage: ParakeetZombieRecoveryStage
    }

    private var epoch = SupersessionEpoch()
    private var activeAttempt: Attempt?

    var generation: UInt64 {
        epoch.snapshot().rawValue
    }

    var isActive: Bool {
        activeAttempt != nil
    }

    mutating func begin(failureKind: String) -> UInt64 {
        if let activeAttempt {
            return activeAttempt.generation
        }
        let generation = epoch.begin().rawValue
        activeAttempt = Attempt(
            generation: generation,
            failureKind: failureKind,
            stage: .detected
        )
        return generation
    }

    mutating func advance(to stage: ParakeetZombieRecoveryStage, generation: UInt64) -> Bool {
        guard activeAttempt?.generation == generation,
              currentToken(matching: generation) != nil else { return false }
        activeAttempt?.stage = stage
        return true
    }

    func canContinue(generation: UInt64) -> Bool {
        activeAttempt?.generation == generation && currentToken(matching: generation) != nil
    }

    mutating func finish(
        result: ParakeetZombieRecoveryResult,
        generation: UInt64
    ) -> ParakeetZombieRecoveryTerminal? {
        guard let attempt = activeAttempt,
              attempt.generation == generation,
              let token = currentToken(matching: generation),
              epoch.finishIfCurrent(token) else { return nil }
        activeAttempt = nil
        return ParakeetZombieRecoveryTerminal(
            generation: generation,
            stage: attempt.stage,
            result: result,
            failureKind: attempt.failureKind
        )
    }

    mutating func cancelActiveAttempt() -> ParakeetZombieRecoveryTerminal? {
        guard let attempt = activeAttempt else { return nil }
        return finish(result: .cancelled, generation: attempt.generation)
    }

    private func currentToken(matching generation: UInt64) -> SupersessionEpoch.Token? {
        let token = epoch.snapshot()
        guard token.rawValue == generation else { return nil }
        return token
    }
}

struct ParakeetAudioStartRecoveryPolicy: Equatable {
    static func shouldRetryStartFailure(
        isRecoveryAttempt: Bool,
        failedAttempts: Int,
        retryBudget: Int = TranscriptedConstants.audioStartRecoveryAttempts
    ) -> Bool {
        guard !isRecoveryAttempt else { return false }
        guard retryBudget > 0 else { return false }
        return failedAttempts <= retryBudget
    }

    static func shouldReportFailure(
        now: TimeInterval,
        lastReportAt: TimeInterval?,
        throttle: TimeInterval = TranscriptedConstants.audioStartFailureReportThrottle
    ) -> Bool {
        guard let lastReportAt else { return true }
        return now - lastReportAt >= throttle
    }
}
