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
@MainActor
protocol DefaultInputDeviceSubscribing: AnyObject, Sendable {
    func start()
    @discardableResult
    func addObserver(_ handler: @escaping () -> Void) -> DefaultInputDeviceObserverToken
    func removeObserver(_ token: DefaultInputDeviceObserverToken)
}

/// Order-preserving observer bookkeeping, split out of
/// `DefaultInputDeviceMonitor` so delivery order is unit-testable without
/// touching CoreAudio or the main actor.
struct DefaultInputDeviceObserverRegistry {
    private var observers: [(token: DefaultInputDeviceObserverToken, handler: () -> Void)] = []

    @discardableResult
    mutating func add(_ handler: @escaping () -> Void) -> DefaultInputDeviceObserverToken {
        let token = DefaultInputDeviceObserverToken()
        observers.append((token, handler))
        return token
    }

    mutating func remove(_ token: DefaultInputDeviceObserverToken) {
        observers.removeAll { $0.token == token }
    }

    var count: Int { observers.count }

    /// Delivers to every registered observer in registration order.
    func notifyAll() {
        for observer in observers {
            observer.handler()
        }
    }
}

/// Pure, unit-testable self-write suppression for
/// `DefaultInputDeviceMonitor.setDefaultInputDevice`. See
/// `TranscriptedConstants.defaultInputDeviceMonitorSelfWriteWindow` for the
/// window-length rationale.
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

    /// Returns `true` when this notification should be swallowed as the echo
    /// of our own write. The pending write is always consumed on the first
    /// notification observed after it (single-use), whether or not that
    /// notification actually matched — so a stale pending write can never
    /// suppress a later, unrelated change.
    mutating func consumeSuppression(currentDeviceID: AudioDeviceID?, now: CFAbsoluteTime) -> Bool {
        guard let pendingDeviceID else { return false }
        self.pendingDeviceID = nil
        guard now <= pendingDeadline else { return false }
        return currentDeviceID == pendingDeviceID
    }
}
