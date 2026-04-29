import Foundation

/// Result of a stop request. `didTimeOut == true` means we did not receive
/// `Audio.onRecordingComplete` within `meetingStopTimeout`, so the WAV files
/// at the returned URLs may not be fully finalized — the controller should
/// route the audio to the failed queue rather than enqueuing for transcription.
struct CaptureStopResult {
    let micURL: URL?
    let systemURL: URL?
    let didTimeOut: Bool
}

final class MeetingCaptureAttempt<Output> {
    private var continuation: CheckedContinuation<Output, Never>?
    private var attemptID: UUID?
    private var timeoutTask: Task<Void, Never>?

    deinit {
        timeoutTask?.cancel()
    }

    func begin(_ continuation: CheckedContinuation<Output, Never>) -> UUID {
        let attemptID = UUID()
        self.continuation = continuation
        self.attemptID = attemptID
        return attemptID
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        timeoutTask?.cancel()
        timeoutTask = task
    }

    func reset() -> CheckedContinuation<Output, Never>? {
        let continuation = continuation
        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        attemptID = nil
        return continuation
    }

    func resetIfCurrent(_ attemptID: UUID) -> CheckedContinuation<Output, Never>? {
        guard self.attemptID == attemptID else { return nil }
        return reset()
    }
}
