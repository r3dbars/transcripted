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
        // The free-text `latest_reliability_packet` blob is intentionally not
        // emitted here: it can carry paths / free text, and
        // `reliability_packet_count` already gives the coarse signal that reaches
        // Sentry. (The human-readable diagnostics text, built separately, still
        // summarizes recent reliability packets for copied support bundles.)

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

    /// Static positive key allowlist for the support-diagnostic extras that
    /// reach Sentry. `sentryContext` builds a fixed set of coarse keys plus
    /// interpolated `route_*` / `runtime_*` / `storage_*` keys and (previously)
    /// a free-text `latest_reliability_packet` blob. The off-device contract is
    /// allowlist-gated, not just key-drop + redaction, so anything not on this
    /// allowlist or matching a bucketed prefix is dropped before send. The
    /// free-text `latest_reliability_packet` is intentionally excluded —
    /// `reliability_packet_count` already carries the coarse signal. Surviving
    /// values still pass through `SentryPayloadSanitizer` (fragment drop + text
    /// redaction) at the call site as defense-in-depth, so a prefixed key whose
    /// suffix is sensitive (e.g. `runtime_file_path`, `route_raw_url`) is also
    /// dropped downstream. Keep in sync with `sentryContext` above.
    static let sentryContextAllowedKeys: Set<String> = [
        "analytics_available",
        "analytics_enabled",
        "app_version",
        "build_version",
        "calendar_granted",
        "crash_reporting_available",
        "crash_reporting_enabled",
        "meeting_display_status",
        "meeting_duration_bucket",
        "meeting_recording",
        "meeting_review_pending",
        "meeting_shortcut",
        "meeting_state",
        "microphone_status",
        "pasteback_granted",
        "queued_meeting_count",
        "reliability_packet_count",
        "system_recording_granted",
    ]

    static let sentryContextAllowedKeyPrefixes: [String] = [
        "route_",
        "runtime_",
        "storage_",
    ]

    /// Apply the positive key allowlist to a `sentryContext` dictionary,
    /// dropping any key (notably the free-text `latest_reliability_packet`)
    /// that is neither explicitly allowlisted nor a bucketed prefix key.
    static func allowlistedSentryContext(_ context: [String: String]) -> [String: String] {
        context.filter { key, _ in
            sentryContextAllowedKeys.contains(key)
                || sentryContextAllowedKeyPrefixes.contains(where: { key.hasPrefix($0) })
        }
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
