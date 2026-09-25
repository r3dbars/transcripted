import AppKit
import AVFoundation
import Foundation
import TranscriptedCore

@MainActor
enum TranscriptedSupportActions {
    /// True while Email Support gathers diagnostics, so a double click
    /// can't open two drafts.
    private static var isPreparingFeedback = false

    static func sendFeedback(appState: TranscriptedAppState) async {
        guard !isPreparingFeedback else { return }
        isPreparingFeedback = true
        defer { isPreparingFeedback = false }
        SupportEmailDispatcher.open(await feedbackEmailURL(appState: appState))
    }

    /// The last diagnostic event sent this session. Email Support includes
    /// it for an hour so the email and the event can be matched up; after
    /// that it is probably about something else.
    private static var lastDiagnosticReport: (id: String, sentAt: Date)?
    private static let diagnosticReportEmailWindow: TimeInterval = 60 * 60

    static var lastDiagnosticReportID: String? {
        guard let report = lastDiagnosticReport,
              Date().timeIntervalSince(report.sentAt) < diagnosticReportEmailWindow else { return nil }
        return report.id
    }

    static func sendDiagnosticEvent(appState: TranscriptedAppState) async -> String? {
        let snapshot = await diagnosticsSnapshot(appState: appState)
        let context = SupportDiagnosticsBundle.sentryContext(snapshot: snapshot)

        AnalyticsReporter.track("support_diagnostic_event_sent")
        let eventID = CrashReporter.shared.captureSupportDiagnosticEvent(extra: context)
        if let eventID {
            lastDiagnosticReport = (id: eventID, sentAt: Date())
        }
        return eventID
    }

    static func feedbackEmailURL(appState: TranscriptedAppState) async -> URL? {
        FeedbackIssueBuilder.emailURL(
            rawLogLines: [],
            diagnostics: await diagnosticsText(appState: appState),
            diagnosticReportID: lastDiagnosticReportID
        )
    }

    static func diagnosticsText(appState: TranscriptedAppState) async -> String {
        SupportDiagnosticsBundle.text(snapshot: await diagnosticsSnapshot(appState: appState))
    }

    static var appVersionDescription: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (short?, build?) where !short.isEmpty && !build.isEmpty && short != build:
            return "Version \(short) (\(build))"
        case let (short?, _) where !short.isEmpty:
            return "Version \(short)"
        case let (_, build?) where !build.isEmpty:
            return "Build \(build)"
        default:
            return "Version unavailable"
        }
    }

    private static func diagnosticsSnapshot(appState: TranscriptedAppState) async -> SupportDiagnosticsSnapshot {
        // The model-cache walk and the reliability log read touch disk (the
        // cache holds many CoreML files, the log can be ~10 MB), so they run
        // off the main thread. Everything else here is cheap in-memory state.
        let diskFields = await Task.detached(priority: .userInitiated) {
            (
                storage: diskFields.storage,
                reliabilityPackets: ReliabilityPacketRecorder.recentPacketSummaries()
            )
        }.value

        let meetingState: String
        let meetingRecording: Bool
        let meetingDurationBucket: String
        let meetingDisplayStatus: String
        let speakerReviewPending: Bool
        let queuedMeetingCount: Int
        let meetingShortcut: String
        if #available(macOS 14.0, *) {
            meetingState = meetingStateName(appState.meetingSession.state)
            meetingRecording = appState.meetingSession.isRecording
            meetingDurationBucket = AnalyticsReporter.durationBucket(seconds: appState.meetingSession.recordingDuration)
            meetingDisplayStatus = displayStatusName(appState.meetingSession.displayStatus)
            speakerReviewPending = appState.meetingSession.isSpeakerReviewPending
            queuedMeetingCount = appState.meetingSession.queuedTranscriptionCount
            meetingShortcut = appState.contextCapture.meetingShortcutDisplay
        } else {
            meetingState = "unavailable"
            meetingRecording = false
            meetingDurationBucket = "lt_10s"
            meetingDisplayStatus = "unavailable"
            speakerReviewPending = false
            queuedMeetingCount = 0
            meetingShortcut = "unavailable"
        }

        return SupportDiagnosticsSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            crashReportingAvailable: CrashReporter.isAvailable,
            crashReportingEnabled: CrashReportingPreferences.isEnabled(),
            analyticsAvailable: AnalyticsReporter.isAvailable,
            analyticsEnabled: AnalyticsPreferences.isEnabled(),
            microphoneStatus: microphoneStatusName(TranscriptedPermissionAccess.microphoneAuthorizationStatus()),
            systemAudioRecordingGranted: TranscriptedPermissionAccess.isGranted(.systemAudioRecording),
            pastebackGranted: TranscriptedPermissionAccess.isGranted(.accessibility),
            calendarGranted: TranscriptedPermissionAccess.isGranted(.calendar),
            audioRoute: appState.sttRouter.dictationAudioRouteAnalyticsContext,
            runtime: appState.runtimeDiagnostics.currentAnalyticsContext(),
            storage: diskFields.storage,
            meetingState: meetingState,
            meetingRecording: meetingRecording,
            meetingDurationBucket: meetingDurationBucket,
            meetingDisplayStatus: meetingDisplayStatus,
            speakerReviewPending: speakerReviewPending,
            queuedMeetingCount: queuedMeetingCount,
            meetingShortcut: meetingShortcut,
            reliabilityPackets: diskFields.reliabilityPackets,
            recentLogLines: [],
            installUUID: InstallIdentity.id(),
            buildRevision: AnalyticsRuntimeConfiguration.buildRevision(),
            recentFailures: UsageHealthStore.shared.snapshot().failures
        )
    }

    private static func microphoneStatusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "unknown"
        }
    }

    @available(macOS 14.0, *)
    private static func meetingStateName(_ state: MeetingSessionController.State) -> String {
        switch state {
        case .idle: return "idle"
        case .loadingModels: return "loading_models"
        case .ready: return "ready"
        case .startingRecording: return "starting_recording"
        case .recording: return "recording"
        case .stoppingRecording: return "stopping_recording"
        case .transcribing: return "transcribing"
        case .error: return "error"
        }
    }

    private static func displayStatusName(_ status: DisplayStatus) -> String {
        switch status {
        case .idle:
            return "idle"
        case .gettingReady:
            return "getting_ready"
        case .transcribing:
            return "transcribing"
        case .finishing:
            return "finishing"
        case .transcriptSaved:
            return "transcript_saved"
        case .discardedAccidentalStart:
            return "discarded_accidental_start"
        case .failed:
            return "failed"
        }
    }
}
