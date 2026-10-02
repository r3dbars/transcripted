import AVFoundation
import Foundation

extension Audio {
    /// Optional provisional transcription consumer. Install once before capture;
    /// buffers arrive on a bounded worker, never on an audio or file-write thread.
    /// Its overflow drops live-preview buffers only; saved recording is unaffected.
    public var onLivePCMBuffer: ((AVAudioPCMBuffer, LiveMeetingAudioSource, TimeInterval, UInt64) -> Void)? {
        get { livePCMDelivery.handler }
        set { livePCMDelivery.handler = newValue }
    }

    public func setLivePCMDeliveryEnabled(_ enabled: Bool, previewEpoch: UInt64) {
        livePCMDelivery.setEnabled(enabled, captureGeneration: recordingSessionGeneration, previewEpoch: previewEpoch)
    }

    public var livePCMDroppedBufferCount: Int { livePCMDelivery.dropCount }
}
