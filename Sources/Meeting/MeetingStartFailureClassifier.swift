import Foundation

/// Telemetry-sensitive classifier for meeting-recording start failures.
///
/// Maps a raw start-failure message into one of six stable analytics
/// rawValues. These strings are emitted as the `failure_kind` analytics
/// property, so the distinct values must not be collapsed or renamed.
/// This is intentionally separate from `MeetingFailureKind.classify`, which
/// has its own (broader) taxonomy for the transcription pipeline.
enum MeetingStartFailureClassifier {
    static func kind(
        from message: String,
        stage: String? = nil,
        microphoneGranted: Bool? = nil,
        explicitMicrophoneDenial: Bool = false
    ) -> String {
        let normalized = message.lowercased()
        if explicitMicrophoneDenial {
            return "permission_missing"
        }
        // The actual denied-access messages do not all contain "permission".
        // Keep these explicit production phrases ahead of the device/stream
        // branches; a generic capture failure remains a service failure.
        let namesMicrophonePermission = normalized.contains("microphone access denied")
            || normalized.contains("microphone permission")
            || normalized.contains("mic_not_authorized")
        if Self.namesSystemAudioPermission(normalized) {
            return "permission_missing"
        }
        if namesMicrophonePermission || normalized.contains("permission") {
            // A granted microphone means the word "permission" is not a TCC
            // denial (Finder write permissions, a Bluetooth route that is
            // still switching, leftover copy). APPLE-MACOS-20 events all had
            // mic_permission_granted=true while failure_kind said otherwise.
            if microphoneGranted == true {
                // Fall through to stage / device classification.
            } else {
                return "permission_missing"
            }
        }
        // Checked before the microphone branch: the core start path names
        // voice processing explicitly when the requested-but-inactive VPIO
        // fallback also failed, and that state must not report as a bare
        // microphone (permission-looking) dead end.
        if normalized.contains("voice processing") { return "voice_processing_unavailable" }
        if normalized.contains("timeout") || normalized.contains("timed out") { return "start_timeout" }
        switch stage {
        case "microphone_permission":
            return "permission_missing"
        case "system_audio":
            return "system_stream_unavailable"
        case "microphone_graph", "microphone_file", "microphone_tap_raised":
            return "mic_unavailable"
        default:
            break
        }
        if normalized.contains("system audio") { return "system_stream_unavailable" }
        if normalized.contains("microphone") || normalized.contains("mic") { return "mic_unavailable" }
        return "unexpected"
    }

    /// Specific start-failure cause for Sentry `start_failure_cause`. Narrower
    /// than `failure_kind`, so Bluetooth-unready can be split from a genuine
    /// missing Microphone permission without renaming the existing kinds.
    static func cause(
        kind: String,
        stage: String?,
        inputDeviceClass: String?,
        selectionReason: String?,
        stabilizationOutcome: String?,
        message: String = "",
        explicitMicrophoneDenial: Bool = false
    ) -> String {
        let normalized = message.lowercased()
        if explicitMicrophoneDenial {
            return "mic_permission_denied"
        }
        if kind == "permission_missing" {
            if stage == "system_audio" || Self.namesSystemAudioPermission(normalized) {
                return "system_audio_permission_denied"
            }
            return "mic_permission_denied"
        }
        if kind == "voice_processing_unavailable" { return "voice_processing_unavailable" }
        if kind == "start_timeout" { return "start_timeout" }
        if kind == "system_stream_unavailable" { return "system_stream_unavailable" }
        if stage == "microphone_tap_raised" { return "tap_raised" }
        if stabilizationOutcome == "built_in_unavailable" { return "built_in_unavailable" }
        if selectionReason == "noBuiltInFallbackAvailable" { return "no_fallback_input" }
        if inputDeviceClass == "bluetooth", kind == "mic_unavailable" {
            return "bluetooth_unready"
        }
        if kind == "mic_unavailable" { return "mic_unavailable" }
        if kind == "unexpected" { return "unexpected" }
        return kind
    }

    static func microphoneGranted(from snapshot: [String: String]) -> Bool? {
        switch snapshot["mic_permission_granted"] {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func namesSystemAudioPermission(_ normalized: String) -> Bool {
        normalized.contains("system audio recording is off")
            || (normalized.contains("system audio") && normalized.contains("permission"))
            || (
                normalized.contains("system audio recording")
                    && (
                        normalized.contains("turn on")
                            || normalized.contains("system settings")
                    )
            )
    }
}

enum MeetingStartFailureCopy {
    static func userMessage(raw: String, cause: String) -> String {
        switch cause {
        case "mic_permission_denied":
            return "Turn on Microphone access in System Settings before recording a meeting."
        case "bluetooth_unready":
            return "The Bluetooth microphone did not become ready in time. Wait a moment and try again, or pick the Mac's microphone in Sound settings."
        case "no_fallback_input", "built_in_unavailable":
            return "Transcripted couldn't start the microphone. Connect a mic or wait for Bluetooth to finish switching, then try again."
        default:
            return raw
        }
    }
}
