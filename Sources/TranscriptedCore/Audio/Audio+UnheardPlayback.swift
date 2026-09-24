import Foundation

extension Audio {
    /// True while the system-audio tap has heard only digital silence for a
    /// sustained stretch, after its own reconnects, while another app kept
    /// playing audio: the other side of the call is probably not being
    /// recorded. Cleared as soon as the tap hears real signal. Scoped to the
    /// live recording; hosts latch it themselves if they need it after stop.
    /// A lock-free read that is safe on the main thread.
    public var isSystemAudioNotHearingPlayback: Bool {
        (systemAudioCapture as? CoreAudioSystemAudioCapture)?.isNotHearingPlayback ?? false
    }
}

extension Audio {
    /// True for the rest of the recording once call audio came back only
    /// after a new tap or a new output. The silence the host warned about was
    /// a real loss. When signal returns on the same tap instead, the call was
    /// just quiet and this stays false. Lock-free read.
    public var systemAudioDidLosePlayback: Bool {
        (systemAudioCapture as? CoreAudioSystemAudioCapture)?.didLosePlayback ?? false
    }
}
