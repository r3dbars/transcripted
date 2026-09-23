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
