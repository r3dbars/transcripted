import Foundation

/// Privacy-safe source marker for a failed meeting-capture start.
public enum AudioCaptureStartFailureStage: String, Equatable, Sendable {
    case microphoneGraph = "microphone_graph"
    case systemAudio = "system_audio"
    case microphoneFile = "microphone_file"
    case unknown = "unknown"
}

/// Start-state policy for meeting capture.
///
/// Meeting recordings are only valid once both source files exist and both the
/// microphone and system-audio taps have actually delivered their first frame.
/// Returning success on "I/O proc started + file URL assigned" alone can leave
/// a header-only mic WAV or a never-streaming system tap while the UI claims to
/// be recording. Both latches keep capture in `.waiting` until the start
/// deadline fails it and tears it down honestly.
public enum AudioCaptureStartState {
    public enum Outcome: Equatable {
        case waiting
        case ready
        case failed(String)
    }

    public static func meetingCaptureOutcome(
        isRecording: Bool,
        micAudioFileURL: URL?,
        micAudioStreaming: Bool,
        systemAudioFileURL: URL?,
        systemAudioStreaming: Bool,
        errorMessage: String?
    ) -> Outcome {
        if let errorMessage, !errorMessage.isEmpty {
            return .failed(errorMessage)
        }

        if isRecording,
           micAudioFileURL != nil,
           micAudioStreaming,
           systemAudioFileURL != nil,
           systemAudioStreaming {
            return .ready
        }

        return .waiting
    }

    public static func timeoutFailureMessage(
        existingErrorMessage: String?,
        micAudioStreaming: Bool,
        systemAudioStreaming: Bool
    ) -> String {
        if let existingErrorMessage, !existingErrorMessage.isEmpty {
            return existingErrorMessage
        }

        if !micAudioStreaming, systemAudioStreaming {
            return "Microphone capture did not become ready in time. Check your input device, then try again."
        }
        if micAudioStreaming, !systemAudioStreaming {
            return "System audio capture did not become ready in time."
        }
        if !micAudioStreaming, !systemAudioStreaming {
            return "Microphone and system audio capture did not become ready in time."
        }

        return "System audio capture did not become ready in time."
    }
}

/// Coarse, snapshot-visible marker for the bounded start-time voice-processing
/// fallback. `none` means the fallback never engaged for the current recording
/// session; `attempted` means Apple voice processing was requested but did not
/// become active on the first graph attempt, so the retry ran on the standard
/// non-VPIO microphone path. Whether the fallback ultimately succeeded is
/// visible from which event carries the value (`meeting_recording_started` vs
/// `meeting_recording_start_failed`).
public enum VoiceProcessingStartFallbackState: String, Sendable {
    case none
    case attempted
}

/// Pure decision for the one bounded meeting-start fallback when Apple voice
/// processing (VPIO) was requested but did not become active while building
/// the meeting microphone graph.
///
/// A failed `setVoiceProcessingEnabled(true)` can leave the fresh input node
/// tainted (private-aggregate device identity, stale format), so the normal
/// retry — which re-arms VPIO identically — fails the exact same way and the
/// start aborts before any capture, watchdog, or device recovery exists.
/// Dictation already survives this state by continuing without VPIO
/// (`ParakeetEngine.applyDictationVoiceProcessingPreference`); this policy
/// gives meeting capture the same escape hatch, bounded to a single retry per
/// graph build, without touching permission gating or the readiness latches
/// in `AudioCaptureStartState.meetingCaptureOutcome`.
public enum VoiceProcessingStartFallbackPolicy {
    /// - Parameters:
    ///   - voiceProcessingRequested: the host's `enableVoiceProcessing` intent.
    ///   - previousAttemptVoiceProcessingActive: `VoiceProcessingBindResult.enabled`
    ///     from the attempt that just failed, or nil when no attempt armed yet.
    ///   - fallbackAlreadyEngaged: true once the fallback ran, so it can never
    ///     retry more than once per graph build.
    public static func shouldRetryWithoutVoiceProcessing(
        voiceProcessingRequested: Bool,
        previousAttemptVoiceProcessingActive: Bool?,
        fallbackAlreadyEngaged: Bool
    ) -> Bool {
        voiceProcessingRequested
            && previousAttemptVoiceProcessingActive == false
            && !fallbackAlreadyEngaged
    }
}
