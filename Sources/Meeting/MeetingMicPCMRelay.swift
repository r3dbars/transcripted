@preconcurrency import AVFoundation
import Foundation

/// Stable, off-tap fan-out for the meeting microphone stream. Core installs
/// one callback before capture starts; consumers can then opt in and out
/// without replacing that callback while CoreAudio is running.
final class MeetingMicPCMRelay: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer) -> Void

    private let queue = DispatchQueue(
        label: "com.transcripted.meeting-mic-pcm-relay",
        qos: .userInitiated
    )
    private var livePreviewHandler: Handler?
    private var dictationHandler: Handler?

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        // Audio owns the delivered buffer, so retaining it across this hop is
        // safe. Keep all fan-out and dictation sample work off the tap thread.
        queue.async { [weak self] in
            guard let self else { return }
            self.livePreviewHandler?(buffer)
            self.dictationHandler?(buffer)
        }
    }

    func setLivePreviewHandler(_ handler: Handler?) {
        queue.sync { livePreviewHandler = handler }
    }

    func setDictationHandler(_ handler: Handler?) {
        queue.sync { dictationHandler = handler }
    }
}
