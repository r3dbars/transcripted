import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
extension MeetingSessionController {
    /// Hands the live transcript service this recording's capture, once per
    /// recording identity. Nothing transcribes until the person turns on live
    /// sharing for this session; the saved meeting pipeline is unaffected.
    func beginLiveTranscriptCaptureIfNeeded() {
        guard let identity = activeRecordingIdentity,
              LiveMeetingTranscriptService.shared.sessionID != identity else { return }
        LiveMeetingTranscriptService.shared.beginCapture(
            sessionID: identity, router: sttRouter, model: recordingSTTModel,
            languageSelection: recordingLanguageSelection,
            capturesSystemAudio: capture.currentRecordingCapturesSystemAudio,
            deliveryEnabled: { [weak capture = capture] enabled, epoch in capture?.setLivePCMDeliveryEnabled(enabled, previewEpoch: epoch) },
            deliveryDrops: { [weak capture = capture] in capture?.livePCMDroppedBufferCount ?? 0 },
            mayInfer: { [weak self] in
                guard let self else { return false }
                return !self.taskManager.hasActiveTranscriptionWorkRequiringQuitConfirmation
            },
            // A dictation gets the Neural Engine to itself; the island's live
            // transcript queues its audio and catches up after.
            shouldCaptionsYield: { [weak router = sttRouter] in
                guard let router else { return false }
                return router.isRecording || router.isTranscribing
            }
        )
    }
}
