// DefaultInputDeviceMonitorSupport.swift
// Testable types backing DefaultInputDeviceMonitor.swift, split out so the
// fast-test runner (scripts/entrypoints/run-tests.sh) can compile and exercise
// observer ordering, self-write classification, and blocked-lookup dispatch
// without pulling in EventReporter/CoreAudioInputDeviceLookup, the
// same constraint that keeps DefaultInputDeviceMonitor's @MainActor class
// itself out of that list. See DefaultInputDeviceMonitor.swift for the
// CoreAudio-facing facade that owns these. Also holds the off-main HAL
// listener registration queue and the default-input registration state
// machine (see "Off-main HAL listener registration" below).

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
struct DefaultInputDevicePendingSelfWrite: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let deadline: CFAbsoluteTime

    func matches(currentDeviceID: AudioDeviceID?, notificationAt: CFAbsoluteTime) -> Bool {
        notificationAt <= deadline && currentDeviceID == deviceID
    }
}

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

    /// Only the first in-window echo of a sanctioned system-default write
    /// needs a device-ID read. External changes have no marker to compare.
    func needsDeviceIDForClassification(at notificationAt: CFAbsoluteTime) -> Bool {
        pendingDeviceID != nil && notificationAt <= pendingDeadline
    }

    /// Reserve this write marker at notification admission, before any async
    /// HAL work. A delayed result for write A must never consume or relabel a
    /// newer write B's marker.
    mutating func takePendingWriteForNotification(
        at notificationAt: CFAbsoluteTime
    ) -> DefaultInputDevicePendingSelfWrite? {
        guard let pendingDeviceID else { return nil }
        self.pendingDeviceID = nil
        guard notificationAt <= pendingDeadline else { return nil }
        return DefaultInputDevicePendingSelfWrite(
            deviceID: pendingDeviceID,
            deadline: pendingDeadline
        )
    }

    /// Returns `true` when this notification is the echo of our own write.
    /// The pending write is always consumed on the first notification
    /// observed after it (single-use), whether or not that notification
    /// actually matched — so a stale pending write can never mislabel a
    /// later, unrelated change as a self-write.
    mutating func consumeIsSelfWrite(currentDeviceID: AudioDeviceID?, now: CFAbsoluteTime) -> Bool {
        takePendingWriteForNotification(at: now)?.matches(
            currentDeviceID: currentDeviceID,
            notificationAt: now
        ) ?? false
    }
}

struct DefaultInputDeviceNotificationRequest: Equatable, Sendable {
    let notificationAt: CFAbsoluteTime
    let pendingSelfWrite: DefaultInputDevicePendingSelfWrite?
}

/// Retains the first reserved/active notification, the earliest additional
/// self-write echo, and the latest remaining burst event. This is bounded at
/// three requests even if the listener posts thousands of callbacks. A write
/// echo is not replaced by ordinary route chatter while its HAL lookup waits.
final class DefaultInputDeviceNotificationMailbox: @unchecked Sendable {
    private struct Entry {
        let sequence: UInt64
        let request: DefaultInputDeviceNotificationRequest
    }

    private let lock = NSLock()
    private var workerScheduled = false
    private var nextSequence: UInt64 = 0
    private var firstReserved: Entry?
    private var protectedSelfWrite: Entry?
    private var latestPending: Entry?
    private var closed = false

    func submit(_ request: DefaultInputDeviceNotificationRequest) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            nextSequence &+= 1
            let entry = Entry(sequence: nextSequence, request: request)
            if !workerScheduled {
                firstReserved = entry
                workerScheduled = true
                return true
            }
            if request.pendingSelfWrite != nil, protectedSelfWrite == nil {
                protectedSelfWrite = entry
            } else {
                latestPending = entry
            }
            return false
        }
    }

    func takeNext() -> DefaultInputDeviceNotificationRequest? {
        lock.withLock {
            guard !closed else {
                workerScheduled = false
                return nil
            }
            if let firstReserved {
                self.firstReserved = nil
                return firstReserved.request
            }
            if let protectedSelfWrite,
               protectedSelfWrite.sequence < (latestPending?.sequence ?? .max) {
                self.protectedSelfWrite = nil
                return protectedSelfWrite.request
            }
            if let latestPending {
                self.latestPending = nil
                return latestPending.request
            }
            if let protectedSelfWrite {
                self.protectedSelfWrite = nil
                return protectedSelfWrite.request
            }
            workerScheduled = false
            return nil
        }
    }

    var isClosed: Bool { lock.withLock { closed } }
    var hasScheduledWorker: Bool { lock.withLock { workerScheduled } }

    func close() {
        lock.withLock {
            closed = true
            workerScheduled = false
            firstReserved = nil
            protectedSelfWrite = nil
            latestPending = nil
        }
    }
}

/// A CoreAudio read may never return after a USB device disconnect. Keep that
/// read off the listener queue and bound both its wait and the number of
/// replacement workers. Unknown/timed-out reads are still delivered so route
/// recovery is not silently skipped. Late results and closed-monitor results
/// are never delivered.
final class DefaultInputDeviceNotificationLookupDispatcher: @unchecked Sendable {
    private let mailbox = DefaultInputDeviceNotificationMailbox()
    private let workCoordinator: ParakeetReplaceableSystemInputWorkCoordinator
    private let timeoutNanoseconds: UInt64
    private let lookup: () -> AudioDeviceID?
    private let deliver: (AudioDeviceID?, DefaultInputDeviceNotificationRequest) async -> Void

    init(
        label: String,
        timeoutNanoseconds: UInt64,
        lookup: @escaping () -> AudioDeviceID?,
        workCoordinator: ParakeetReplaceableSystemInputWorkCoordinator? = nil,
        deliver: @escaping (AudioDeviceID?, DefaultInputDeviceNotificationRequest) async -> Void
    ) {
        self.workCoordinator = workCoordinator
            ?? ParakeetReplaceableSystemInputWorkCoordinator(label: label)
        self.timeoutNanoseconds = timeoutNanoseconds
        self.lookup = lookup
        self.deliver = deliver
    }

    func submit(
        at notificationAt: CFAbsoluteTime,
        pendingSelfWrite: DefaultInputDevicePendingSelfWrite? = nil
    ) {
        let request = DefaultInputDeviceNotificationRequest(
            notificationAt: notificationAt,
            pendingSelfWrite: pendingSelfWrite
        )
        guard mailbox.submit(request) else { return }
        Task.detached(priority: .utility) { [self] in
            await drain()
        }
    }

    func close() { mailbox.close() }
    var hasScheduledWorker: Bool { mailbox.hasScheduledWorker }

    private func drain() async {
        while let request = mailbox.takeNext() {
            let deviceID = try? await workCoordinator.run(
                operation: "default_input_notification_lookup",
                timeoutNanoseconds: timeoutNanoseconds,
                lookup
            )
            guard !mailbox.isClosed else { return }
            await deliver(deviceID, request)
        }
    }
}

// MARK: - Off-main HAL listener registration

/// Carries one `AudioObjectPropertyListenerBlock` value across the
/// registration queue hop. The add and the later remove must pass the *same*
/// block object: re-bridging a Swift closure makes a new block, and
/// `AudioObjectRemovePropertyListenerBlock` then silently fails to match.
/// The block itself is only ever invoked by CoreAudio on `DispatchQueue.main`.
final class HALListenerBlockBox: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock

    init(_ block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }
}

/// The app's first CoreAudio call pays for HAL client init (40 ms on a warm
/// coreaudiod, 5 s+ when its XPC to the capture-defaults service stalls; Sentry
/// APPLE-MACOS-31). At launch that first call used to be a listener add on the
/// main thread, before the status item existed. Both launch-time system-object
/// listener adds (default input in `DefaultInputDeviceMonitor`, device list in
/// `PersistentDictationInputController+Live.swift`) now run on this one serial
/// queue instead; CoreAudio still delivers their callbacks on
/// `DispatchQueue.main`, so subscribers see no change. Whichever add runs
/// first does (or waits for) HAL init off main.
///
/// Registering a listener opens no device and never touches an
/// `AVAudioEngine` or its `inputNode`, so AirPods as the default input stay in
/// A2DP exactly as before. Removes stay on main: they only run after their add
/// finished, when the HAL is already up and a remove costs microseconds.
enum HALListenerRegistrationQueue {
    static let queue = DispatchQueue(
        label: "com.transcripted.hal-listener-registration",
        qos: .userInitiated
    )

    /// Adds `listener` for `selector` on the system object off main, with
    /// callbacks delivered on main. `completion` runs on the main actor with
    /// the HAL status, after the add returned.
    static func addSystemObjectListener(
        selector: AudioObjectPropertySelector,
        listener: HALListenerBlockBox,
        completion: @escaping @MainActor (OSStatus) -> Void
    ) {
        run({
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            return AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener.block
            )
        }, then: completion)
    }

    /// Runs `work` on the registration queue, in submission order, then hands
    /// its result to `completion` on the main actor. Completions arrive in the
    /// same order as their work (both hops are FIFO serial queues).
    static func run<Result>(
        _ work: @escaping @Sendable () -> Result,
        then completion: @escaping @MainActor (Result) -> Void
    ) {
        let hop = RegistrationHop(work: work, completion: completion)
        queue.async {
            let result = RegistrationResult(hop.work())
            DispatchQueue.main.async {
                MainActor.assumeIsolated { hop.completion(result.value) }
            }
        }
    }
}

/// Carries registration work and its main-actor completion through the queue
/// hop. `work` only runs on `HALListenerRegistrationQueue.queue`;
/// `completion` only runs back on the main queue.
private final class RegistrationHop<Result>: @unchecked Sendable {
    let work: @Sendable () -> Result
    let completion: @MainActor (Result) -> Void

    init(work: @escaping @Sendable () -> Result, completion: @escaping @MainActor (Result) -> Void) {
        self.work = work
        self.completion = completion
    }
}

private final class RegistrationResult<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// The one default-input listener registration as a small state machine:
/// idle, registering (the add is queued or blocked in HAL init), registered.
/// `start` is a no-op unless idle, so callers that start while an add is
/// pending (ParakeetEngine prewarm, MicActivityMonitor) never queue a second
/// one. `stop` while registering bumps the generation; the late completion
/// then removes the very token it added. A failed add goes back to idle so a
/// later `start` retries. Generic over the token so tests drive it with a
/// fake registrar and no CoreAudio.
@MainActor
final class DefaultInputDeviceListenerRegistrar<Token> {
    typealias Add = (_ token: Token, _ completion: @escaping @MainActor (OSStatus) -> Void) -> Void
    typealias Remove = (_ token: Token) -> OSStatus

    private enum Phase {
        case idle
        case registering
        case registered(Token)
    }

    private var phase: Phase = .idle
    private let add: Add
    private let remove: Remove

    /// Bumped on every stop and every failed add. Results tagged with an older
    /// generation are stale.
    private(set) var generation: UInt64 = 0

    init(add: @escaping Add, remove: @escaping Remove) {
        self.add = add
        self.remove = remove
    }

    /// True while an add is pending or live.
    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    var isRegistered: Bool {
        if case .registered = phase { return true }
        return false
    }

    /// Queues one add. Returns false (and does nothing) unless idle.
    /// `onFailure` runs on the main actor with the HAL status if this add is
    /// still current when it fails.
    @discardableResult
    func start(_ token: Token, onFailure: @escaping @MainActor (OSStatus) -> Void) -> Bool {
        guard case .idle = phase else { return false }
        phase = .registering
        let started = generation
        add(token) { [weak self] status in
            self?.complete(token, generation: started, status: status, onFailure: onFailure)
        }
        return true
    }

    /// Tears the registration down. Returns false when nothing was pending or
    /// live, or when the HAL refused the remove (state kept, as before).
    @discardableResult
    func stop() -> Bool {
        switch phase {
        case .idle:
            return false
        case .registering:
            break
        case .registered(let token):
            guard remove(token) == noErr else { return false }
        }
        phase = .idle
        generation &+= 1
        return true
    }

    private func complete(
        _ token: Token,
        generation started: UInt64,
        status: OSStatus,
        onFailure: @MainActor (OSStatus) -> Void
    ) {
        guard started == generation, case .registering = phase else {
            // stop() ran while this add was pending. Undo it with the same token.
            if status == noErr { _ = remove(token) }
            return
        }
        guard status == noErr else {
            phase = .idle
            generation &+= 1
            onFailure(status)
            return
        }
        phase = .registered(token)
    }
}
