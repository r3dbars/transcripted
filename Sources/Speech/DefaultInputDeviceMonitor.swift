// DefaultInputDeviceMonitor.swift
// Single-registration facade over CoreAudio's
// kAudioHardwarePropertyDefaultInputDevice change notification.
//
// Before this file existed, three independent consumers each registered
// their own `AudioObjectAddPropertyListenerBlock` for that property:
//   - PersistentDictationInputController.installDefaultInputListener
//   - ParakeetEngine.installInputDeviceChangeListenerIfNeeded (ParakeetDeviceRecovery.swift)
//   - MicActivityMonitor.installListeners
// CoreAudio gives no ordering guarantee across independent registrations on
// the same property/object. Worse, PersistentDictationInputController's own
// preference-apply path *writes* the very property everyone listens on
// (`CoreAudioInputDeviceLookup.setDefaultInputDeviceID`), which re-fires every
// listener, including itself. Each consumer grew its own defense against that
// feedback loop (a recovery-marker short-circuit, ParakeetEngine's
// `ignoreInputSelectionConfigChangesUntil`, MicActivityMonitor's tolerance for
// a harmless extra re-scan).
//
// This type owns the one CoreAudio registration, applies a single self-write
// suppression centrally (instead of three defensive copies), and fans out to
// subscribers in a defined, documented order. Consumers keep their own
// post-event behavior (recovery, rewarm, re-scan) unchanged; only the trigger
// plumbing moves here. See the per-consumer migration notes in
// PersistentDictationInputController.swift, ParakeetDeviceRecovery.swift, and
// MicActivityMonitor.swift for what each one used to do on a self-write event
// versus what happens now that the write is suppressed once, upstream.
//
// Threading: CoreAudio calls the listener block on whatever dispatch queue we
// register it with. This monitor registers directly against
// `DispatchQueue.main`, which is the one thread-hop the whole system needs —
// two of the three former listeners already targeted `.main` themselves.
// MicActivityMonitor is the exception: its documented threading contract
// confines CoreAudio reads/writes and mutable state to its own private serial
// queue, so its subscription handler re-hops from this monitor's main-actor
// delivery back onto that queue before doing anything (see
// MicActivityMonitor.swift). That is a second, consumer-owned hop, not a
// second hop performed by this monitor.
//
// The observer registry and self-write tracker this class owns live in
// DefaultInputDeviceMonitorSupport.swift as dependency-free pure types (no
// EventReporter, no CoreAudioInputDeviceLookup) so the fast-test runner can
// compile and exercise them directly — see that file's header and
// Tests/DefaultInputDeviceMonitorTests.swift.

import CoreAudio
import Foundation

@MainActor
final class DefaultInputDeviceMonitor: DefaultInputDeviceSubscribing, @unchecked Sendable {
    static let shared = DefaultInputDeviceMonitor()

    typealias ObserverToken = DefaultInputDeviceObserverToken

    private var listener: AudioObjectPropertyListenerBlock?
    private var registry = DefaultInputDeviceObserverRegistry()
    private var selfWriteTracker = DefaultInputDeviceSelfWriteTracker()

    private init() {}

    /// Registers the single CoreAudio listener. Idempotent and safe for every
    /// subscriber to call from its own startup path — only the first caller
    /// actually touches CoreAudio; later calls are no-ops. At app startup the
    /// known call order is: `PersistentDictationInputController.start()`
    /// (from `applicationDidFinishLaunching`, before anything else touches
    /// audio), then `ParakeetEngine` the first time dictation warmup or
    /// recording calls `prewarm()`, then `MicActivityMonitor.start()` when
    /// meeting-prompt detection is enabled (which can start/stop repeatedly
    /// across a session). Whichever of those runs first performs the actual
    /// registration; this does not change delivery order for `addObserver`,
    /// which is documented there.
    func start() {
        guard listener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handlePropertyChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "default_input_device_monitor_listener_failed",
                message: "Could not monitor system default input device changes",
                context: ["status": "\(status)"]
            )
            return
        }
        listener = block
    }

    /// Registers `handler` to run on the main actor for every default-input
    /// change, including ones caused by `setDefaultInputDevice`'s own writes
    /// — `isSelfWrite` tells the handler which. Delivery is strictly
    /// registration order — first registered, first notified — so callers
    /// that must observe a change before another subsystem reacts to it
    /// should call `addObserver` earlier in the app's startup sequence.
    /// Assign before any code path that could itself trigger a default-input
    /// change.
    @discardableResult
    func addObserver(_ handler: @escaping (Bool) -> Void) -> ObserverToken {
        registry.add(handler)
    }

    func removeObserver(_ token: ObserverToken) {
        registry.remove(token)
    }

    /// The only sanctioned way to write `kAudioHardwarePropertyDefaultInputDevice`
    /// through this monitor. Used exclusively by
    /// `PersistentDictationInputController`, the one consumer whose job is to
    /// actively steer the system default input for a user-facing preference.
    /// Records the write so the resulting notification is classified
    /// `isSelfWrite: true` for every subscriber, once, centrally, instead of
    /// each one independently re-deriving "was that us?".
    ///
    /// ParakeetEngine's own device overrides during recording start
    /// deliberately do *not* route through here — they keep their existing,
    /// purpose-built `ignoreInputSelectionConfigChangesUntil` window (see
    /// ParakeetDeviceRecovery.swift), which is not the same suppression: it
    /// spans the whole recording-start sequencing around the override (audio
    /// graph rebuild, format renegotiation), not just the CoreAudio round
    /// trip, so collapsing it into this 500ms window would not be behavior
    /// preserving.
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
        selfWriteTracker.beginWrite(deviceID: deviceID, now: CFAbsoluteTimeGetCurrent())
        do {
            try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(deviceID)
        } catch {
            selfWriteTracker.cancelPendingWrite()
            throw error
        }
    }

    // Every notification is delivered to every subscriber — the monitor
    // itself does not decide who cares about a self-write (codex review of
    // PR #1640, P2: a global drop here hid the event from MicActivityMonitor,
    // which never writes the property and relied on seeing every change,
    // including PersistentDictationInputController's self-reassertion
    // writes, to re-point its "running somewhere" listener). Each observer's
    // handler receives `isSelfWrite` and decides for itself — see the
    // per-consumer handlers in PersistentDictationInputController.swift,
    // ParakeetDeviceRecovery.swift, and MicActivityMonitor.swift.
    private func handlePropertyChanged() {
        let now = CFAbsoluteTimeGetCurrent()
        let currentDeviceID = try? CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()
        let isSelfWrite = selfWriteTracker.consumeIsSelfWrite(currentDeviceID: currentDeviceID, now: now)
        registry.notifyAll(isSelfWrite: isSelfWrite)
    }
}
