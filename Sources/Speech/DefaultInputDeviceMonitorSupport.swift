// DefaultInputDeviceMonitorSupport.swift
// Pure, CoreAudio-free types backing DefaultInputDeviceMonitor.swift, split
// out so the fast-test runner (scripts/entrypoints/run-tests.sh) can compile
// and exercise ordering + self-write suppression without pulling in
// EventReporter/CoreAudioInputDeviceLookup and their dependency graph, the
// same constraint that keeps DefaultInputDeviceMonitor's @MainActor class
// itself out of that list. See DefaultInputDeviceMonitor.swift for the
// CoreAudio-facing facade that owns these.

import CoreAudio
import Foundation

/// Identifies one `DefaultInputDeviceMonitor.addObserver` registration so it
/// can later be passed to `removeObserver`. Opaque by design — callers store
/// it, they don't inspect it.
struct DefaultInputDeviceObserverToken: Hashable {
    fileprivate let id = UUID()

    init() {}
}

/// The narrow surface `MicActivityMonitor` needs from `DefaultInputDeviceMonitor`.
/// `DefaultInputDeviceMonitor` conforms to this in DefaultInputDeviceMonitor.swift;
/// `MicActivityMonitor` stores an injected `DefaultInputDeviceSubscribing?`
/// instead of naming the concrete singleton directly (see
/// `MicActivityMonitor.defaultInputDeviceMonitor`), so MicActivityMonitor.swift
/// — which the fast-test runner compiles on its own for its pure attribution
/// helpers — never has to pull in DefaultInputDeviceMonitor.swift's
/// EventReporter/CoreAudioInputDeviceLookup dependency graph.
/// `Sendable` so a reference to it can cross into the `Task { @MainActor in }`
/// hops `MicActivityMonitor` needs (subscribe/unsubscribe happen from its own
/// background `queue`). Safe because every conformer is `@MainActor`-isolated
/// — see `DefaultInputDeviceMonitor`'s `@unchecked Sendable` conformance.
///
/// Every observer is notified on every non-self-write-ambiguous change; the
/// handler receives `isSelfWrite: Bool` instead of the monitor silently
/// dropping the notification (codex review of PR #1640, P2: a global drop
/// hid the event from `MicActivityMonitor`, which never wrote the property
/// and relied on seeing every change, including
/// `PersistentDictationInputController`'s self-reassertion writes, to
/// re-point its "running somewhere" listener). Each consumer now makes its
/// own choice — see the per-consumer handlers in
/// `PersistentDictationInputController.swift`, `ParakeetDeviceRecovery.swift`,
/// and `MicActivityMonitor.swift`.
@MainActor
protocol DefaultInputDeviceSubscribing: AnyObject, Sendable {
    func start()
    @discardableResult
    func addObserver(_ handler: @escaping (Bool) -> Void) -> DefaultInputDeviceObserverToken
    func removeObserver(_ token: DefaultInputDeviceObserverToken)
}

/// Order-preserving observer bookkeeping, split out of
/// `DefaultInputDeviceMonitor` so delivery order is unit-testable without
/// touching CoreAudio or the main actor.
struct DefaultInputDeviceObserverRegistry {
    private var observers: [(token: DefaultInputDeviceObserverToken, handler: (Bool) -> Void)] = []

    @discardableResult
    mutating func add(_ handler: @escaping (Bool) -> Void) -> DefaultInputDeviceObserverToken {
        let token = DefaultInputDeviceObserverToken()
        observers.append((token, handler))
        return token
    }

    mutating func remove(_ token: DefaultInputDeviceObserverToken) {
        observers.removeAll { $0.token == token }
    }

    var count: Int { observers.count }

    /// Delivers to every registered observer in registration order, passing
    /// `isSelfWrite` through unfiltered — this registry does not decide who
    /// cares about a self-write, each observer does.
    func notifyAll(isSelfWrite: Bool) {
        for observer in observers {
            observer.handler(isSelfWrite)
        }
    }
}

/// Pure, unit-testable self-write detection for
/// `DefaultInputDeviceMonitor.setDefaultInputDevice`. See
/// `TranscriptedConstants.defaultInputDeviceMonitorSelfWriteWindow` for the
/// window-length rationale. Renamed from the PR #1640 original
/// `consumeSuppression` — it no longer gates delivery (see
/// `DefaultInputDeviceObserverRegistry.notifyAll`), it only classifies the
/// notification so each observer can decide for itself.
struct DefaultInputDeviceSelfWriteTracker {
    private var pendingDeviceID: AudioDeviceID?
    private var pendingDeadline: CFAbsoluteTime = 0

    mutating func beginWrite(
        deviceID: AudioDeviceID,
        now: CFAbsoluteTime,
        window: TimeInterval = TranscriptedConstants.defaultInputDeviceMonitorSelfWriteWindow
    ) {
        pendingDeviceID = deviceID
        pendingDeadline = now + window
    }

    mutating func cancelPendingWrite() {
        pendingDeviceID = nil
    }

    /// Returns `true` when this notification is the echo of our own write.
    /// The pending write is always consumed on the first notification
    /// observed after it (single-use), whether or not that notification
    /// actually matched — so a stale pending write can never mislabel a
    /// later, unrelated change as a self-write.
    mutating func consumeIsSelfWrite(currentDeviceID: AudioDeviceID?, now: CFAbsoluteTime) -> Bool {
        guard let pendingDeviceID else { return false }
        self.pendingDeviceID = nil
        guard now <= pendingDeadline else { return false }
        return currentDeviceID == pendingDeviceID
    }
}
