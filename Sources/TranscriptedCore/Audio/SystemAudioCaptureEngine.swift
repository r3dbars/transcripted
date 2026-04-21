import AVFoundation
import Combine

/// Common interface for system audio capture backends.
///
/// The current app uses `SCKAudioCapture` (macOS 26+) — a ScreenCaptureKit
/// audio-only stream that stays on the lighter "System Audio Recording Only"
/// permission tier.
///
/// Legacy `SystemAudioCapture` still conforms to this protocol for older or
/// standalone paths, but the live Transcripted app no longer routes through it.
public protocol SystemAudioCaptureEngine: AnyObject {
    /// Audio format available after `prepare()`. Used to create the WAV file before starting capture.
    var audioFormat: AVAudioFormat? { get }

    /// Fraction of received buffers that contained actual audio data (0.0–1.0).
    var bufferSuccessRate: Double { get }

    /// True when delivered `AVAudioPCMBuffer`s own their sample memory beyond the callback.
    /// Legacy CoreAudio taps wrap borrowed memory, while ScreenCaptureKit conversion already
    /// copies into an owned buffer.
    var deliversOwnedAudioBuffers: Bool { get }

    /// Publishes error messages for UI status updates (device changes, failures, etc.).
    var errorMessagePublisher: AnyPublisher<String?, Never> { get }

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
}
