import AVFoundation
import Combine

/// A recovery/health event a `SystemAudioCaptureEngine` backend reports so
/// hosts can feed system-audio dropouts into the same capture-quality signal
/// mic-path recovery already drives (`Audio.deviceSwitchCount` /
/// `Audio.recordingGaps`, composed by `RecordingHealthInfo.from`).
///
/// Backends that don't perform bounded mid-recording recovery never publish
/// these — the default `recoveryEventPublisher` below is empty for them.
public enum SystemAudioRecoveryEvent: Sendable, Equatable {
    /// A bounded recovery attempt started (mirrors the mic path incrementing
    /// `Audio.deviceSwitchCount` at the start of `recoverFromDeviceChange`).
    case deviceSwitch
    /// A bounded recovery attempt succeeded after this much silent/stopped
    /// time (mirrors the mic path appending an `Audio.AudioGap` once
    /// recovery is confirmed by a real audio frame).
    case gap(duration: TimeInterval)
    /// A bounded recovery attempt ended without a confirmed buffer: it was
    /// cancelled, superseded, its restart threw, or no buffer arrived within
    /// the restart timeout. `Audio` releases the system-audio write hold on
    /// this event; without it every later system buffer would be dropped
    /// for the rest of the recording.
    case recoveryAbandoned
}

/// Common interface for system audio capture backends.
///
/// The current app uses `CoreAudioSystemAudioCapture`, a private process tap
/// requiring System Audio Recording Only. ScreenCaptureKit is retained as a
/// separate implementation, never an automatic broader-permission fallback.
public protocol SystemAudioCaptureEngine: AnyObject {
    /// Coarse backend name for diagnostics. Must not include device names or process names.
    var diagnosticBackendName: String { get }

    /// Audio format available after `prepare()`. Used to create the WAV file before starting capture.
    var audioFormat: AVAudioFormat? { get }

    /// Fraction of received buffers that contained actual audio data (0.0–1.0).
    var bufferSuccessRate: Double { get }

    /// True when delivered `AVAudioPCMBuffer`s own their sample memory beyond the callback.
    /// The Core Audio backend copies through a bounded realtime-safe ring and
    /// constructs owned buffers on its non-realtime consumer queue.
    var deliversOwnedAudioBuffers: Bool { get }

    /// Publishes error messages for UI status updates (device changes, failures, etc.).
    var errorMessagePublisher: AnyPublisher<String?, Never> { get }

    /// Publishes bounded-recovery device-switch/gap events so the host can
    /// record them the same way it records mic-path recovery. Defaults to an
    /// empty publisher (see the protocol extension below) for backends that
    /// don't need it.
    var recoveryEventPublisher: AnyPublisher<SystemAudioRecoveryEvent, Never> { get }

    /// Set up the capture pipeline (tap/stream creation, format negotiation).
    /// Call once before `start()`. Makes `audioFormat` available.
    func prepare() throws

    /// Begin delivering audio buffers through `bufferCallback`.
    /// Calls `prepare()` automatically if not already called.
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws

    /// Stop capture with a short delay to let the pipeline settle.
    func stop()

    /// Stop capture immediately (no delay). Use when re-preparing the same instance.
    func stopSync()

    /// Stop the producer and synchronously deliver its admitted PCM tail before
    /// returning. Cancellation uses stopSync instead and may discard that tail.
    func finishAndDrain()

    /// Give this backend a proactive recovery opportunity after system wake,
    /// mirroring the mic path's post-wake proactive kick
    /// (`Audio.installWorkspaceSleepWakeObservers`) instead of waiting for a
    /// stall/stop callback. Defaults to a no-op (see the protocol extension
    /// below) for backends without bounded mid-recording recovery.
    func recoverAfterSystemWake()
}

extension SystemAudioCaptureEngine {
    public func finishAndDrain() { stopSync() }
    public var recoveryEventPublisher: AnyPublisher<SystemAudioRecoveryEvent, Never> {
        Empty().eraseToAnyPublisher()
    }

    public func recoverAfterSystemWake() {}
}
