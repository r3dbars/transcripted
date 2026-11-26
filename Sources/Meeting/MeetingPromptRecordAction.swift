import Foundation

/// Owns the async work kicked off by the detected-meeting prompt's Record
/// action. The action belongs to the app lifecycle rather than the prompt
/// panel, so dismissing the panel cannot cancel a start that the user chose.
@available(macOS 14.0, *)
@MainActor
final class MeetingPromptRecordAction {
    typealias StartRecording = (
        MeetingPromptDetector.Candidate,
        [String: String]
    ) async -> Bool

    private let onStartRequested: () -> Void
    private let startRecording: StartRecording
    private let onCompleted: (MeetingPromptDetector.Candidate, Bool) -> Void
    private var startTask: Task<Void, Never>?

    init(
        onStartRequested: @escaping () -> Void,
        startRecording: @escaping StartRecording,
        onCompleted: @escaping (MeetingPromptDetector.Candidate, Bool) -> Void
    ) {
        self.onStartRequested = onStartRequested
        self.startRecording = startRecording
        self.onCompleted = onCompleted
    }

    /// Returns false when a previous Record choice is still resolving.
    @discardableResult
    func record(
        candidate: MeetingPromptDetector.Candidate,
        promptTelemetryProperties: [String: String]
    ) -> Bool {
        guard startTask == nil else { return false }

        onStartRequested()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await self.startRecording(candidate, promptTelemetryProperties)
            self.onCompleted(candidate, started)
            self.startTask = nil
        }
        return true
    }
}
