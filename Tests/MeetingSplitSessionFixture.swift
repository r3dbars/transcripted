// The fast-test target links the app's two controller extensions against
// this recording fixture. Capture, transcription and diagnostics stay local
// to the fixture, while observers, sampling and user actions run unchanged.
import Foundation

@MainActor
final class MeetingSessionController {
    enum State { case recording, stopped }
    enum StopReason { case newMeetingSplit }
    enum StartTrigger { case detectedPrompt }
    var state = State.recording
    var isRecording: Bool { state == .recording }
    var activeRecordingIdentity: UUID? = UUID()
    var activeRecordingStartedAt: Date?
    var meetingSplitOffer: MeetingSplitOffer?
    var latestCallActivity = MeetingCallActivitySnapshot.unknown
    var callEndTracking: MeetingCallEndTracking?
    var pendingCallEndCandidate: (identity: UUID, candidate: MeetingPromptDetector.Candidate)?
    var callEndArming = MeetingCallEndArming()
    var callCameraInUse: Bool?
    var callCameraSampledAt: TimeInterval?
    var audioInactivityWarning: MeetingAudioInactivityWarning?
    var audioInactivityDetector = MeetingAudioInactivityDetector()
    var systemAudioDegradationWarning: MeetingSystemAudioDegradationWarning?
    var audioRouteWarning: Bool?
    var refreshCalendarForSplitAcceptance: (() async -> Bool)?
    var onMeetingSplitDecision: ((MeetingPromptDetector.Candidate, MeetingSplitDecision) -> Void)?
    var callActivitySampler: (@MainActor (@escaping @MainActor @Sendable (MeetingCallActivitySnapshot) -> Void) -> Void)?
    var stops = 0

    func stopRecording(reason: StopReason) async -> Bool? {
        stops += 1
        state = .stopped
        return true
    }
    func startRecording(trigger: StartTrigger, suggestedTitle: String?,
                        detectedCallCandidate: MeetingPromptDetector.Candidate?) async -> Bool { false }
    func applyAudioInactivityEvent(_ event: MeetingAudioInactivityDetector.Event) {}
    func endRecordingFromAudioInactivityPrompt(automatic: Bool, expectedWarning: MeetingAudioInactivityWarning) async {}
    func baseDiagnosticsContext(extra: [String: String]) -> [String: String] { extra }
}

enum DiagnosticsTrail {
    static func record(engine: String, event: String, message: String, context: [String: String]) {}
}
