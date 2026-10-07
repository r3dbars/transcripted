import Foundation

/// What a pinned microphone capture reports to its owner. Delivered on the
/// capture's serial queue. `.gap` and `.silentInput` are in order with the
/// audio buffers; the state events (`.restarted`, `.deviceLost`, `.failed`)
/// are reported as soon as they happen.
public enum PinnedMicrophoneCaptureEvent: Equatable, Sendable {
    /// Audio resumed after a hole: a restart, a dropped callback, a device
    /// switch, or a wake. `paddedSeconds` of silence follow this event, ahead
    /// of the next real buffer, so the timeline stays continuous (zero when
    /// padding is off; less than `seconds` when the hole was longer than
    /// `maxSilencePadSeconds`). Long pads are paced across timer ticks so the
    /// owner's writer never takes them in one burst.
    case gap(seconds: TimeInterval, paddedSeconds: TimeInterval)
    /// The IOProc was rebuilt on the same pinned device.
    case restarted(PinnedMicrophoneRestartTrigger)
    /// The pinned device went away. Nothing is captured until the owner calls
    /// `switchDevice(to:)` or stops. `isWaitingForDevice` stays true until then.
    case deviceLost
    /// The device has delivered `silentInputDetectionSeconds` of samples that
    /// are all exactly 0.0 (a closed MacBook lid, a digitally muted input).
    /// Reported once per device; `switchDevice(to:)` re-arms it. Capture keeps
    /// running; the owner decides whether to move to another input.
    case silentInput
    /// Capture cannot continue on its own. The owner should stop.
    case failed(String)
}

public enum PinnedMicrophoneRestartTrigger: String, Sendable {
    case stall
    case formatChange = "format_change"
}

public struct PinnedMicrophoneCaptureDiagnostics: Equatable, Sendable {
    public let restarts: Int
    public let gaps: Int
    public let paddedSeconds: TimeInterval
    public let droppedCallbacks: Int
}
