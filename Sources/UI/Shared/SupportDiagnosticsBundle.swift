import Foundation

struct SupportDiagnosticsSnapshot: Equatable {
    var appVersion: String
    var buildVersion: String
    var osVersion: String
    var crashReportingAvailable: Bool
    var crashReportingEnabled: Bool
    var analyticsAvailable: Bool
    var analyticsEnabled: Bool
    var microphoneStatus: String
    var systemAudioRecordingGranted: Bool
    var pastebackGranted: Bool
    var calendarGranted: Bool
    var audioRoute: [String: String]
    var runtime: [String: String]
    var storage: [String: String] = [:]
    var meetingState: String
    var meetingRecording: Bool
    var meetingDurationBucket: String
    var meetingDisplayStatus: String = "unknown"
    var speakerReviewPending: Bool = false
    var queuedMeetingCount: Int = 0
    var meetingShortcut: String = "unknown"
    var reliabilityPackets: [String]
    var recentLogLines: [String]
}

enum SupportDiagnosticsBundle {
    static let maxRecentLogLines = 20
    static let maxReliabilityPackets = 8

    static func text(snapshot: SupportDiagnosticsSnapshot, now: Date = Date()) -> String {
        let reliabilityPackets = snapshot.reliabilityPackets
            .suffix(maxReliabilityPackets)
            .map(AnalyticsPayloadSanitizer.redact)
            .filter { !$0.isEmpty }
        let recentLogs = snapshot.recentLogLines
            .suffix(maxRecentLogLines)
            .map(AnalyticsPayloadSanitizer.redact)
            .filter { !$0.isEmpty }

        return """
        Transcripted diagnostics
        Generated: \(ISO8601DateFormatter().string(from: now))

        App
        Version: \(snapshot.appVersion)
        Build: \(snapshot.buildVersion)
        macOS: \(snapshot.osVersion)

        Reporting
        Crash reporting: \(status(available: snapshot.crashReportingAvailable, enabled: snapshot.crashReportingEnabled))
        Anonymous analytics: \(status(available: snapshot.analyticsAvailable, enabled: snapshot.analyticsEnabled))

        Permissions
        Microphone: \(snapshot.microphoneStatus)
        System audio recording: \(bool(snapshot.systemAudioRecordingGranted))
        Paste-back accessibility: \(bool(snapshot.pastebackGranted))
        Calendar: \(bool(snapshot.calendarGranted))

        Runtime
        \(render(snapshot.runtime))

        Storage
        \(render(snapshot.storage))

        Audio Route
        \(render(snapshot.audioRoute))

        Meeting
        State: \(snapshot.meetingState)
        Display status: \(snapshot.meetingDisplayStatus)
        Recording: \(bool(snapshot.meetingRecording))
        Duration: \(snapshot.meetingDurationBucket)
        Speaker review pending: \(bool(snapshot.speakerReviewPending))
        Queued meetings: \(snapshot.queuedMeetingCount)
        Meeting shortcut: \(snapshot.meetingShortcut)

        Reliability Packets
        \(reliabilityPackets.isEmpty ? "No recent reliability packets." : reliabilityPackets.joined(separator: "\n"))

        Recent Events
        \(recentLogs.isEmpty ? "No recent in-app events." : recentLogs.joined(separator: "\n"))

        Privacy
        This diagnostic summary is designed to exclude transcript text, raw audio, file paths, device names, meeting titles, speaker names, emails, tokens, and raw URLs.
        """
    }

    static func sentryContext(snapshot: SupportDiagnosticsSnapshot) -> [String: String] {
        var context: [String: String] = [
            "analytics_available": bool(snapshot.analyticsAvailable),
            "analytics_enabled": bool(snapshot.analyticsEnabled),
            "app_version": snapshot.appVersion,
            "build_version": snapshot.buildVersion,
            "calendar_granted": bool(snapshot.calendarGranted),
            "crash_reporting_available": bool(snapshot.crashReportingAvailable),
            "crash_reporting_enabled": bool(snapshot.crashReportingEnabled),
            "meeting_display_status": snapshot.meetingDisplayStatus,
            "meeting_duration_bucket": snapshot.meetingDurationBucket,
            "meeting_recording": bool(snapshot.meetingRecording),
            "meeting_review_pending": bool(snapshot.speakerReviewPending),
            "meeting_shortcut": snapshot.meetingShortcut,
            "meeting_state": snapshot.meetingState,
            "microphone_status": snapshot.microphoneStatus,
            "pasteback_granted": bool(snapshot.pastebackGranted),
            "queued_meeting_count": "\(snapshot.queuedMeetingCount)",
            "reliability_packet_count": "\(min(snapshot.reliabilityPackets.count, maxReliabilityPackets))",
            "system_recording_granted": bool(snapshot.systemAudioRecordingGranted),
        ]
        if let latest = snapshot.reliabilityPackets.last {
            context["latest_reliability_packet"] = latest
        }

        for (key, value) in snapshot.audioRoute {
            context["route_\(key)"] = value
        }

        for (key, value) in snapshot.runtime {
            context["runtime_\(key)"] = value
        }

        for (key, value) in snapshot.storage {
            context["storage_\(key)"] = value
        }

        return context
    }

    private static func render(_ values: [String: String]) -> String {
        let sanitized = AnalyticsPayloadSanitizer.sanitizeDiagnosticContextForDisplay(values)
        guard !sanitized.isEmpty else { return "Unavailable" }
        return sanitized
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func status(available: Bool, enabled: Bool) -> String {
        guard available else { return "unavailable" }
        return enabled ? "enabled" : "disabled"
    }

    private static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}
