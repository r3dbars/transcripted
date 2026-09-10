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
    var installUUID: String = "unknown"
    var buildRevision: String = "unknown"
    var recentFailures: [UsageFailure] = []
}

enum SupportDiagnosticsBundle {
    static let maxRecentLogLines = 20
    static let maxReliabilityPackets = 8

    static func text(snapshot: SupportDiagnosticsSnapshot, now: Date = Date()) -> String {
        let failures = snapshot.recentFailures.prefix(3).map {
            "\($0.time.formatted(date: .abbreviated, time: .shortened)) | \(PayloadSanitizationCore.category($0.kind) ?? "unknown") | \(PayloadSanitizationCore.category($0.stage) ?? "unknown") | version \(PayloadSanitizationCore.category($0.version) ?? "unknown")"
        }

        return """
        Transcripted diagnostics
        Generated: \(ISO8601DateFormatter().string(from: now))

        App
        Version: \(snapshot.appVersion)
        Build: \(snapshot.buildVersion)
        Revision: \(PayloadSanitizationCore.category(snapshot.buildRevision) ?? "unknown")
        Install UUID: \(PayloadSanitizationCore.uuid(snapshot.installUUID) ?? "unknown")
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

        Recent failures
        \(failures.isEmpty ? "No recent failures recorded." : failures.joined(separator: "\n"))

        Privacy
        This diagnostic summary is designed to exclude transcript text, raw audio, file paths, device names, meeting titles, speaker names, emails, tokens, and raw URLs.
        """
    }

    static func sentryContext(snapshot: SupportDiagnosticsSnapshot) -> [String: String] {
        var context: [String: String] = [
            "install_uuid": PayloadSanitizationCore.uuid(snapshot.installUUID) ?? "unknown",
            "build_revision": PayloadSanitizationCore.category(snapshot.buildRevision) ?? "unknown",
            "last_failure_kind": PayloadSanitizationCore.category(snapshot.recentFailures.first?.kind) ?? "none",
            "last_failure_stage": PayloadSanitizationCore.category(snapshot.recentFailures.first?.stage) ?? "none",
            "last_failure_version": PayloadSanitizationCore.category(snapshot.recentFailures.first?.version) ?? "unknown",
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
        // summarizes recent reliability packets for support diagnostic payloads.)

        for (key, value) in safeMetadata(snapshot.audioRoute) {
            context["route_\(key)"] = value
        }

        for (key, value) in safeMetadata(snapshot.runtime) {
            context["runtime_\(key)"] = value
        }

        for (key, value) in safeMetadata(snapshot.storage) {
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
        "install_uuid",
        "build_revision",
        "last_failure_kind",
        "last_failure_stage",
        "last_failure_version",
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
                || sentryContextAllowedKeyPrefixes.contains(where: { prefix in
                    key.hasPrefix(prefix) && safeMetadata([String(key.dropFirst(prefix.count)): context[key]!]).count == 1
                })
        }
    }

    private static func safeMetadata(_ values: [String: String]) -> [String: String] {
        let keys = PayloadSanitizationCore.commonTelemetryKeys.union([
            "session_stage", "session_kind", "session_active", "previous_clean_shutdown", "heartbeat_age_bucket",
            "last_event", "session_duration_bucket", "route_shape", "default_input_class", "default_output_class",
            "selected_input_class", "selection_overrode_default", "input_channels", "output_channels",
            "input_rate_hz", "output_rate_hz", "recovering", "format_ready", "sample_flow_started",
            "known_stale_model_count", "model_cache_total", "known_stale_model_size",
        ])
        return values.filter { key, value in
            guard keys.contains(key) else { return false }
            if key == "model_cache_total" || key == "known_stale_model_size" {
                return value.range(of: #"^[0-9]+(?:[.,][0-9]+)? (?:bytes|KB|MB|GB|TB)$"#, options: .regularExpression) != nil
            }
            return PayloadSanitizationCore.category(value) != nil
        }
    }

    private static func render(_ values: [String: String]) -> String {
        let sanitized = AnalyticsPayloadSanitizer.sanitizeDiagnosticContextForDisplay(safeMetadata(values))
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
