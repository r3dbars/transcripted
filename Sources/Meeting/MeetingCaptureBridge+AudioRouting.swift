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

    // MARK: - Shared meeting microphone routing

    /// Install the shared-meeting-mic dictation consumer, or clear it. The
    /// consumer is installed before capture and only records while dictation
    /// explicitly arms its own recorder.
    func setSharedDictationMicHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        micPCMRelay.setDictationHandler(handler)
    }

    /// Drain both bounded handoffs before Speech finalizes borrowed dictation.
    /// This stays separate from file finalization so a slow disk cannot make
    /// already-admitted dictation PCM disappear at stop.
    func flushSharedDictationMicHandler() async {
        await audio.flushMicHostPCMBufferFanout()
        await micPCMRelay.flush()
    }
}
