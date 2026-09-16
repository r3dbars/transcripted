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

    /// Invalidates any in-flight recovery and leaves hardware validation for
    /// the next explicit dictation start. Idle route notifications should not
    /// rebuild native audio graphs in the background.
    mutating func deferUntilNextUse() {
        epoch.invalidate()
        isRecovering = false
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

/// A native AUHAL binding command may emit its configuration notification
/// before setDeviceID returns. Retain the command identity at callback arrival,
/// but trust it only after the setter has returned successfully.
final class ParakeetAUHALBindingToken: @unchecked Sendable {
    let engineID: ObjectIdentifier
    let route: ParakeetAudioRouteIdentity
    let issuedAt: CFAbsoluteTime
    private let issuedUptime = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var result: Bool?

    init(engine: AnyObject, route: ParakeetAudioRouteIdentity, issuedAt: CFAbsoluteTime) {
        engineID = ObjectIdentifier(engine)
        self.route = route
        self.issuedAt = issuedAt
    }

    func finish(succeeded: Bool) {
        lock.withLock {
            guard result == nil else { return }
            result = succeeded
        }
    }

    var wasConfirmed: Bool { lock.withLock { result == true } }

    /// A callback can be delivered before a slow USB setter returns. Wait only
    /// for the native operation's remaining 1.5s budget, without blocking the
    /// main actor or creating another CoreAudio worker. Failure/hang fails open.
    func waitForResolution(nativeTimeoutNanoseconds: UInt64) async {
        let deadline = issuedUptime + Double(nativeTimeoutNanoseconds) / 1_000_000_000
        while !Task.isCancelled {
            if lock.withLock({ result != nil }) { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                lock.withLock {
                    if result == nil { result = false }
                }
                return
            }
            let sleepNanoseconds = UInt64(min(remaining, 0.01) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: max(1, sleepNanoseconds))
        }
    }
}

/// One current intent per ParakeetEngine; prior callback requests keep their
/// own token rather than borrowing a later binding's confirmation.
final class ParakeetAUHALBindingIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var currentToken: ParakeetAUHALBindingToken?

    func begin(engine: AnyObject, route: ParakeetAudioRouteIdentity,
               at issuedAt: CFAbsoluteTime) -> ParakeetAUHALBindingToken {
        lock.withLock {
            let token = ParakeetAUHALBindingToken(engine: engine, route: route, issuedAt: issuedAt)
            currentToken = token
            return token
        }
    }

    func tokenForNotification(engineID: ObjectIdentifier, at observedAt: CFAbsoluteTime,
                              window: TimeInterval) -> ParakeetAUHALBindingToken? {
        lock.withLock {
            guard let token = currentToken,
                  token.engineID == engineID,
                  observedAt >= token.issuedAt,
                  observedAt <= token.issuedAt + window else { return nil }
            return token
        }
    }
}

struct ParakeetInputDeviceRefreshRequest: Sendable {
    let configChangeSource: ParakeetConfigChangeSource?
    let observedAt: CFAbsoluteTime?
    let bindingToken: ParakeetAUHALBindingToken?
}

/// A one-worker, latest-wins mailbox for CoreAudio input-device notifications.
///
/// CoreAudio callbacks can arrive in bursts. Creating one detached task for
/// every callback lets a slow HAL lookup turn that burst into unbounded task
/// retention. This mailbox admits one worker and collapses every pending burst
/// into one latest request.
final class ParakeetInputDeviceRefreshMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var workerScheduled = false
    private var hasPendingRequest = false
    private var pendingConfigChangeSource: ParakeetConfigChangeSource?
    private var pendingObservedAt: CFAbsoluteTime?
    private var pendingBindingToken: ParakeetAUHALBindingToken?
    private var isClosed = false

    /// Returns true only when the caller must schedule the single worker.
    func submit(configChangeSource: ParakeetConfigChangeSource? = nil,
                observedAt: CFAbsoluteTime? = nil,
                bindingToken: ParakeetAUHALBindingToken? = nil) -> Bool {
        lock.withLock {
            guard !isClosed else { return false }
            hasPendingRequest = true
            if let configChangeSource {
                pendingConfigChangeSource = configChangeSource
                pendingObservedAt = observedAt
                pendingBindingToken = bindingToken
            }
            guard !workerScheduled else { return false }
            workerScheduled = true
            return true
        }
    }

    /// Returns the latest pending request, or atomically releases worker
    /// ownership when the mailbox has drained.
    func takeNext() -> ParakeetInputDeviceRefreshRequest? {
        lock.withLock {
            guard !isClosed, hasPendingRequest else {
                workerScheduled = false
                return nil
            }
            hasPendingRequest = false
            let request = ParakeetInputDeviceRefreshRequest(
                configChangeSource: pendingConfigChangeSource,
                observedAt: pendingObservedAt,
                bindingToken: pendingBindingToken
            )
            pendingConfigChangeSource = nil
            pendingObservedAt = nil
            pendingBindingToken = nil
            return request
        }
    }

    func close() {
        lock.withLock {
            isClosed = true
            workerScheduled = false
            hasPendingRequest = false
            pendingConfigChangeSource = nil
            pendingObservedAt = nil
            pendingBindingToken = nil
        }
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

/// Only a proven, unchanged route may be treated as an AUHAL setter echo.
/// Older generic ignore windows still cover deliberate system-default-input
/// restore work, but are evaluated at notification arrival, not after HAL.
enum ParakeetSelfInducedConfigChangePolicy {
    static func shouldIgnore(
        source: ParakeetConfigChangeSource,
        observedAt: CFAbsoluteTime,
        ignoreWindowUntil: CFAbsoluteTime,
        windowDuration: TimeInterval,
        stableRoute: ParakeetAudioRouteIdentity?,
        observedRoute: ParakeetAudioRouteIdentity?,
        bindingToken: ParakeetAUHALBindingToken?,
        currentEngine: AnyObject
    ) -> Bool {
        if let bindingToken, source == .audioEngine {
            // A captured native setter command owns classification exclusively.
            // A failed command must not fall through to an optimistic cache
            // window and be mistaken for a successful binding echo.
            return bindingToken.wasConfirmed
                && bindingToken.engineID == ObjectIdentifier(currentEngine)
                && observedAt >= bindingToken.issuedAt
                && observedAt <= bindingToken.issuedAt + windowDuration
                && observedRoute == bindingToken.route
        }
        guard ignoreWindowUntil > 0,
              observedAt >= ignoreWindowUntil - windowDuration,
              observedAt <= ignoreWindowUntil else { return false }
        // The system-input restore path writes the default input itself; keep
        // its existing short suppression window. A later external change does
        // not inherit that window merely because route lookup was delayed.
        if source == .defaultInputDevice { return true }
        guard let stableRoute, let observedRoute else { return false }
        return stableRoute == observedRoute
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
