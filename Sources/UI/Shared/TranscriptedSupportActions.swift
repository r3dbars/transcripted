import AppKit
import AVFoundation
import Foundation

@MainActor
enum TranscriptedSupportActions {
    static func sendFeedback(appState: TranscriptedAppState) {
        guard let url = feedbackEmailURL(appState: appState) else { return }
        AppSoundPlayer.shared.play(.feedbackSubmitted, respectingPreferences: false)
        NSWorkspace.shared.open(url)
    }

    static func sendFeedback(logger: AppLogger?) {
        guard let url = FeedbackIssueBuilder.emailURL(rawLogLines: logger?.entries) else { return }
        AppSoundPlayer.shared.play(.feedbackSubmitted, respectingPreferences: false)
        NSWorkspace.shared.open(url)
    }

    static func copyDiagnostics(appState: TranscriptedAppState) -> Bool {
        let text = diagnosticsText(appState: appState)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(text, forType: .string)
        if copied {
            AnalyticsReporter.track("support_diagnostics_copied")
        }
        return copied
    }

    static func sendDiagnosticEvent(appState: TranscriptedAppState) -> String? {
        let snapshot = diagnosticsSnapshot(appState: appState)
        let context = SupportDiagnosticsBundle.sentryContext(snapshot: snapshot)

        AnalyticsReporter.track("support_diagnostic_event_sent")
        return CrashReporter.shared.captureSupportDiagnosticEvent(extra: context)
    }

    static func feedbackEmailURL(logger: AppLogger?) -> URL? {
        FeedbackIssueBuilder.emailURL(rawLogLines: logger?.entries)
    }

    static func feedbackEmailURL(appState: TranscriptedAppState) -> URL? {
        FeedbackIssueBuilder.emailURL(
            rawLogLines: appState.logger.entries,
            diagnostics: diagnosticsText(appState: appState)
        )
    }

    static func diagnosticsText(appState: TranscriptedAppState) -> String {
        SupportDiagnosticsBundle.text(snapshot: diagnosticsSnapshot(appState: appState))
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

    private static func diagnosticsSnapshot(appState: TranscriptedAppState) -> SupportDiagnosticsSnapshot {
        let meetingState: String
        let meetingRecording: Bool
        let meetingDurationBucket: String
        if #available(macOS 14.0, *) {
            meetingState = meetingStateName(appState.meetingSession.state)
            meetingRecording = appState.meetingSession.isRecording
            meetingDurationBucket = AnalyticsReporter.durationBucket(seconds: appState.meetingSession.recordingDuration)
        } else {
            meetingState = "unavailable"
            meetingRecording = false
            meetingDurationBucket = "lt_10s"
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
            storage: ModelCacheInventory.snapshot().diagnosticsFields,
            meetingState: meetingState,
            meetingRecording: meetingRecording,
            meetingDurationBucket: meetingDurationBucket,
            reliabilityPackets: ReliabilityPacketRecorder.recentPacketSummaries(),
            recentLogLines: appState.logger.entries
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
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .error: return "error"
        }
    }
}
