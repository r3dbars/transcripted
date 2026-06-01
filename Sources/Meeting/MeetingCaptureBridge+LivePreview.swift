import AVFoundation
import TranscriptedCore

@available(macOS 14.0, *)
extension MeetingCaptureBridge {
    /// Snapshot of Core's recording health metadata for transcript
    /// frontmatter.
    ///
    /// `overrideSystemAudioStatus` lets the caller pass the system-audio
    /// status they captured BEFORE `stopAndAwaitFiles()` ran — useful
    /// because `Audio.stop()` resets `systemAudioStatus` to `.unknown` as
    /// part of its UI cleanup, which would otherwise mask a real `.failed`
    /// outcome in the resulting `captureQuality`.
    func healthInfo(
        overrideSystemAudioStatus: SystemAudioStatus? = nil
    ) -> RecordingHealthInfo {
        audio.createHealthInfo(overrideSystemAudioStatus: overrideSystemAudioStatus)
    }

    // MARK: - Live PCM buffer routing (dual-stream preview)
    //
    // These forward TranscriptedCore's new live-buffer hooks through the
    // bridge so MeetingSessionController can route mic + system buffers to
    // the live meeting streaming ASR sidecar without touching the
    // Audio class directly. Fired on the CoreAudio capture thread — the
    // handler MUST be real-time safe (no I/O, no locks held across async,
    // no allocations beyond small copies). See Audio.swift's
    // `onMicPCMBuffer` docstring in TranscriptedCore for the full contract.

    /// Install a live-preview handler for mic buffers, or clear with `nil`.
    /// Call once before `startRecording()`; do not reassign mid-session.
    func setMicLivePreviewHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        audio.onMicPCMBuffer = handler
    }

    /// Install a live-preview handler for system-audio buffers, or clear
    /// with `nil`. Call once before `startRecording()`; do not reassign
    /// mid-session.
    func setSystemLivePreviewHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        audio.onSystemPCMBuffer = handler
    }
}
