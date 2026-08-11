import Foundation

/// Whether a failed row's surviving audio actually contains something to
/// transcribe.
///
/// Retry availability used to rest entirely on the persisted failure message,
/// which describes what an older build could not do rather than what is on
/// disk now. This is the second, factual half of that decision: resolving it
/// means decoding audio, so `FailedMeetingStore` answers it off the main actor
/// via `FailedRecordingSignalProbe` and caches the verdict.
///
/// Deliberately Foundation-only and free of the store's `@MainActor` /
/// `TranscriptedCore` dependencies so the presentation policies that consume it
/// stay in the fast-test compile.
enum FailedMeetingUsableAudio: Equatable {
    /// Not probed yet. Callers should stay optimistic and keep retry offered —
    /// that matches the previous behavior, and an action that appears a moment
    /// later reads as a glitch.
    case unknown
    /// At least one surviving file has audible signal.
    case present
    /// Probed, and nothing on disk holds audible signal. Retrying could only
    /// reproduce the original failure.
    case absent
}
