import AVFoundation
import Combine

/// Common interface for system audio capture backends.
///
/// Two implementations exist:
/// - `SystemAudioCapture` (macOS 14.2+) — CoreAudio process taps, requires full Screen Recording permission
/// - `SCKAudioCapture` (macOS 26+) — ScreenCaptureKit audio-only stream, requires lighter "System Audio Recording Only" permission
///
/// `Audio` creates the right one at init time and uses this protocol everywhere else.
public protocol SystemAudioCaptureEngine: AnyObject {
    /// Audio format available after `prepare()`. Used to create the WAV file before starting capture.
    var audioFormat: AVAudioFormat? { get }

    /// Fraction of received buffers that contained actual audio data (0.0–1.0).
    var bufferSuccessRate: Double { get }

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
