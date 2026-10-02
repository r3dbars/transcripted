import AppKit
import Combine
import Foundation

/// App-facing companion owner. Socket I/O stays on its utility queue; every
/// permission decision and capture action runs on the same main actor as the UI.
@MainActor
final class CompanionConnectionService: ObservableObject {
    static let shared = CompanionConnectionService()

    @Published private(set) var isEnabled = CompanionPreferences.isEnabled()
    @Published private(set) var allowsMeetingControl = CompanionPreferences.allowsMeetingControl()
    @Published private(set) var allowsLiveSharing = CompanionPreferences.allowsLiveSharing()
    @Published private(set) var isListening = false
    @Published private(set) var connectionIssue: String?
    @Published private(set) var liveSharingActive = false
    @Published private(set) var captureActive = false
    @Published private(set) var canShareCurrentMeeting = false

    private weak var meetingSession: MeetingSessionController?
    private var stateSubscription: AnyCancellable?
    private let server = CompanionSocketServer(directory: FileManager.default.transcriptedAppSupportRootURL
        .appendingPathComponent("companion", isDirectory: true))
    private var controlInFlight = false
    private var configured = false
    private var connectionEpoch = CompanionConnectionEpoch()
    private var terminationObserver: NSObjectProtocol?

    func configure(meetingSession: MeetingSessionController) {
        guard !AutomatedLaunchEnvironment.isActive() else { return }
        self.meetingSession = meetingSession
        configured = true
        stateSubscription = meetingSession.$state.sink { [weak self] _ in
            // Combine publishes before updating the property. Refresh on the
            // next main-actor turn so captureActive describes the new state.
            Task { @MainActor [weak self] in self?.refreshCaptureState() }
        }
        refreshCaptureState()
        reconcileConnection()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { CompanionConnectionService.shared.shutdown() } }
    }

    func setEnabled(_ enabled: Bool) {
        guard !AutomatedLaunchEnvironment.isActive() else { return }
        UserDefaults.standard.set(enabled, forKey: CompanionPreferences.enabledKey)
        isEnabled = enabled
        if !enabled { revokeLiveSharing() }
        reconcileConnection()
    }

    func setAllowsMeetingControl(_ enabled: Bool) {
        guard !AutomatedLaunchEnvironment.isActive() else { return }
        UserDefaults.standard.set(enabled, forKey: CompanionPreferences.meetingControlKey)
        allowsMeetingControl = enabled
    }

    func setAllowsLiveSharing(_ enabled: Bool) {
        guard !AutomatedLaunchEnvironment.isActive() else { return }
        UserDefaults.standard.set(enabled, forKey: CompanionPreferences.liveSharingKey)
        allowsLiveSharing = enabled
        if !enabled { revokeLiveSharing() }
    }

    func setCurrentMeetingSharing(_ enabled: Bool) {
        guard isEnabled, allowsLiveSharing, let id = LiveMeetingTranscriptService.shared.sessionID,
              !enabled || meetingSession?.isRecording == true else { return }
        _ = LiveMeetingTranscriptService.shared.setSharingEnabled(enabled, sessionID: id)
        refreshCaptureState()
    }

    func reconnect() {
        connectionEpoch.invalidate()
        server.stop()
        isListening = false
        reconcileConnection()
    }

    func shutdown() {
        connectionEpoch.invalidate()
        revokeLiveSharing()
        server.stop()
        isListening = false
    }

    private func reconcileConnection() {
        guard configured, isEnabled else {
            connectionEpoch.invalidate()
            server.stop()
            isListening = false
            connectionIssue = nil
            return
        }
        guard !isListening else { return }
        let lease = connectionEpoch.begin()
        do {
            try server.start { [weak self] request, reply in
                Task { @MainActor [weak self] in
                    guard let self else {
                        reply(CompanionProtocol.response(id: request.id, failure: .permissionDenied))
                        return
                    }
                    reply(await self.handle(request, lease: lease))
                }
            }
            isListening = true
            connectionIssue = nil
        } catch {
            connectionEpoch.invalidate()
            isListening = false
            // Never expose a Foundation/POSIX description: it can contain the
            // user's path, credential, or device identifiers.
            connectionIssue = "The local connection couldn’t open. Reconnect to try again."
        }
    }

    private func refreshCaptureState() {
        captureActive = meetingSession?.isCaptureSessionActive == true
        canShareCurrentMeeting = meetingSession?.isRecording == true
        liveSharingActive = LiveMeetingTranscriptService.shared.sharingEnabled
    }

    private func revokeLiveSharing() {
        if let id = LiveMeetingTranscriptService.shared.sessionID {
            _ = LiveMeetingTranscriptService.shared.setSharingEnabled(false, sessionID: id)
        }
        refreshCaptureState()
    }

    private func status() -> [String: Any] {
        var result = LiveMeetingTranscriptService.shared.statusSnapshot()
        result["companion_enabled"] = isEnabled
        result["allow_meeting_control"] = allowsMeetingControl
        result["allow_live_sharing"] = allowsLiveSharing
        result["capture_active"] = meetingSession?.isCaptureSessionActive == true
        if let meetingSession {
            switch meetingSession.state {
            case .idle: result["recording_state"] = "idle"
            case .loadingModels: result["recording_state"] = "loading_models"
            case .ready: result["recording_state"] = "ready"
            case .startingRecording: result["recording_state"] = "starting_recording"
            case .recording: result["recording_state"] = "recording"
            case .stoppingRecording: result["recording_state"] = "stopping_recording"
            case .transcribing: result["recording_state"] = "transcribing"
            case .error: result["recording_state"] = "error"
            }
        }
        return result
    }

    private func handle(_ request: CompanionRequest, lease: UUID) async -> Data {
        guard connectionEpoch.accepts(lease), isEnabled, isListening, let meetingSession else {
            return CompanionProtocol.response(id: request.id, failure: .permissionDenied)
        }
        let live = LiveMeetingTranscriptService.shared
        let result: [String: Any]
        switch request.method {
        case .status:
            result = status()
        case .startMeeting(let shareLive):
            guard allowsMeetingControl, !shareLive || allowsLiveSharing else {
                return CompanionProtocol.response(id: request.id, failure: .permissionDenied)
            }
            guard !controlInFlight, !meetingSession.isCaptureSessionActive else {
                return failure(request, code: "capture_busy", message: "A meeting is already starting, recording, or stopping.")
            }
            controlInFlight = true
            let started = await meetingSession.startRecording(trigger: .menu)
            controlInFlight = false
            guard started else {
                return failure(request, code: "start_failed", message: "The meeting couldn’t start. Check Transcripted for permissions or capture details.")
            }
            if shareLive, connectionEpoch.accepts(lease), isEnabled, allowsLiveSharing, let id = live.sessionID {
                _ = live.setSharingEnabled(true, sessionID: id)
            }
            refreshCaptureState()
            var snapshot = status()
            snapshot["started"] = true
            result = snapshot
        case .stopMeeting(let id):
            guard allowsMeetingControl else { return CompanionProtocol.response(id: request.id, failure: .permissionDenied) }
            guard live.sessionID == id else { return CompanionProtocol.response(id: request.id, failure: .staleSession) }
            // During a pending start, a retained previous session ID must never
            // authorize stopping the new meeting after that start resolves.
            guard !controlInFlight, meetingSession.isRecording else {
                return failure(request, code: "capture_busy", message: "This meeting is not currently recording. Refresh meeting status.")
            }
            controlInFlight = true
            await meetingSession.stopRecordingJoiningPendingStart(reason: .menuBarStopButton)
            controlInFlight = false
            refreshCaptureState()
            var snapshot = status()
            snapshot["stopped"] = true
            result = snapshot
        case .setLiveSharing(let id, let enabled):
            guard live.sessionID == id else { return CompanionProtocol.response(id: request.id, failure: .staleSession) }
            guard !enabled || allowsLiveSharing else {
                return CompanionProtocol.response(id: request.id, failure: .permissionDenied)
            }
            guard !enabled || meetingSession.isRecording else {
                return failure(request, code: "capture_busy", message: "Live sharing can start while this meeting is recording.")
            }
            guard live.setSharingEnabled(enabled, sessionID: id) else {
                return failure(request, code: "live_unavailable", message: "Live context is unavailable for this meeting.")
            }
            refreshCaptureState()
            result = status()
        case .readLiveTranscript(let id, let after, let limit):
            guard live.sessionID == id else { return CompanionProtocol.response(id: request.id, failure: .staleSession) }
            guard allowsLiveSharing, live.sharingEnabled else {
                return CompanionProtocol.response(id: request.id, failure: .permissionDenied)
            }
            guard let transcript = live.readLive(sessionID: id, afterSequence: after, limit: limit) else {
                return failure(request, code: "live_unavailable", message: "Live context is unavailable for this meeting.")
            }
            result = transcript
        }
        return CompanionProtocol.response(id: request.id, result: result)
    }

    private func failure(_ request: CompanionRequest, code: String, message: String) -> Data {
        CompanionProtocol.response(id: request.id, failure: CompanionFailure(code: code, message: message))
    }
}
