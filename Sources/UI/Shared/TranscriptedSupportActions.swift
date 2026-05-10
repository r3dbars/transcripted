import AppKit
import AVFoundation
import Foundation

@MainActor
enum TranscriptedSupportActions {
    enum FeedbackEmailResult: Equatable {
        case opened
        case copiedDraftToClipboard
        case unavailable

        var statusMessage: String? {
            switch self {
            case .opened:
                return "Opened a prefilled email."
            case .copiedDraftToClipboard:
                return "Mail did not open, so the email draft was copied."
            case .unavailable:
                return nil
            }
        }
    }

    @discardableResult
    static func sendFeedback(appState: TranscriptedAppState) -> FeedbackEmailResult {
        guard let url = feedbackEmailURL(appState: appState) else { return .unavailable }
        return openFeedbackEmail(url)
    }

    @discardableResult
    static func sendFeedback(logger: AppLogger?) -> FeedbackEmailResult {
        guard let url = FeedbackIssueBuilder.emailURL(rawLogLines: logger?.entries) else { return .unavailable }
        return openFeedbackEmail(url)
    }

    @discardableResult
    static func openFeedbackEmail(_ url: URL) -> FeedbackEmailResult {
        if NSWorkspace.shared.open(url) {
            AppSoundPlayer.shared.play(.feedbackSubmitted, respectingPreferences: false)
            return .opened
        }

        guard let draftText = FeedbackIssueBuilder.emailDraftText(from: url) else {
            return .unavailable
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(draftText, forType: .string) else {
            return .unavailable
        }

        AppSoundPlayer.shared.play(.feedbackSubmitted, respectingPreferences: false)
        return .copiedDraftToClipboard
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
            if let meetingSession = appState.loadedMeetingSession {
                meetingState = meetingStateName(meetingSession.state)
                meetingRecording = meetingSession.isRecording
                meetingDurationBucket = AnalyticsReporter.durationBucket(seconds: meetingSession.recordingDuration)
            } else {
                meetingState = "not_loaded"
                meetingRecording = false
                meetingDurationBucket = "lt_10s"
            }
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
