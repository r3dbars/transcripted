import Foundation

/// Why Core ended a meeting recording on its own, with no app-side stop.
/// The app sends the raw value as `stop_cause` on
/// `meeting_capture_stopped_under_controller`, so each case must stay a
/// short, telemetry-safe category (no user content, no sanitizer drop
/// fragments). Before this existed every such stop looked the same in
/// Sentry and PostHog, and about half of APPLE-MACOS-2D couldn't be named.
public enum InternalCaptureStopCause: String, CaseIterable, Sendable {
    /// The mic watchdog spent its recovery attempts with no system audio left.
    case micRecoveryGaveUp = "mic_recovery_gave_up"
    /// The pinned meeting microphone could not be restarted.
    case pinnedMicFailed = "pinned_mic_failed"
    /// Free disk space under the recording floor.
    case diskLow = "disk_low"
    /// Too many consecutive mic file write errors.
    case micWriteFailed = "mic_write_failed"
    /// Mic buffers backed up past the write limit.
    case micWriteBackpressure = "mic_write_backpressure"
    /// System-audio buffers backed up past the write limit.
    case systemWriteBackpressure = "system_write_backpressure"
}
