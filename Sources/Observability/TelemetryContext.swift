import Foundation

/// Shared metadata contract. Only UUIDs and categorical state cross the reporting boundary.
enum TelemetryContext {
    static let launchSessionID = UUID().uuidString
    static let keys = PayloadSanitizationCore.commonTelemetryKeys
    static let deviceClasses: Set<String> = [
        "built_in", "bluetooth", "usb", "aggregate", "virtual", "continuity", "wired", "external",
        "hdmi", "displayport", "airplay", "thunderbolt", "firewire", "pci", "unknown", "none",
    ]

    static func permissions() -> [String: String] {
        [
            "mic_permission_granted": String(TranscriptedPermissionAccess.isGranted(.microphone)),
            "screen_permission_granted": String(TranscriptedPermissionAccess.isGranted(.systemAudioRecording)),
            "accessibility_permission_granted": String(TranscriptedPermissionAccess.isGranted(.accessibility)),
        ]
    }

    static func enrich(
        event: String,
        properties: [String: String],
        isFailure: Bool = false,
        environment: [String: String] = permissions()
    ) -> [String: String] {
        var result = properties
        for (key, value) in environment where result[key] == nil { result[key] = value }
        result["app_version"] = result["app_version"] ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        result["build_revision"] = result["build_revision"] ?? AnalyticsRuntimeConfiguration.buildRevision()
        result["os_major"] = result["os_major"] ?? String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        let session = uuid(result["session_id"]) ?? uuid(result["dictation_session_id"]) ?? launchSessionID
        result["session_id"] = session
        result["correlation_id"] = uuid(result["correlation_id"]) ?? UUID().uuidString
        for key in ["input_device_class", "output_device_class"] {
            if !deviceClasses.contains(result[key] ?? "") { result[key] = "unknown" }
        }
        result["selection_reason"] = category(result["selection_reason"]) ?? "unknown"
        result["trigger"] = category(result["trigger"]) ?? "unknown"
        for key in ["mic_permission_granted", "screen_permission_granted", "accessibility_permission_granted"] {
            result[key] = result[key] == "true" ? "true" : "false"
        }
        let outcome = category(result["capture_outcome"]) ?? "unknown"
        let outcomeFailure = ["no_audio", "timed_out", "stop_timed_out", "failed"].contains(outcome)
        let failed = isFailure || event.hasSuffix("_failed") || event == "reliability_failure_observed" || outcomeFailure
        if failed || event == "product_friction_observed" || event == "meeting_capture_health_snapshot" {
            let fallbackKind = outcomeFailure ? outcome
                : failed ? (category(event) ?? "unknown")
                : event == "meeting_capture_health_snapshot" && outcome == "unknown" ? "unknown" : "none"
            result["failure_kind"] = category(result["failure_kind"]) ?? fallbackKind
            result["failure_stage"] = category(result["failure_stage"])
                ?? category(result["start_failure_stage"]) ?? category(result["stage"])
                ?? category(result["session_stage"]) ?? stage(for: event)
        }
        if event == "meeting_capture_health_snapshot" {
            result["quality_reason"] = category(result["quality_reason"]) ?? "unknown"
            result["capture_outcome"] = category(result["capture_outcome"]) ?? "unknown"
        }
        return result
    }

    static func uuid(_ value: String?) -> String? { PayloadSanitizationCore.uuid(value) }
    static func category(_ value: String?) -> String? { PayloadSanitizationCore.category(value) }

    static func stage(for event: String) -> String {
        if event.contains("speaker_finalization") { return "speaker_finalization" }
        if event.contains("start") || event.contains("mic_not_authorized") { return "start" }
        if event.contains("transcript") { return "transcription" }
        if event.contains("stop") || event.contains("health") { return "capture_stop" }
        if event.contains("delivery") || event.contains("paste") { return "delivery" }
        if event.contains("model") || event.contains("prewarm") { return "model_loading" }
        if event.contains("recovery") || event.contains("engine") { return "recovery" }
        return "unknown"
    }
}
